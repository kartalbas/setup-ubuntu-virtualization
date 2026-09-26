# shellcheck shell=bash
# modules/10-storage.sh — everything the host keeps for virtualization lives
# under DATA_DIR on the data disk:
#
#   src/  build/        pinned source tarballs, build trees (transient)
#   stack/              built stacks (see modules/20-stack.sh)
#   images/             cloud base images            (libvirt pool "images")
#   vms/                VM disks and seeds           (libvirt pool "vms")
#   libvirt/            bind-mounted onto /var/lib/libvirt (NVRAM, TPM state,
#                       save/snapshot images, dnsmasq leases, QEMU runtime)

LIBVIRT_STATE_MOUNT_UNIT="var-lib-libvirt.mount"

storage_setup() {
  log_step "Storage under $DATA_DIR"
  local mnt; mnt="$(findmnt -n -o TARGET -T "$DATA_DIR" 2>/dev/null || true)"
  [[ -n "$mnt" && "$mnt" != / ]] || die "$DATA_DIR is not on a mounted data disk (it resolves to '/') — mount the disk first"
  log_ok "$DATA_DIR is on $(findmnt -n -o SOURCE -T "$DATA_DIR") ($mnt, $(df -h --output=avail "$mnt" | tail -1 | tr -d ' ') free)"

  run install -d -m 0755 "$DATA_DIR" "$DATA_DIR/stack" "$DATA_DIR/images" "$DATA_DIR/libvirt"
  run install -d -m 0755 -o "$INVOKING_USER" "$DATA_DIR/src" "$DATA_DIR/build"
  run install -d -m 0711 "$DATA_DIR/vms"

  # /var/lib/libvirt → DATA_DIR/libvirt. Existing content is moved over once.
  local unit="/etc/systemd/system/$LIBVIRT_STATE_MOUNT_UNIT"
  if ! mountpoint -q /var/lib/libvirt; then
    if [[ -d /var/lib/libvirt && -n "$(ls -A /var/lib/libvirt 2>/dev/null)" ]]; then
      [[ -z "$(ls -A "$DATA_DIR/libvirt")" ]] || die "Both /var/lib/libvirt and $DATA_DIR/libvirt have content — merge them by hand"
      run cp -a /var/lib/libvirt/. "$DATA_DIR/libvirt/"
      run find /var/lib/libvirt -mindepth 1 -delete
    fi
    run install -d -m 0755 /var/lib/libvirt
  fi
  render var-lib-libvirt.mount | atomic_write "$unit" 0644
  if (( CHANGED )); then run systemctl daemon-reload; fi
  run systemctl enable --now "$LIBVIRT_STATE_MOUNT_UNIT"
  mountpoint -q /var/lib/libvirt || [[ "$DRY_RUN" == 1 ]] || die "/var/lib/libvirt is not mounted"
  log_ok "/var/lib/libvirt is $DATA_DIR/libvirt"
}
