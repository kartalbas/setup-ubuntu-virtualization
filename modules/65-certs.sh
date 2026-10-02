# shellcheck shell=bash
# modules/65-certs.sh — public certificates for the VMs' RDP. An RDP client
# checks the certificate of the computer it connects to, through the gateway
# too; GNOME Remote Desktop's own is self-signed, so clients warn and Windows
# refuses saved passwords. With RDP_CERT_DOMAIN set, every VM of VMS gets a
# Let's Encrypt certificate for VM.RDP_CERT_DOMAIN — the name to enter as the
# computer — by lego with the DNS-01 challenge at Cloudflare (no inbound port,
# so it works for a host behind another host's entry point too). A daily timer
# renews them; a renewed certificate reaches the VM through its guest agent and
# GNOME Remote Desktop takes it at once (`grdctl rdp set-tls-*` again: replacing
# the file alone is not noticed), without restarting anything.

CERTS_UNIT="setup-ubuntu-virtualization-certs"
GRD_CERT_DIR="/var/lib/gnome-remote-desktop/.local/share/gnome-remote-desktop"

_certs_dir() { printf '%s/certs' "$(cfg_req DATA_DIR)"; }
_cf_token_file() { printf '%s/cloudflare-dns.token' "$SECRETS_DIR"; }
_lego_bin()  { printf '%s/lego/%s/lego' "$(cfg_req DATA_DIR)" "$(ver_get LEGO_VERSION)"; }

# rdp_cert_name VM — the name VM's certificate is for (empty without RDP_CERT_DOMAIN).
rdp_cert_name() {
  local d; d="$(cfg_get RDP_CERT_DOMAIN)"
  [[ -n "$d" ]] && printf '%s.%s' "$1" "$d"
  return 0
}

_lego_install() {
  local bin src; bin="$(_lego_bin)"
  [[ -x "$bin" ]] && return 0
  src="$(cfg_req DATA_DIR)/src/lego-$(ver_get LEGO_VERSION).tar.gz"
  run install -d -m 0755 "$(dirname "$src")" "$(dirname "$bin")"
  download "$(ver_get LEGO_URL)" "$(ver_get LEGO_SHA256)" "$src"
  run tar -xzf "$src" -C "$(dirname "$bin")" lego
  log_ok "lego $(ver_get LEGO_VERSION)"
}

# _vm_put_file NAME PATH — stdin into PATH inside the VM, through the guest
# agent (guest-file-*) by the stack's libvirt binding: no command line carries
# the data (a private key), and no line length limits it.
_vm_put_file() {
  PYTHONPATH="$(stack_current)/$(python_site)" python3 -c '
import base64, json, sys
import libvirt, libvirt_qemu
dom = libvirt.open("qemu:///system").lookupByName(sys.argv[1])
def agent(cmd, **args):
    return json.loads(libvirt_qemu.qemuAgentCommand(dom, json.dumps({"execute": cmd, "arguments": args}), 30, 0))["return"]
data = sys.stdin.buffer.read()
h = agent("guest-file-open", path=sys.argv[2], mode="w")
try:
    for i in range(0, len(data), 32768):
        agent("guest-file-write", handle=h, **{"buf-b64": base64.b64encode(data[i:i + 32768]).decode()})
finally:
    agent("guest-file-close", handle=h)
' "$1" "$2"
}

# _cert_fpr FILE — SHA-256 fingerprint of a PEM certificate, as grdctl shows it.
_cert_fpr() { openssl x509 -in "$1" -noout -fingerprint -sha256 | cut -d= -f2 | tr 'A-F' 'a-f'; }

# _vm_rdp_fpr NAME — the fingerprint of the certificate the VM's RDP presents.
_vm_rdp_fpr() {
  vm_exec "$1" 'grdctl --system status 2>/dev/null' 2>/dev/null | sed -nE 's/^[[:space:]]*TLS fingerprint: //p' | tr 'A-F' 'a-f'
}

