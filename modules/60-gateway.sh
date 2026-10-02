# shellcheck shell=bash
# modules/60-gateway.sh — rdpgw, an RD Gateway: RDP clients (mstsc, Windows
# App, Remmina/FreeRDP) tunnel native RDP through HTTPS on 443 to the VMs.
# Users authenticate at the gateway as VM_USER with its password: mstsc with
# NTLM, the Windows App on macOS, iOS and Android with Basic, which rdpgw-auth
# checks through PAM against a hash of that password (never against the host's
# accounts). The gateway then lets them reach exactly the VMs in VMS and
# REMOTE_VMS (those of other hosts), by name, on 3389 (or a REMOTE_VMS entry's
# own port).

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

# _gateway_basic_line USER PASSWORD [LINE] — the pam_pwdfile line for USER:
# LINE again when its hash still matches PASSWORD (a new salt would rewrite the
# file and restart the gateway on every run), else a new SHA-512 crypt hash.
_gateway_basic_line() {
  local user="$1" pw="$2" old="${3:-}" hash salt
  hash="${old#"$user":}"
  if [[ "$old" == "$user:\$6\$"* ]]; then
    salt="${hash#\$6\$}"; salt="${salt%%\$*}"
    [[ "$(openssl passwd -6 -salt "$salt" -stdin <<<"$pw")" == "$hash" ]] && { printf '%s\n' "$old"; return 0; }
  fi
  printf '%s:%s\n' "$user" "$(openssl passwd -6 -stdin <<<"$pw")"
}

# gateway_vms — "NAME ADDRESS PORT" of every RDP target the gateway lets
# through: this host's VMs (VMS), each also by the name of its certificate
# (RDP_CERT_DOMAIN), and other targets (REMOTE_VMS, NAME=ADDRESS[:PORT]: a VM of
# another host, or an RDP server with a port of its own).
gateway_vms() {
  local vm ip
  for vm in $(cfg_req VMS); do
    ip="$(vm_ip "$vm")"; printf '%s %s 3389\n' "$vm" "$ip"
    [[ -z "$(cfg_get RDP_CERT_DOMAIN)" ]] || printf '%s %s 3389\n' "$(rdp_cert_name "$vm")" "$ip"
  done
  gateway_remote_targets
}

# gateway_remote_targets — "NAME ADDRESS PORT" of each REMOTE_VMS entry.
gateway_remote_targets() {
  local pair
  for pair in $(cfg_get REMOTE_VMS); do
    [[ "$pair" =~ ^([^=]+)=([^:=]+)(:([0-9]+))?$ ]] || die "REMOTE_VMS entry '$pair' is not NAME=ADDRESS[:PORT]"
    printf '%s %s %s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[4]:-3389}"
  done
}

