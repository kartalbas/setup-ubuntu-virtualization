# shellcheck shell=bash
# modules/90-doctor.sh — read-only health check of the whole host.

_d_ok=0 _d_bad=0
_check() { # DESCRIPTION COMMAND... — run a check, report ✓/✗
  local what="$1"; shift
  if "$@" >/dev/null 2>&1; then log_ok "$what"; _d_ok=$((_d_ok + 1))
  else log_err "$what"; _d_bad=$((_d_bad + 1)); fi
}
_active()   { systemctl is-active -q "$1"; }
# _vm_cert_ok VM — its RDP presents the certificate lego keeps for it, which
# has at least 14 days left.
_vm_cert_ok() {
  local crt; crt="$(_certs_dir)/certificates/$(rdp_cert_name "$1").crt"
  [[ -f "$crt" ]] && openssl x509 -in "$crt" -noout -checkend $((14 * 86400)) \
    && [[ "$(_cert_fpr "$crt")" == "$(_vm_rdp_fpr "$1")" ]]
}
_http_ok()  { local c; c="$(curl -s -o /dev/null -m 5 -w '%{http_code}' "$@")"; [[ "$c" =~ ^(2|3|401|404) ]]; }
_tcp_open() { timeout 3 bash -c ">/dev/tcp/$1/$2"; }
_resolves_here() { # HOST — DNS points at this machine's public address
  local pub; pub="$(curl -4 -s -m 5 https://ifconfig.me || true)"
  [[ -n "$pub" ]] && getent ahostsv4 "$1" | awk '{print $1}' | grep -qx "$pub"
}
_qemu_off_nvidia() { # no guest's QEMU holds an NVIDIA device open
  local pidfile fd
  for pidfile in /run/libvirt/qemu/*.pid; do
    [[ -f "$pidfile" ]] || continue
    for fd in /proc/"$(cat "$pidfile")"/fd/*; do
      [[ "$(readlink "$fd" 2>/dev/null)" == /dev/nvidia* ]] && return 1
    done
  done
  return 0
}

# _rdp_login TARGET [GATEWAY] — a real RDP login (NLA) as VM_USER with
# FreeRDP, without opening a window; the host's password goes in on stdin.
_rdp_login() {
  local args=(/v:"$1" /u:"$(cfg_req VM_USER)" /d: /auth-only /cert:ignore /log-level:OFF)
  [[ -n "${2:-}" ]] && args+=(/gateway:"g:$2,u:$(cfg_req VM_USER),d:,type:auto")
  { vm_password; echo; if [[ -n "${2:-}" ]]; then vm_password; echo; fi; } \
    | timeout 60 xfreerdp3 "${args[@]}" /from-stdin:force >/dev/null 2>&1
}

# _check_rdp VM [GATEWAY] — classify a login by FreeRDP's exit code:
#   0 login works · 134 (logon failure) the connection got through to the
#   VM, which has its own password now (set inside it) · 155 (access denied)
#   the gateway refused its password · anything else: no connection.
_check_rdp() {
  local vm="$1" gw="${2:-}" how="directly" rc=0
  [[ -n "$gw" ]] && how="through the gateway $gw"
  _rdp_login "$vm" "$gw" || rc=$?
  case "$rc" in
    0)   log_ok "VM $vm: RDP login $how works"; _d_ok=$((_d_ok + 1)) ;;
    134) log_ok "VM $vm: RDP $how reaches the VM (it has its own password, login not tested)"
         _d_ok=$((_d_ok + 1)) ;;
    155) log_err "VM $vm: the gateway refused its password ($how)"; _d_bad=$((_d_bad + 1)) ;;
    *)   log_err "VM $vm: no RDP connection $how (FreeRDP exit $rc)"; _d_bad=$((_d_bad + 1)) ;;
  esac
}

doctor() {
  local rdp=0; [[ "${1:-}" == --rdp ]] && rdp=1
  (( rdp )) && apt_install freerdp3-x11
  log_step "Doctor"
  local cur h vm pair
  _check "$DATA_DIR is on a data disk" bash -c "[[ \$(findmnt -n -o TARGET -T '$DATA_DIR') != / ]]"
  _check "/var/lib/libvirt is bind-mounted from $DATA_DIR/libvirt" mountpoint -q /var/lib/libvirt
  cur="$(stack_dir 2>/dev/null || true)"
  _check "active stack $(basename "${cur:-none}") is complete" test -f "$cur/.complete"
  _check "stack matches versions.conf pin ($(stack_id))" test "$(basename "${cur:-none}")" = "$(stack_id)"
  _check "virtqemud answers (libvirt $(virsh -c qemu:///system version 2>/dev/null | awk '/Using library/{print $NF}'), QEMU $(virsh -c qemu:///system version 2>/dev/null | awk '/Running hypervisor/{print $NF}'))" virsh -c qemu:///system version
  _check "AppArmor profile for virtqemud is loaded" grep -q '^virtqemud ' /sys/kernel/security/apparmor/profiles
  if [[ -n "$(cfg_get VM_LAN)" ]]; then
    _check "VMs on the LAN: interface $(cfg_get VM_LAN) is up" bash -c "ip -o link show '$(cfg_get VM_LAN)' | grep -q 'state UP'"
  else
    _check "NAT network $(cfg_req NAT_NAME) is active" bash -c "virsh -c qemu:///system net-info '$(cfg_req NAT_NAME)' | grep -q '^Active:.*yes'"
  fi
  _check "storage pools vms + images are running" bash -c "virsh -c qemu:///system pool-list --name | grep -qx vms && virsh -c qemu:///system pool-list --name | grep -qx images"
  _check "libvirt-guests is active (shuts guests down with the host)" systemctl is-active -q libvirt-guests.service
  _check "python3 finds the stack's libvirt + cockpit modules" python3 -c 'import libvirt, cockpit'
  _check "libvirt-dbus answers (Cockpit's view of the VMs)" \
    busctl --system call org.libvirt /org/libvirt/QEMU org.libvirt.Connect ListDomains u 0
  _check "Cockpit finds its machines page" bash -c "cockpit-bridge --packages | grep -q '^machines '"
  _check "Cockpit answers on 127.0.0.1:9090" _http_ok -H "Host: $(cfg_req COCKPIT_HOST)" http://127.0.0.1:9090/
  local entry lan; entry="$(cfg_get ENTRY_HOST)"
  if [[ -n "$entry" ]]; then
    # This host's own LAN address is not the entry point: it must be refused.
    lan="$(ip -4 route get "$entry" 2>/dev/null | grep -oE 'src [0-9.]+' | cut -d' ' -f2)"
    _check "Cockpit on the LAN lets only $entry in (refuses $lan)" bash -c "! curl -s -m 3 -o /dev/null http://$lan:9090/"
  else
    _check "Caddy is running" _active caddy
    _check "Caddy listens on 443 and not on 80" bash -c "ss -tlnpH '( sport = :443 )' | grep -q caddy && ! ss -tlnpH '( sport = :80 )' | grep -q caddy"
    _check "rdpgw + rdpgw-auth are running" bash -c "systemctl is-active -q rdpgw && systemctl is-active -q rdpgw-auth"
    _check "rdpgw is not reachable from the LAN" bash -c "! timeout 3 bash -c '>/dev/tcp/$(hostname -I | awk '{print $1}')/$GATEWAY_PORT'"
  fi
  [[ "$(cfg_get FIREWALL 1)" == 0 ]] || _check "ufw is active" bash -c "[[ \$(ufw status) == 'Status: active'* ]]"
  [[ -z "$(cfg_get RDP_CERT_DOMAIN)" ]] || _check "the RDP certificates' daily renewal is on ($CERTS_UNIT.timer)" \
    systemctl is-active -q "$CERTS_UNIT.timer"
  _check "no guest QEMU uses the NVIDIA GPU" _qemu_off_nvidia
  [[ -z "$(cfg_get VM_RENDER_NODE)" ]] || _check "render node $(cfg_get VM_RENDER_NODE) exists" test -e "$(cfg_get VM_RENDER_NODE)"
  for vm in $(cfg_req VMS); do
    [[ "$(_vm_state "$vm")" == undefined ]] && { log_info "VM $vm: not created (sudo ./setup.sh vm create $vm)"; continue; }
    _check "VM $vm is running" test "$(_vm_state "$vm")" = running
    _check "VM $vm: disk readable by root/QEMU only" \
      bash -c "[[ \$(stat -c %a '$(vm_disk "$vm")') == 600 ]]"
    _check "VM $vm answers RDP on $(vm_ip "$vm"):3389" _vm_rdp_up "$vm"
    [[ -z "$(cfg_get RDP_CERT_DOMAIN)" ]] || _check "VM $vm presents the certificate for $(rdp_cert_name "$vm"), valid 14 more days" \
      _vm_cert_ok "$vm"
    # A VM on the LAN (macvtap) cannot be reached from this host: the entry
    # point checks it (REMOTE_VMS there).
    [[ -n "$(cfg_get VM_LAN)" ]] && continue
    _check "VM $vm: ssh $vm works for $INVOKING_USER (key, no prompt)" \
      sudo -u "$INVOKING_USER" -H ssh -o BatchMode=yes -o ConnectTimeout=5 "$vm" true
    if (( rdp )); then
      _check_rdp "$vm"
      [[ -n "$entry" ]] || _check_rdp "$vm" "$(cfg_req GATEWAY_HOST)"
    fi
  done
  if [[ -z "$entry" ]]; then   # the entry point: other hosts' VMs, names, certificates
    local name addr port
    while read -r name addr port; do
      _check "remote target $name answers RDP on $addr:$port" _tcp_open "$addr" "$port"
      if (( rdp )); then
        _check_rdp "$name:$port"
        _check_rdp "$name:$port" "$(cfg_req GATEWAY_HOST)"
      fi
    done < <(gateway_remote_targets)
    for h in $(proxy_hosts); do
      _check "DNS: $h points at this host's public address" _resolves_here "$h"
      _check "TLS: Caddy holds a certificate for $h" proxy_has_cert "$h"
    done
  fi
  echo >&2
  if (( _d_bad )); then log_warn "$_d_ok passed, $_d_bad failed"; exit 1; fi
  log_ok "All $_d_ok checks passed"
}