# _cert_deploy VM CRT KEY — the certificate into the VM's GNOME Remote Desktop.
# The files are checked inside the VM before GNOME Remote Desktop is pointed at
# them, and what it then presents is checked again: anything else, and it is
# pointed back at what it had.
_cert_deploy() {
  local vm="$1" crt="$2" key="$3" want d="$GRD_CERT_DIR" old
  [[ "$DRY_RUN" == 1 ]] && { log_info "dry-run: would give $vm the certificate $(basename "$crt")"; return 0; }
  want="$(_cert_fpr "$crt")"
  if ! _vm_put_file "$vm" "$d/rdp-public.crt.new" <"$crt" || ! _vm_put_file "$vm" "$d/rdp-public.key.new" <"$key"; then
    log_err "$vm: could not copy the certificate in"; return 1
  fi
  vm_exec "$vm" "cd $d && [[ \$(openssl x509 -in rdp-public.crt.new -noout -fingerprint -sha256 | cut -d= -f2 | tr A-F a-f) == $want ]] \
    && [[ \$(openssl x509 -in rdp-public.crt.new -noout -pubkey | sha256sum) == \$(openssl pkey -in rdp-public.key.new -pubout | sha256sum) ]] \
    && chown gnome-remote-desktop:gnome-remote-desktop rdp-public.crt.new rdp-public.key.new \
    && chmod 0644 rdp-public.crt.new && chmod 0600 rdp-public.key.new \
    && mv -f rdp-public.key.new rdp-public.key && mv -f rdp-public.crt.new rdp-public.crt" >/dev/null 2>&1 \
    || { vm_exec "$vm" "rm -f $d/rdp-public.crt.new $d/rdp-public.key.new" >/dev/null 2>&1; log_err "$vm: the copied certificate is not intact — nothing changed"; return 1; }
  old="$(vm_exec "$vm" 'grdctl --system status 2>/dev/null' 2>/dev/null | sed -nE 's/^[[:space:]]*TLS (certificate|key): /\1 /p')"
  vm_exec "$vm" "grdctl --system rdp set-tls-key $d/rdp-public.key && grdctl --system rdp set-tls-cert $d/rdp-public.crt" >/dev/null 2>&1
  [[ "$(_vm_rdp_fpr "$vm")" == "$want" ]] && return 0
  vm_exec "$vm" "grdctl --system rdp set-tls-key $(awk '$1 == "key" {print $2}' <<<"$old") && grdctl --system rdp set-tls-cert $(awk '$1 == "certificate" {print $2}' <<<"$old")" >/dev/null 2>&1
  log_err "$vm: GNOME Remote Desktop did not present the new certificate — back to its previous one"
  return 1
}

# certs_run — obtain or renew each VM's certificate, and give it to the VM
# wherever the VM's RDP presents another one. Also what the timer runs.
certs_run() {
  local vm name dir crt key want have
  [[ -n "$(cfg_get RDP_CERT_DOMAIN)" ]] || { log_info "RDP certificates: RDP_CERT_DOMAIN is empty, the VMs keep their own"; return 0; }
  log_step "RDP certificates (Let's Encrypt, DNS-01 at Cloudflare)"
  [[ -s "$(_cf_token_file)" ]] || die "No Cloudflare token in $(_cf_token_file) (an API token allowed to edit DNS of the zone; see README)"
  _lego_install
  dir="$(_certs_dir)"; run install -d -m 0700 "$dir"
  for vm in $(cfg_req VMS); do
    name="$(rdp_cert_name "$vm")"
    CF_DNS_API_TOKEN_FILE="$(_cf_token_file)" run "$(_lego_bin)" run --accept-tos --dns cloudflare --path "$dir" \
      --no-random-sleep --log.format text --log.level warn -d "$name" \
      || { log_err "$name: no certificate (lego failed)"; continue; }
    crt="$dir/certificates/$name.crt" key="$dir/certificates/$name.key"
    [[ -f "$crt" || "$DRY_RUN" == 1 ]] || { log_err "$name: lego wrote no certificate"; continue; }
    if [[ "$(_vm_state "$vm")" != running ]]; then log_info "$vm is not running: its certificate follows at the next run"; continue; fi
    [[ "$DRY_RUN" == 1 ]] && { log_info "dry-run: $name"; continue; }
    want="$(_cert_fpr "$crt")" have="$(_vm_rdp_fpr "$vm")"
    if [[ "$want" == "$have" ]]; then log_ok "$vm presents $name (until $(openssl x509 -in "$crt" -noout -enddate | cut -d= -f2))"
    elif _cert_deploy "$vm" "$crt" "$key"; then log_ok "$vm now presents $name"; fi
  done
}

# certs_setup — certs_run once, and the daily timer that runs it again.
certs_setup() {
  if [[ -z "$(cfg_get RDP_CERT_DOMAIN)" ]]; then
    if [[ -f "/etc/systemd/system/$CERTS_UNIT.timer" ]]; then
      run systemctl disable --now "$CERTS_UNIT.timer" >/dev/null 2>&1 || true
      run rm -f "/etc/systemd/system/$CERTS_UNIT.timer" "/etc/systemd/system/$CERTS_UNIT.service"
      run systemctl daemon-reload
    fi
    certs_run; return 0
  fi
  certs_run
  local changed=0
  render rdp-certs.service | atomic_write "/etc/systemd/system/$CERTS_UNIT.service" 0644; (( CHANGED )) && changed=1
  render rdp-certs.timer | atomic_write "/etc/systemd/system/$CERTS_UNIT.timer" 0644; (( CHANGED )) && changed=1
  (( changed )) && run systemctl daemon-reload
  run systemctl enable --now "$CERTS_UNIT.timer" >/dev/null 2>&1
  log_ok "Renewal: $CERTS_UNIT.timer, daily"
}
