# shellcheck shell=bash
# modules/35-libvirt.sh — the VMs' NAT network and storage pools.
#
# Every VM in VMS gets a fixed MAC (derived from its name) and a fixed
# address (NAT_PREFIX.11, .12, ... in list order) through a DHCP reservation,
# so the gateway and the firewall can rely on it.

vm_index() { # NAME → 0-based position in VMS
  local i=0 n
  for n in $(cfg_req VMS); do [[ "$n" == "$1" ]] && { echo "$i"; return 0; }; i=$((i + 1)); done
  die "VM '$1' is not listed in VMS ($(cfg_get VMS))"
}
vm_ip()  { printf '%s.%d' "$(cfg_req NAT_PREFIX)" "$(( 11 + $(vm_index "$1") ))"; }
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
