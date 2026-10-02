#!/usr/bin/env bash
# setup-ubuntu-virtualization — KVM host with Cockpit, desktop VMs over native
# RDP, and one TLS entry point (port 443) for everything.
#
#   sudo ./setup.sh COMMAND [ARGS] [--dry-run]
#
# The machine config lives in /etc/setup-ubuntu-virtualization/config.conf
# (see config.example.conf); pinned upstream versions in versions.conf.

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$REPO_ROOT/lib/common.sh"
for _m in "$REPO_ROOT"/modules/*.sh; do
  # shellcheck source=/dev/null
  . "$_m"
done

usage() {
  cat >&2 <<USAGE
${C_BOLD}setup-ubuntu-virtualization${C_RST} — KVM host, Cockpit, RDP desktops, one port 443

${C_BOLD}USAGE${C_RST}
  sudo ./setup.sh COMMAND [ARGS] [--dry-run]

${C_BOLD}COMMANDS${C_RST} (install runs the host steps in this order)
  init                 Create the machine config from config.example.conf
  config show | set KEY VALUE
                       Show the config, or change one value
  install              host, storage, stack build+activate, libvirt, cockpit,
                       proxy, gateway, firewall — idempotent, safe to re-run
                       (proxy and gateway only on the entry point; see
                       ENTRY_HOST, and FIREWALL for the firewall)
  host                 The host's name (HOST_NAME) and its /etc/hosts line
  storage              Prepare \$DATA_DIR and move libvirt's state onto it
  stack build [--force] | activate [ID] | rollback | status
                       Build the virtualization stack from versions.conf into
                       its own prefix; swap it in only once it passed its checks
  libvirt              Wire the active stack into the system (users, units,
                       AppArmor, D-Bus, NAT network, storage pool)
  cockpit              Cockpit web console behind the proxy
  proxy                Caddy: the single TLS entry point on port 443
  gateway [password]   rdpgw: RDP over HTTPS (RD Gateway) to the VMs;
                       password sets the gateway password (asked twice)
  certs [renew]        Let's Encrypt certificates for the VMs' RDP
                       (RDP_CERT_DOMAIN) and their daily renewal timer;
                       renew: only obtain/renew and deploy (what the timer runs)
  firewall             ufw: allow SSH and 443 only (plus LAN/VM-internal ports)
  vm create NAME | update NAME | restart NAME [--force] | delete NAME --yes | list |
     exec NAME COMMAND
                       Ubuntu desktop VMs from the cloud image + cloud-init;
                       update applies config changes (next boot), restart
                       reboots cleanly; exec runs a command inside (guest agent)
  vm snapshot NAME [TAG] | snapshots NAME | revert NAME TAG --yes |
     snapshot-delete NAME TAG
                       Disk snapshots, taken while the VM runs (its file
                       systems frozen for that moment); revert shuts it down,
                       returns its disk to the snapshot and starts it
  doctor [--rdp]       Health check of everything; --rdp also logs in to every
                       VM over RDP, directly and through the gateway (FreeRDP)
  configs [save]       This host's settings from / to your own private config
                       repository (CONFIGS_REPO)
USAGE
}

main() {
  local args=() a
  for a in "$@"; do
    case "$a" in
      --dry-run) DRY_RUN=1 ;;
      -h|--help) usage; exit 0 ;;
      *) args+=("$a") ;;
    esac
  done
  set -- "${args[@]}"
  (( $# )) || { usage; exit 1; }
  local verb="$1"; shift
  require_root "$verb" "$@"
  case "$verb" in
    init) cfg_init; return 0 ;;
    config)
      case "${1:-}" in
        show) cfg_load; grep -vE '^[[:space:]]*(#|$)' "$CONFIG_FILE"; return 0 ;;
        set)  (( $# == 3 )) || die "config set KEY VALUE"; cfg_set "$2" "$3"; return 0 ;;
        *) die "config: show | set KEY VALUE" ;;
      esac ;;
  esac
  cfg_load
  ver_load
  DATA_DIR="$(cfg_req DATA_DIR)"
  case "$verb" in
    install)  host_setup; storage_setup; stack_build; stack_activate; cockpit_setup; proxy_setup; gateway_setup; certs_setup; firewall_setup ;;
    host)     host_setup ;;
    storage)  storage_setup ;;
    stack)
      case "${1:-}" in
        build)    shift; stack_build "$@" ;;
        activate) shift; stack_activate "$@" ;;
        rollback) stack_rollback ;;
        status)   stack_status ;;
        *) die "stack: build | activate [ID] | rollback | status" ;;
      esac ;;
    libvirt)  integrate_all ;;
    cockpit)  cockpit_setup ;;
    proxy)    proxy_setup ;;
    gateway)
      case "${1:-}" in
        "")       gateway_setup ;;
        password) gateway_password ;;
        *) die "gateway: (no argument) | password" ;;
      esac ;;
    certs)
      case "${1:-}" in
        "")    certs_setup ;;
        renew) certs_run ;;
        *) die "certs: (no argument) | renew" ;;
      esac ;;
    firewall) firewall_setup ;;
    vm)
      case "${1:-}" in
        create) vm_create "${2:?vm create NAME}" ;;
        delete) vm_delete "${2:?vm delete NAME --yes}" "${3:-}" ;;
        list)   vm_list ;;
        update) vm_update "${2:?vm update NAME}" ;;
        restart) vm_restart "${2:?vm restart NAME [--force]}" "${3:-}" ;;
        exec)   vm_exec "${2:?vm exec NAME COMMAND}" "${3:?vm exec NAME COMMAND}" ;;
        snapshot)  vm_snapshot "${2:?vm snapshot NAME [TAG]}" "${3:-}" ;;
        snapshots) vm_snapshots "${2:?vm snapshots NAME}" ;;
        revert)    vm_revert "${2:?vm revert NAME TAG --yes}" "${3:?vm revert NAME TAG --yes}" "${4:-}" ;;
        snapshot-delete) vm_snapshot_delete "${2:?vm snapshot-delete NAME TAG}" "${3:?vm snapshot-delete NAME TAG}" ;;
        *) die "vm: create NAME | update NAME | restart NAME | delete NAME --yes | list | exec NAME COMMAND | snapshot NAME [TAG] | snapshots NAME | revert NAME TAG --yes | snapshot-delete NAME TAG" ;;
      esac ;;
    doctor)   doctor "$@" ;;
    configs)  configs_run "$@" ;;
    *) usage; die "Unknown command: $verb" ;;
  esac
}

main "$@"
