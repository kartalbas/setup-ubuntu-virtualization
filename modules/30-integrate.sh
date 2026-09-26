# shellcheck shell=bash
# modules/30-integrate.sh — wire the active stack into the system. Runs on
# every `stack activate` (and `setup.sh libvirt`), so a new or rolled-back
# stack always replaces the previous one's units, profiles and links.
#
#   /usr/local/lib/systemd/system   stack units (vendor layer; our drop-ins
#                                   and settings go to /etc as usual)
#   /usr/local/bin                  links to the stack's user-facing tools
#   /usr/local/{share,lib}/cockpit  links for Cockpit's bridge
#   /usr/local/lib/python3.X/dist-packages/*.pth the stack's Python modules
#   /etc/apparmor.d                 libvirt's profiles for this stack

UNIT_DIR="/usr/local/lib/systemd/system"
STACK_MARK="# Installed by setup-ubuntu-virtualization"
STACK_TOOLS=(virsh virt-admin virt-host-validate virt-xml-validate virt-install virt-clone virt-xml
             qemu-img qemu-nbd qemu-io qemu-system-x86_64 cockpit-bridge)
# Modular libvirt daemons in use (no monolithic libvirtd, no remote proxy).
LIBVIRT_DAEMONS=(virtqemud virtlogd virtlockd virtnetworkd virtstoraged virtnodedevd virtsecretd
                 virtinterfaced virtnwfilterd)

stack_dir() { readlink -f "$(stack_current)"; }

# _put_unit FILE — install one stack unit; services wait for the data disk
# that holds their binaries.
_put_unit() {
  local src="$1" name; name="$(basename "$src")"
  { echo "$STACK_MARK from $(dirname "$src")"
    if [[ "$name" == *.service ]]; then
      sed "0,/^\[Unit\]\$/s||[Unit]\nRequiresMountsFor=$DATA_DIR|" "$src"
    else
      cat "$src"
    fi
  } | atomic_write "$UNIT_DIR/$name" 0644
  if (( CHANGED )); then UNITS_CHANGED=1; fi
  INSTALLED_UNITS+=("$name")
}

# _prune_units — remove units a previous stack installed that this one lacks.
_prune_units() {
  local f u keep
  for f in "$UNIT_DIR"/*; do
    [[ -f "$f" && "$(head -1 "$f")" == "$STACK_MARK"* ]] || continue
    keep=0
    for u in "${INSTALLED_UNITS[@]}"; do [[ "$u" == "$(basename "$f")" ]] && keep=1; done
    (( keep )) || { run rm -f "$f"; UNITS_CHANGED=1; }
  done
}

# _link TARGET LINK — LINK → TARGET, refusing to replace anything but a link.
_link() {
  [[ "$(readlink "$2" 2>/dev/null)" == "$1" ]] && return 0
  [[ ! -e "$2" || -L "$2" ]] || die "$2 exists and is not a link — move it away first"
  run ln -sfn "$1" "$2"
}

_integrate_links() {
  local cur="$1" t
  for t in "${STACK_TOOLS[@]}"; do
    [[ -x "$cur/bin/$t" ]] || die "Stack lacks bin/$t"
    _link "$(stack_current)/bin/$t" "/usr/local/bin/$t"
  done
  # Cockpit's bridge looks for its pages and helpers in fixed places only.
  _link "$(stack_current)/share/cockpit" /usr/local/share/cockpit
  _link "$(stack_current)/libexec" /usr/local/lib/cockpit
  # The stack's Python modules (libvirt, cockpit) for every python3: a .pth
  # file in the interpreter's local site directory.
  local site; site="$(python3 -c 'import sysconfig; print(sysconfig.get_path("purelib", "posix_local"))')"
  echo "$(stack_current)/$(python_site)" | atomic_write "$site/setup-ubuntu-virtualization.pth" 0644
  [[ "$DRY_RUN" == 1 ]] || python3 -c 'import libvirt, cockpit' \
    || die "python3 cannot import the stack's libvirt/cockpit modules via $site"
}

_integrate_users() {
  local cur="$1"
  render sysusers.conf | atomic_write /usr/local/lib/sysusers.d/setup-ubuntu-virtualization.conf 0644
  run systemd-sysusers
  # D-Bus policies name these users: let the bus re-read them.
  if (( CHANGED )); then run systemctl reload dbus; fi
  [[ " $(id -nG "$INVOKING_USER") " == *" libvirt "* ]] || run usermod -aG libvirt "$INVOKING_USER"
}

_integrate_apparmor() {
  local cur="$1" f
  for f in abstractions/libvirt-qemu libvirt/TEMPLATE.qemu usr.sbin.virtqemud usr.lib.libvirt.virt-aa-helper; do
    atomic_write "/etc/apparmor.d/$f" 0644 <"$cur/payload/etc/apparmor.d/$f"
  done
  run install -d -m 0755 /etc/apparmor.d/libvirt /etc/apparmor.d/abstractions/libvirt-qemu.d /etc/apparmor.d/local
  render apparmor-libvirt-qemu | atomic_write /etc/apparmor.d/abstractions/libvirt-qemu.d/setup-ubuntu-virtualization 0644
  render apparmor-virtqemud | atomic_write /etc/apparmor.d/local/usr.sbin.virtqemud 0644
  render apparmor-virt-aa-helper | atomic_write /etc/apparmor.d/local/usr.lib.libvirt.virt-aa-helper 0644
  run apparmor_parser -r -W /etc/apparmor.d/usr.sbin.virtqemud /etc/apparmor.d/usr.lib.libvirt.virt-aa-helper
}

# Default config files are installed once; later runs keep local edits.
_integrate_libvirt_conf() {
  local cur="$1" f
  run install -d -m 0755 /etc/libvirt /etc/libvirt/qemu /etc/libvirt/qemu/networks /etc/libvirt/storage
  run install -d -m 0700 /etc/libvirt/secrets
  for f in "$cur"/payload/etc/libvirt/*.conf; do
    [[ -e "/etc/libvirt/${f##*/}" ]] || run install -m 0644 "$f" "/etc/libvirt/${f##*/}"
  done
  [[ -d /etc/libvirt/nwfilter ]] || run cp -a "$cur/payload/etc/libvirt/nwfilter" /etc/libvirt/
  atomic_write /etc/logrotate.d/libvirtd.qemu 0644 <"$cur/payload/etc/logrotate.d/libvirtd.qemu"
  # Directory skeleton of libvirt's state (on the data disk via the bind mount).
  (cd "$cur/payload" && find var -type d) | while read -r d; do
    [[ -d "/$d" ]] || run install -d -m 0755 "/$d"
  done
  guests_config
  _qemu_seccomp
}

