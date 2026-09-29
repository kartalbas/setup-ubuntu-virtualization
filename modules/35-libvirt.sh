# shellcheck shell=bash
# modules/35-libvirt.sh — the VMs' NAT network and storage pools.
#
# Every VM in VMS gets a fixed MAC (derived from its name) and a fixed
# address (NAT_PREFIX.11, .12, ... in list order) through a DHCP reservation,
# so the gateway and the firewall can rely on it. With VM_LAN the VMs are on
# the host's LAN instead (macvtap), with the addresses of VM_LAN_ADDRESSES.

vm_index() { # NAME → 0-based position in VMS
  local i=0 n
  for n in $(cfg_req VMS); do [[ "$n" == "$1" ]] && { echo "$i"; return 0; }; i=$((i + 1)); done
  die "VM '$1' is not listed in VMS ($(cfg_get VMS))"
}
vm_ip() {
  local idx addrs=(); idx="$(vm_index "$1")" || return 1
  if [[ -n "$(cfg_get VM_LAN)" ]]; then
    read -ra addrs <<<"$(cfg_get VM_LAN_ADDRESSES)"
    [[ -n "${addrs[$idx]:-}" ]] || die "VM_LAN_ADDRESSES has no address for $1 (one per VM in VMS, in that order)"
    printf '%s' "${addrs[$idx]}"
  else
    printf '%s.%d' "$(cfg_req NAT_PREFIX)" "$(( 11 + idx ))"
  fi
}
# vm_lan_net — "PREFIX GATEWAY DNS" of the host's VM_LAN interface, e.g.
# "24 192.168.1.1 192.168.1.1": the VMs on that LAN use them too.
vm_lan_net() {
  local ifc pfx gw dns; ifc="$(cfg_req VM_LAN)"
  ip link show "$ifc" >/dev/null 2>&1 || die "VM_LAN: this host has no interface $ifc"
  pfx="$(ip -4 -o addr show dev "$ifc" | awk '{split($4, a, "/"); print a[2]; exit}')"
  gw="$(ip -4 route show default dev "$ifc" | awk '{print $3; exit}')"
  dns="$(resolvectl dns "$ifc" 2>/dev/null | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1 || true)"
  [[ -n "$pfx" && -n "$gw" ]] || die "VM_LAN: $ifc has no IPv4 address or no default route"
  printf '%s %s %s' "$pfx" "$gw" "${dns:-$gw}"
}
vm_mac() { printf '52:54:00:%s' "$(printf '%s' "$1" | sha256sum | sed -E 's/^(..)(..)(..).*/\1:\2:\3/')"; }

_virsh() { run virsh -c qemu:///system "$@"; }
# _vinfo KIND NAME FIELD — one field of net-info/pool-info (captured first:
# `virsh | grep -q` would trip pipefail when grep exits early).
_vinfo() {
  local out; out="$(virsh -c qemu:///system "$1-info" "$2" 2>/dev/null)" || return 1
  sed -nE "s/^$3:[[:space:]]+//p" <<<"$out"
}

# _dhcp_sync NAME MODE — make the DHCP reservations of the network's config
# (MODE=config) or running instance (MODE=live) match VMS exactly.
_dhcp_sync() {
  local name="$1" mode="$2" xml vm entry want dump=(net-dumpxml)
  want=" $(cfg_req VMS) "
  [[ "$mode" == config ]] && dump+=(--inactive)
  xml="$(virsh -c qemu:///system "${dump[@]}" "$name")"
  for vm in $(cfg_req VMS); do
    entry="<host mac='$(vm_mac "$vm")' name='$vm' ip='$(vm_ip "$vm")'/>"
    grep -qF "$entry" <<<"$xml" || _virsh net-update "$name" add-last ip-dhcp-host "$entry" "--$mode"
  done
  grep -oE "<host mac='[^']+' name='[^']+' ip='[^']+'/>" <<<"$xml" | while read -r entry; do
    vm="$(sed -E "s/.*name='([^']+)'.*/\1/" <<<"$entry")"
    [[ "$want" == *" $vm "* ]] || _virsh net-update "$name" delete ip-dhcp-host "$entry" "--$mode"
  done || true
}

libvirt_network_setup() {
  if [[ -n "$(cfg_get VM_LAN)" ]]; then
    log_ok "VMs on the LAN of $(cfg_get VM_LAN) (macvtap): no NAT network"; return 0
  fi
  local name; name="$(cfg_req NAT_NAME)"
  NAT_NAME="$name" NAT_BRIDGE="$(cfg_req NAT_BRIDGE)" NAT_PREFIX="$(cfg_req NAT_PREFIX)"
  if ! _vinfo net "$name" Name >/dev/null; then
    local xml; xml="$(mktemp)"
    render network.xml >"$xml"
    _virsh net-define "$xml"; rm -f "$xml"
  fi
  [[ "$(_vinfo net "$name" Autostart)" == yes ]] || _virsh net-autostart "$name"
  [[ "$(_vinfo net "$name" Active)" == yes ]] || _virsh net-start "$name"
  _dhcp_sync "$name" config
  _dhcp_sync "$name" live
  log_ok "NAT network $name ($(cfg_req NAT_PREFIX).0/24, bridge $(cfg_req NAT_BRIDGE)) is up"
}

_pool() { # NAME DIR
  _vinfo pool "$1" Name >/dev/null || _virsh pool-define-as "$1" dir --target "$2"
  [[ "$(_vinfo pool "$1" Autostart)" == yes ]] || _virsh pool-autostart "$1"
  [[ "$(_vinfo pool "$1" State)" == running ]] || _virsh pool-start "$1"
}

libvirt_pools_setup() {
  _pool vms "$DATA_DIR/vms"
  _pool images "$DATA_DIR/images"
  log_ok "Storage pools: vms → $DATA_DIR/vms, images → $DATA_DIR/images"
}