# The VM names resolve on the host through a marked block in /etc/hosts.
_gateway_hosts_file() {
  local vm ip block
  block="$HOSTS_BEGIN"$'\n'
  while read -r vm ip _; do
    [[ "$block" == *$'\n'"$ip	$vm"$'\n'* ]] || block+="$ip	$vm"$'\n'   # a target on several ports: one line
  done < <(gateway_vms)
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

# _gateway_tls — rdpgw's own certificate for 127.0.0.1, made once: the key
# stays root-only (rdpgw gets it as a credential), the certificate is readable
# for Caddy, which trusts exactly it.
_gateway_tls() {
  local key="$GATEWAY_CONF_DIR/rdpgw-tls.key"
  [[ -s "$key" && -s "$GATEWAY_TLS_CRT" ]] && return 0
  [[ "$DRY_RUN" == 1 ]] && { log_info "dry-run: would make rdpgw's certificate for 127.0.0.1"; return 0; }
  (umask 077; openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 3650 -quiet \
    -subj "/CN=127.0.0.1" -addext "subjectAltName=IP:127.0.0.1" -keyout "$key" -out "$GATEWAY_TLS_CRT")
  chmod 0644 "$GATEWAY_TLS_CRT"
  log_ok "rdpgw's certificate for 127.0.0.1 ($GATEWAY_TLS_CRT)"
}

gateway_setup() {
  if [[ -n "$(cfg_get ENTRY_HOST)" ]]; then
    log_info "RD Gateway: not on this host — $(cfg_get ENTRY_HOST) is the entry point (its REMOTE_VMS lists this host's VMs)"; return 0
  fi
  log_step "RD Gateway → $(cfg_req GATEWAY_HOST) (rdpgw on 127.0.0.1:$GATEWAY_PORT)"
  [[ -x "$(stack_current)/bin/rdpgw" ]] || die "No rdpgw in the active stack — run: sudo ./setup.sh stack build && sudo ./setup.sh stack activate"
  _gateway_hosts_file
  local vm ip hosts="" pw; pw="$(vm_password)"
  GATEWAY_ALLOW="localhost"   # rdpgw may reach exactly the VMs it lets through
  while read -r vm ip port; do
    hosts+="    - \"$vm:$port\""$'\n'
    [[ "$hosts" == *"\"$ip:$port\""* ]] || hosts+="    - \"$ip:$port\""$'\n'   # the same target by its certificate's name
    [[ " $GATEWAY_ALLOW " == *" $ip "* ]] || GATEWAY_ALLOW+=" $ip"
  done < <(gateway_vms)
  GATEWAY_HOST="$(cfg_req GATEWAY_HOST)" GATEWAY_HOSTS="${hosts%$'\n'}"
  SESSION_KEY="$(_gateway_key session)" SESSION_ENC_KEY="$(_gateway_key session-enc)"
  PAA_SIGN_KEY="$(_gateway_key paa-sign)" PAA_ENC_KEY="$(_gateway_key paa-enc)"
  VM_USER="$(cfg_req VM_USER)" VM_PASSWORD="$pw" STACK_CURRENT="$(stack_current)"
  apt_install libpam-pwdfile
  run install -d -m 0700 "$GATEWAY_CONF_DIR"
  _gateway_tls
  local changed=0
  render rdpgw.yaml | atomic_write "$GATEWAY_CONF_DIR/rdpgw.yaml" 0600; (( CHANGED )) && changed=1
  render rdpgw-auth.yaml | atomic_write "$GATEWAY_CONF_DIR/rdpgw-auth.yaml" 0600; (( CHANGED )) && changed=1
  _gateway_basic_line "$VM_USER" "$pw" "$(head -1 "$GATEWAY_CONF_DIR/rdpgw-basic.passwd" 2>/dev/null || true)" \
    | atomic_write "$GATEWAY_CONF_DIR/rdpgw-basic.passwd" 0600; (( CHANGED )) && changed=1
  render rdpgw.pam | atomic_write /etc/pam.d/rdpgw 0644; (( CHANGED )) && changed=1
  render rdpgw-auth.service | atomic_write /etc/systemd/system/rdpgw-auth.service 0644; (( CHANGED )) && changed=2
  render rdpgw.service | atomic_write /etc/systemd/system/rdpgw.service 0644; (( CHANGED )) && changed=2
  if (( changed == 2 )); then run systemctl daemon-reload; fi
  run systemctl enable --now rdpgw-auth.service rdpgw.service
  if (( changed )); then run systemctl restart rdpgw-auth.service rdpgw.service; fi
  # Right after a restart rdpgw needs a moment to open its port.
  local code waited=0
  while code="$(curl -s -o /dev/null -w '%{http_code}' --cacert "$GATEWAY_TLS_CRT" "https://127.0.0.1:$GATEWAY_PORT/" || true)"; [[ "$code" == 000 && "$DRY_RUN" != 1 ]]; do
    (( waited < 15 )) || die "rdpgw does not answer on 127.0.0.1:$GATEWAY_PORT"
    sleep 1; waited=$((waited + 1))
  done
  log_ok "rdpgw answers (HTTP $code); RDP: gateway $(cfg_req GATEWAY_HOST), computer = VM name, user $(cfg_req VM_USER)"
}