# guests_config — what running VMs do when the host shuts down: saved to disk
# and back 1:1 at boot (VM_HOST_SHUTDOWN=suspend), or shut down cleanly and
# booted again by autostart. QEMU cannot save a VM with 3D graphics, so while
# any VM has them, all are shut down instead of failing to be saved.
guests_config() {
  local name
  VM_ON_SHUTDOWN="$(cfg_get VM_HOST_SHUTDOWN shutdown)"
  [[ "$VM_ON_SHUTDOWN" == suspend || "$VM_ON_SHUTDOWN" == shutdown ]] \
    || die "VM_HOST_SHUTDOWN must be suspend or shutdown (is: $VM_ON_SHUTDOWN)"
  if [[ "$VM_ON_SHUTDOWN" == suspend ]]; then
    for name in $(cfg_get VMS); do
      if virsh -c qemu:///system dumpxml --inactive "$name" 2>/dev/null | grep -q "accel3d='yes'"; then
        log_warn "$name has 3D graphics, which QEMU cannot save: VMs are shut down with the host until it has none (VM_RENDER_NODE empty, vm update, vm restart)"
        VM_ON_SHUTDOWN=shutdown; break
      fi
    done
  fi
  render libvirt-guests.default | atomic_write /etc/default/libvirt-guests 0644
  log_ok "With the host, running VMs are: $([[ "$VM_ON_SHUTDOWN" == suspend ]] && echo "saved and resumed 1:1" || echo "shut down and booted again")"
}

# Venus runs a render server process next to QEMU, which QEMU's seccomp
# sandbox (spawn=deny) forbids: only VM_GPU_MODE=venus relaxes it, globally.
_qemu_seccomp() {
  local want=1 line
  [[ "$(cfg_get VM_GPU_MODE virgl)" == venus ]] && want=0
  line="seccomp_sandbox = $want  # setup-ubuntu-virtualization (0 only for VM_GPU_MODE=venus)"
  if grep -qE '^seccomp_sandbox' /etc/libvirt/qemu.conf; then
    awk -v l="$line" '/^seccomp_sandbox/ { print l; next } { print }' /etc/libvirt/qemu.conf
  else
    cat /etc/libvirt/qemu.conf; echo "$line"
  fi | atomic_write /etc/libvirt/qemu.conf 0644
  if (( CHANGED )); then UNITS_CHANGED=1; fi
}

_integrate_units() {
  local cur="$1" d f
  INSTALLED_UNITS=()
  run install -d -m 0755 "$UNIT_DIR"
  for d in "${LIBVIRT_DAEMONS[@]}"; do
    for f in "$cur"/lib/systemd/system/"$d"{.service,.socket,-ro.socket,-admin.socket}; do
      [[ -f "$f" ]] && _put_unit "$f"
    done
  done
  _put_unit "$cur/lib/systemd/system/virt-secret-init-encryption.service"
  _put_unit "$cur/lib/systemd/system/libvirt-guests.service"
  _put_unit "$cur/lib/systemd/system/virt-guest-shutdown.target"
  _put_unit "$cur/payload/usr/lib/systemd/system/libvirt-dbus.service"
  for f in "$cur"/lib/systemd/system/cockpit* "$cur"/lib/systemd/system/system-cockpithttps.slice; do
    _put_unit "$f"
  done
  _prune_units
  # Without polkit, the read-write sockets are opened up to the libvirt group.
  for d in "${LIBVIRT_DAEMONS[@]}"; do
    [[ "$d" == virtlogd || "$d" == virtlockd ]] && continue
    printf '[Socket]\nSocketGroup=libvirt\nSocketMode=0660\n' \
      | atomic_write "/etc/systemd/system/$d.socket.d/10-libvirt-group.conf" 0644
    if (( CHANGED )); then UNITS_CHANGED=1; fi
  done
  atomic_write /usr/local/lib/tmpfiles.d/cockpit-ws.conf 0644 <"$cur/lib/tmpfiles.d/cockpit-ws.conf"
  if (( UNITS_CHANGED )); then run systemctl daemon-reload; fi
}

