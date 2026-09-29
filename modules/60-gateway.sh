# shellcheck shell=bash
# modules/60-gateway.sh — rdpgw, an RD Gateway: RDP clients (mstsc, Windows
# App, Remmina/FreeRDP) tunnel native RDP through HTTPS on 443 to the VMs.
# Users authenticate at the gateway with NTLM (VM_USER + its password); the
# gateway then lets them reach exactly the VMs in VMS and REMOTE_VMS (those of
# other hosts), by name, on 3389.

GATEWAY_CONF_DIR="/etc/setup-ubuntu-virtualization/rdpgw"
HOSTS_BEGIN="# BEGIN setup-ubuntu-virtualization VMs"
HOSTS_END="# END setup-ubuntu-virtualization VMs"

# _gateway_key NAME — a 32-character secret kept across runs.
_gateway_key() {
  local f="$SECRETS_DIR/rdpgw-$1.key" k
  if [[ ! -s "$f" ]]; then
    run install -d -m 0700 "$SECRETS_DIR"
    k="$(openssl rand -base64 64 | tr -dc 'A-Za-z0-9')"
    (umask 077; printf '%s' "${k:0:32}" >"$f")
  fi
  cat "$f"
}

# gateway_vms — "NAME ADDRESS" of every VM the gateway lets through: this
# host's (VMS) and other hosts' (REMOTE_VMS).
gateway_vms() {
  local vm pair
  for vm in $(cfg_req VMS); do printf '%s %s\n' "$vm" "$(vm_ip "$vm")"; done
  for pair in $(cfg_get REMOTE_VMS); do
    [[ "$pair" == ?*=?* ]] || die "REMOTE_VMS entry '$pair' is not NAME=ADDRESS"
    printf '%s %s\n' "${pair%%=*}" "${pair#*=}"
  done
}

# The VM names resolve on the host through a marked block in /etc/hosts.
_gateway_hosts_file() {
  local vm ip block
  block="$HOSTS_BEGIN"$'\n'
  while read -r vm ip; do block+="$ip	$vm"$'\n'; done < <(gateway_vms)
  block+="$HOSTS_END"
  awk -v b="$HOSTS_BEGIN" -v e="$HOSTS_END" '$0 == b {skip=1} !skip {print} $0 == e {skip=0}' /etc/hosts \
    | { cat; printf '%s\n' "$block"; } | atomic_write /etc/hosts 0644
}

# gateway_password — set the gateway password (also the one new VMs get).
# Read from the terminal twice, never from the command line.
gateway_password() {
  local a b
  [[ -t 0 ]] || die "Run this interactively: the password is read from the terminal"
  read -rsp "New gateway password for $(cfg_req VM_USER): " a; echo >&2
  read -rsp "Repeat it: " b; echo >&2
  [[ "$a" == "$b" ]] || die "The two entries differ — nothing changed"
  (( ${#a} >= 12 )) || die "Use at least 12 characters — nothing changed"
  [[ "$a" != *[\"\\]* ]] || die "Double quotes and backslashes are not supported — nothing changed"
  if [[ "$DRY_RUN" == 1 ]]; then log_info "dry-run: would store the new password and re-apply the gateway"; return 0; fi
  run install -d -m 0700 "$SECRETS_DIR"
  (umask 077; printf '%s' "$a" >"$SECRETS_DIR/vm-user.password")
  log_ok "Stored the new password in $SECRETS_DIR/vm-user.password"
  gateway_setup
}

gateway_setup() {
  if [[ -n "$(cfg_get ENTRY_HOST)" ]]; then
    log_info "RD Gateway: not on this host — $(cfg_get ENTRY_HOST) is the entry point (its REMOTE_VMS lists this host's VMs)"; return 0
  fi
  log_step "RD Gateway → $(cfg_req GATEWAY_HOST) (rdpgw on 127.0.0.1:$GATEWAY_PORT)"
  [[ -x "$(stack_current)/bin/rdpgw" ]] || die "No rdpgw in the active stack — run: sudo ./setup.sh stack build && sudo ./setup.sh stack activate"
  _gateway_hosts_file
  local vm ip hosts="" pw; pw="$(vm_password)"
  while read -r vm ip; do
    hosts+="    - \"$vm:3389\""$'\n'"    - \"$ip:3389\""$'\n'
  done < <(gateway_vms)
  GATEWAY_HOST="$(cfg_req GATEWAY_HOST)" GATEWAY_HOSTS="${hosts%$'\n'}"
  SESSION_KEY="$(_gateway_key session)" SESSION_ENC_KEY="$(_gateway_key session-enc)"
  PAA_SIGN_KEY="$(_gateway_key paa-sign)" PAA_ENC_KEY="$(_gateway_key paa-enc)"
  VM_USER="$(cfg_req VM_USER)" VM_PASSWORD="$pw" STACK_CURRENT="$(stack_current)" NAT_PREFIX="$(cfg_req NAT_PREFIX)"
  run install -d -m 0700 "$GATEWAY_CONF_DIR"
  local changed=0
  render rdpgw.yaml | atomic_write "$GATEWAY_CONF_DIR/rdpgw.yaml" 0600; (( CHANGED )) && changed=1
  render rdpgw-auth.yaml | atomic_write "$GATEWAY_CONF_DIR/rdpgw-auth.yaml" 0600; (( CHANGED )) && changed=1
  render rdpgw-auth.service | atomic_write /etc/systemd/system/rdpgw-auth.service 0644; (( CHANGED )) && changed=2
  render rdpgw.service | atomic_write /etc/systemd/system/rdpgw.service 0644; (( CHANGED )) && changed=2
  if (( changed == 2 )); then run systemctl daemon-reload; fi
  run systemctl enable --now rdpgw-auth.service rdpgw.service
  if (( changed )); then run systemctl restart rdpgw-auth.service rdpgw.service; fi
  local code; code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$GATEWAY_PORT/" || true)"
  [[ "$code" != 000 ]] || [[ "$DRY_RUN" == 1 ]] || die "rdpgw does not answer on 127.0.0.1:$GATEWAY_PORT"
  log_ok "rdpgw answers (HTTP $code); RDP: gateway $(cfg_req GATEWAY_HOST), computer = VM name, user $(cfg_req VM_USER)"
}
