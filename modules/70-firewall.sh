# shellcheck shell=bash
# modules/70-firewall.sh — ufw: default deny inbound. Open to everyone: SSH
# and 443 (Caddy). LAN_PORTS: only from LAN_CIDRS and the VM network. The VM
# network may use the host's DHCP/DNS (libvirt's dnsmasq) and is routed
# (NAT) to the outside. Cockpit (9090) and rdpgw (3443) stay localhost-only.

_ufw_rule() { # RULE... — ufw skips rules it already has; hide that chatter
  { run ufw "$@" 2>&1; } | { grep -v '^Skipping' || true; } >&2
}

firewall_setup() {
  if [[ "$(cfg_get FIREWALL 1)" == 0 ]]; then
    log_info "Firewall: left as it is on this host (FIREWALL=0)"; return 0
  fi
  log_step "Firewall (ufw)"
  apt_install ufw
  local bridge cidr port nat
  bridge="$(cfg_req NAT_BRIDGE)"; nat="$(cfg_req NAT_PREFIX).0/24"
  run ufw default deny incoming >/dev/null
  run ufw default allow outgoing >/dev/null
  _ufw_rule allow 22/tcp comment 'ssh'
  _ufw_rule allow 443/tcp comment 'caddy: all public services'
  for port in $(cfg_get LAN_PORTS); do
    for cidr in $(cfg_get LAN_CIDRS) "$nat"; do
      _ufw_rule allow from "$cidr" to any port "$port" proto tcp comment 'LAN-only service'
    done
  done
  if [[ -z "$(cfg_get VM_LAN)" ]]; then   # VMs on the LAN are not behind this host
    _ufw_rule allow in on "$bridge" to any port 67 proto udp comment 'VM network: DHCP'
    _ufw_rule allow in on "$bridge" to any port 53 comment 'VM network: DNS'
    _ufw_rule route allow in on "$bridge" comment 'VM network: outbound (NAT)'
    _ufw_rule route allow out on "$bridge" comment 'VM network: replies'
  fi
  [[ "$(ufw status)" == "Status: active"* ]] || run ufw --force enable
  ufw status verbose | sed 's/^/    /' >&2
}