# QEMU's firmware descriptors name files inside the versioned stack, and
# libvirt stores the resolved paths in each VM: a stack switch would leave
# them dangling. The same descriptors in /etc/qemu/firmware (which libvirt
# prefers) point at stack/current instead.
_integrate_firmware() {
  local cur="$1" f
  run install -d -m 0755 /etc/qemu/firmware
  for f in "$cur"/share/qemu/firmware/*-x86_64*.json; do
    sed "s|$cur/|$(stack_current)/|g" "$f" | atomic_write "/etc/qemu/firmware/${f##*/}" 0644
  done
}

_integrate_dbus() {
  local cur="$1"
  atomic_write /etc/dbus-1/system.d/org.libvirt.conf 0644 <"$cur/share/dbus-1/system.d/org.libvirt.conf"
  local c1=$CHANGED
  atomic_write /usr/local/share/dbus-1/system-services/org.libvirt.service 0644 <"$cur/share/dbus-1/system-services/org.libvirt.service"
  if (( c1 || CHANGED )); then run systemctl reload dbus; fi
}

_integrate_osinfo() {
  local tar; tar="$(_src_file osinfo_db)"
  download "$(ver_get OSINFO_DB_URL)" "$(ver_get OSINFO_DB_SHA256)" "$tar"
  if [[ ! -f "/etc/osinfo/VERSION" || "$(cat /etc/osinfo/VERSION 2>/dev/null)" != "$(ver_get OSINFO_DB_VERSION)" ]]; then
    run osinfo-db-import --local "$tar"
  fi
}

# _restart_active UNIT... — restart what already runs so it uses this stack.
_restart_active() {
  local u
  for u in "$@"; do
    if systemctl is-active -q "$u"; then run systemctl restart "$u"; fi
  done
}

integrate_all() {
  local cur; cur="$(stack_dir)"
  UNITS_CHANGED=0
  [[ -f "$cur/.complete" ]] || die "No active stack — run: sudo ./setup.sh stack activate"
  log_step "Integrate stack $(basename "$cur")"
  _integrate_users "$cur"
  _integrate_links "$cur"
  _integrate_apparmor "$cur"
  _integrate_libvirt_conf "$cur"
  _integrate_firmware "$cur"
  _integrate_units "$cur"
  _integrate_dbus "$cur"
  _integrate_osinfo
  run systemd-tmpfiles --create /usr/local/lib/tmpfiles.d/cockpit-ws.conf
  local d socks=()
  for d in "${LIBVIRT_DAEMONS[@]}"; do
    socks+=("$d.socket")
    [[ -f "$UNIT_DIR/$d-admin.socket" ]] && socks+=("$d-admin.socket")
    [[ -f "$UNIT_DIR/$d-ro.socket" ]] && socks+=("$d-ro.socket")
  done
  run systemctl enable --now "${socks[@]}"
  # The daemons start at boot (not only on socket activity): virtqemud
  # autostarts the VMs, virtnetworkd/virtstoraged their network and pools.
  run systemctl enable virtqemud.service virtnetworkd.service virtstoraged.service
  # libvirt-guests stops before the daemons, so they are still there to shut
  # the guests down; started (not only enabled), since its stop action is
  # what does it.
  printf '[Unit]\nAfter=virtqemud.service virtnetworkd.service virtstoraged.service\n' \
    | atomic_write /etc/systemd/system/libvirt-guests.service.d/10-after-daemons.conf 0644
  if (( CHANGED )); then run systemctl daemon-reload; fi
  run systemctl enable libvirt-guests.service
  if ! systemctl is-active -q libvirt-guests.service; then run systemctl restart libvirt-guests.service; fi
  # Only a changed stack (new unit files) needs its running daemons restarted.
  # virtlogd/virtlockd hold the running guests' logs and locks: they re-exec
  # (reload) instead of restarting.
  if (( UNITS_CHANGED )); then
    local restart=() d
    for d in "${LIBVIRT_DAEMONS[@]}"; do
      [[ "$d" == virtlogd || "$d" == virtlockd ]] || restart+=("$d.service")
    done
    _restart_active "${restart[@]}" libvirt-dbus.service cockpit.service rdpgw.service rdpgw-auth.service
    for d in virtlogd virtlockd; do
      if systemctl is-active -q "$d.service"; then run systemctl reload "$d.service"; fi
    done
  fi
  libvirt_network_setup
  libvirt_pools_setup
  log_ok "Stack $(basename "$cur") is integrated"
}
