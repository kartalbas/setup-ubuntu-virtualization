# shellcheck shell=bash
# modules/20-stack.sh — build the virtualization stack from pinned upstream
# sources (versions.conf) into its own prefix, then swap it in atomically.
#
#   $DATA_DIR/stack/<id>/     one complete stack (QEMU, virglrenderer, libvirt,
#                             libvirt-glib, libvirt-dbus, libvirt-python,
#                             virt-install, Cockpit, cockpit-machines, rdpgw)
#   $DATA_DIR/stack/current   → the active <id>     (what the services run)
#   $DATA_DIR/stack/previous  → the one before it   (for `stack rollback`)
#
# <id> is derived from versions.conf and this build recipe, so an unchanged
# stack is never rebuilt and a changed one never overwrites a running one.
# Everything a build would install outside its prefix (/etc, /var) is captured
# under <id>/payload and applied by the integration modules on activation.

STACK_PARTS=(virglrenderer qemu libvirt libvirt_glib libvirt_dbus libvirt_python virt_manager cockpit cockpit_machines rdpgw)

stack_root()    { printf '%s/stack' "$DATA_DIR"; }
stack_current() { printf '%s/current' "$(stack_root)"; }
stack_id() {
  { grep -E '^[A-Z_]+_(VERSION|SHA256)=' "$REPO_ROOT/versions.conf"; cat "$REPO_ROOT/modules/20-stack.sh"; } \
    | sha256sum | cut -c1-12
}
# Python modules go to <prefix>/lib/python3/dist-packages: Debian's python
# would otherwise add a local/ level for any prefix but /usr.
python_site()   { printf 'lib/python3/dist-packages'; }
export DEB_PYTHON_INSTALL_LAYOUT=deb

_stack_build_deps() {
  apt_install build-essential pkg-config meson ninja-build git curl xz-utils bzip2 \
    python3-venv python3-dev python3-setuptools python3-build python3-installer python3-wheel python3-pip \
    python3-docutils gettext flex bison \
    libglib2.0-dev libepoxy-dev libdrm-dev libgbm-dev libvulkan-dev libva-dev \
    libpixman-1-dev libcap-ng-dev libattr1-dev libseccomp-dev libaio-dev liburing-dev libzstd-dev \
    libnuma-dev libudev-dev libusb-1.0-0-dev libgnutls28-dev libjpeg-dev libpng-dev libfdt-dev \
    libxml2-dev libxml2-utils xsltproc libjson-c-dev libnl-3-dev libnl-route-3-dev libapparmor-dev \
    libpciaccess-dev libtirpc-dev libacl1-dev libblkid-dev libdevmapper-dev \
    libjson-glib-dev libpam0g-dev libkrb5-dev libsystemd-dev systemd-dev
}

# Runtime pieces the stack uses from Ubuntu (none of them depends on libvirt).
_stack_runtime_deps() {
  apt_install dnsmasq-base nftables iproute2 dmidecode genisoimage gettext-base \
    python3-gi gir1.2-libosinfo-1.0 osinfo-db-tools python3-requests python3-libxml2 \
    glib-networking mesa-vulkan-drivers libgl1-mesa-dri
}

# _part NAME — run one component's build/install with its output in a log.
# The subshell gets its own errexit: a caller's `if`/`||` would disable it.
_part() {
  local name="$1" log="$BUILD_DIR/$1.log" rc
  log_info "Building $name (log: $log)"
  set +e; ( set -e; "_build_$name" ) >"$log" 2>&1; rc=$?; set -e
  if (( rc )); then
    tail -n 40 "$log" >&2
    die "Build of $name failed — see $log"
  fi
  log_ok "$name done"
}

# _src_file PART — cache path of a part's pinned tarball.
_src_file() {
  local key="${1^^}" url ext
  url="$(ver_get "${key}_URL" | sed 's/%2E/./g')"
  [[ "$url" =~ \.(tar\.(xz|gz|bz2))$ ]] || die "versions.conf: ${key}_URL is not a tarball"
  ext="${BASH_REMATCH[1]}"
  printf '%s/src/%s-%s.%s' "$DATA_DIR" "${1//_/-}" "$(ver_get "${key}_VERSION")" "$ext"
}

# _unpack PART — verify and unpack a part's source; prints the source dir.
_unpack() {
  local key="${1^^}" src dir="$BUILD_DIR/src/$1"
  src="$(_src_file "$1")"
  download "$(ver_get "${key}_URL")" "$(ver_get "${key}_SHA256")" "$src" >&2
  rm -rf "$dir"; mkdir -p "$dir"
  tar -xf "$src" -C "$dir" --strip-components=1
  chown -R "$INVOKING_USER" "$dir"
  printf '%s' "$dir"
}
_as_builder() { sudo -u "$INVOKING_USER" -H env PATH="$BUILD_PATH" PKG_CONFIG_PATH="$P/lib/pkgconfig" \
                  LDFLAGS="-Wl,-rpath,$P/lib" DEB_PYTHON_INSTALL_LAYOUT=deb "$@"; }
_merge_stage() {
  if [[ -d "$STAGE$P" ]]; then cp -a "$STAGE$P/." "$P/"; rm -rf "$STAGE$P"; fi
}
_meson_part() { # DIR [meson options...]
  local dir="$1"; shift
  _as_builder meson setup "$dir/_build" "$dir" --prefix="$P" --libdir=lib --buildtype=release "$@"
  _as_builder meson compile -C "$dir/_build"
  env DESTDIR="$STAGE" meson install -C "$dir/_build" --no-rebuild
  _merge_stage
}

_build_virglrenderer() {
  local d; d="$(_unpack virglrenderer)"
  _meson_part "$d" -Dplatforms=egl -Dvenus=true -Ddrm-renderers=amdgpu-experimental -Dvideo=true
}

_build_qemu() {
  local d; d="$(_unpack qemu)"
  ( cd "$d" && _as_builder ./configure --prefix="$P" --libdir=lib --sysconfdir=/etc --localstatedir=/var \
      --target-list=x86_64-softmmu --enable-kvm --enable-opengl --enable-virglrenderer \
      --enable-vnc --enable-vnc-jpeg --enable-png --enable-gnutls --enable-seccomp --enable-cap-ng \
      --enable-linux-io-uring --enable-linux-aio --enable-numa --enable-zstd --enable-attr \
      --enable-libudev --enable-libusb --enable-tools --disable-docs --disable-gtk --disable-sdl \
      --disable-spice --extra-ldflags="-Wl,-rpath,$P/lib" )
  _as_builder make -C "$d/build" -j"$(nproc)"
  make -C "$d/build" install DESTDIR="$STAGE"
  _merge_stage
}

_build_libvirt() {
  local d; d="$(_unpack libvirt)"
  _meson_part "$d" --sysconfdir=/etc --localstatedir=/var -Dinit_script=systemd -Ddocs=enabled -Dtests=disabled \
    -Ddriver_qemu=enabled -Ddriver_libvirtd=enabled -Ddriver_remote=enabled -Ddriver_network=enabled \
    -Ddriver_lxc=disabled -Ddriver_ch=disabled -Ddriver_vbox=disabled -Ddriver_esx=disabled \
    -Ddriver_openvz=disabled -Ddriver_vmware=disabled -Ddriver_bhyve=disabled -Ddriver_libxl=disabled \
    -Dapparmor=enabled -Dapparmor_profiles=enabled -Dsecdriver_apparmor=enabled -Dselinux=disabled \
    -Dpolkit=disabled -Dsasl=disabled -Dlibssh=disabled -Dlibssh2=disabled -Dcurl=disabled \
    -Dqemu_user=libvirt-qemu -Dqemu_group=kvm -Dfirewall_backend_priority=nftables \
    -Dstorage_disk=disabled -Dstorage_iscsi=disabled -Dstorage_rbd=disabled -Dstorage_gluster=disabled
  # libvirt-guests.sh sources gettext.sh from libvirt's own bindir.
  ln -sfn /usr/bin/gettext.sh "$P/bin/gettext.sh"
}

_build_libvirt_glib() {
  local d; d="$(_unpack libvirt_glib)"
  _meson_part "$d" -Dintrospection=disabled -Dvapi=disabled -Ddocs=disabled -Dtests=disabled
}

_build_libvirt_dbus() {
  local d; d="$(_unpack libvirt_dbus)"
  _meson_part "$d" -Dinit_script=systemd
}

_build_libvirt_python() {
  local d; d="$(_unpack libvirt_python)"
  ( cd "$d" && _as_builder python3 -m build --wheel --no-isolation --outdir "$d/dist" . )
  python3 -m installer --destdir="$STAGE" --prefix="$P" "$d"/dist/*.whl
  _merge_stage
}

_build_virt_manager() {
  local d; d="$(_unpack virt_manager)"
  _meson_part "$d" -Dupdate-icon-cache=false -Dcompile-schemas=false -Dtests=disabled
}

_build_cockpit() {
  local d; d="$(_unpack cockpit)"
  ( cd "$d" && _as_builder ./configure --prefix="$P" --libdir="$P/lib" --libexecdir="$P/libexec" \
      --sysconfdir=/etc --localstatedir=/var --disable-doc --disable-pcp --disable-ssh \
      --with-systemdunitdir="$P/lib/systemd/system" --with-pamdir="$P/lib/security" \
      --with-default-session-path="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" )
  _as_builder make -C "$d" -j"$(nproc)"
  make -C "$d" install DESTDIR="$STAGE"
  _merge_stage
}

_build_cockpit_machines() {
  local d; d="$(_unpack cockpit_machines)"
  make -C "$d" install DESTDIR="$STAGE" PREFIX="$P"
  _merge_stage
}

_build_rdpgw() {
  local go; go="$DATA_DIR/build/toolchains/go-$(ver_get GO_VERSION)"
  if [[ ! -x "$go/bin/go" ]]; then
    local tgz; tgz="$(_src_file go)"
    download "$(ver_get GO_URL)" "$(ver_get GO_SHA256)" "$tgz"
    mkdir -p "$go"; tar -xf "$tgz" -C "$go" --strip-components=1; chown -R "$INVOKING_USER" "$go"
  fi
  local d; d="$(_unpack rdpgw)"
  # The release's go.sum is incomplete: -mod=mod lets go add the missing
  # sums, each one verified against the Go checksum database.
  # rdpgw-auth (NTLM user store) links libpam, hence cgo.
  ( cd "$d" && _as_builder env GOPATH="$BUILD_DIR/gopath" GOCACHE="$BUILD_DIR/gocache" GOTOOLCHAIN=local \
      GOFLAGS=-mod=mod "$go/bin/go" build -trimpath -o "$d/rdpgw" ./cmd/rdpgw )
  ( cd "$d" && _as_builder env GOPATH="$BUILD_DIR/gopath" GOCACHE="$BUILD_DIR/gocache" GOTOOLCHAIN=local \
      GOFLAGS=-mod=mod "$go/bin/go" build -trimpath -o "$d/rdpgw-auth" ./cmd/auth )
  install -D -m 0755 "$d/rdpgw" "$P/bin/rdpgw"
  install -D -m 0755 "$d/rdpgw-auth" "$P/bin/rdpgw-auth"
}

# _stack_verify P — the new stack must run before it may become current.
_stack_verify() {
  local p="$1" bin missing
  for bin in bin/qemu-system-x86_64 bin/qemu-img sbin/virtqemud sbin/virtnetworkd sbin/virtlogd \
             bin/virsh sbin/libvirt-dbus bin/virt-install libexec/cockpit-ws bin/cockpit-bridge bin/rdpgw bin/rdpgw-auth; do
    [[ -x "$p/$bin" ]] || die "Stack check: $p/$bin missing"
  done
  missing="$(find "$p/bin" "$p/sbin" "$p/libexec" "$p/lib" -maxdepth 1 -type f -perm -u+x -exec ldd {} + 2>/dev/null | grep 'not found' || true)"
  [[ -z "$missing" ]] || die "Stack check: unresolved libraries:"$'\n'"$missing"
  sh -n "$p/libexec/libvirt-guests.sh" && [[ -r "$p/bin/gettext.sh" ]] \
    || die "Stack check: libvirt-guests.sh cannot load gettext.sh"
  "$p/bin/qemu-system-x86_64" --version | head -1 >&2
  "$p/sbin/virtqemud" --version >&2
  "$p/bin/virsh" --version >/dev/null
  PYTHONPATH="$p/$(python_site)" python3 -c 'import libvirt, cockpit' \
    || die "Stack check: python modules libvirt/cockpit not importable"
  log_ok "Stack $p passed its checks"
}

stack_build() {
  local force=0; [[ "${1:-}" == --force ]] && force=1
  local id; id="$(stack_id)"
  P="$(stack_root)/$id"
  if [[ -f "$P/.complete" && $force == 0 ]]; then
    log_ok "Stack $id is already built (versions.conf unchanged) — use --force to rebuild"
    return 0
  fi
  [[ "$(readlink -f "$(stack_current)" 2>/dev/null)" == "$P" ]] && die "Stack $id is active — build a new pin, or rollback first"
  log_step "Build stack $id"
  _stack_build_deps
  _stack_runtime_deps
  BUILD_DIR="$DATA_DIR/build/$id"; STAGE="$BUILD_DIR/stage"
  BUILD_PATH="$P/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
  [[ "$DRY_RUN" == 1 ]] && { log_info "dry-run: would build ${STACK_PARTS[*]} into $P"; return 0; }
  # An interrupted build of the same pin resumes at the first unfinished part.
  (( force )) && rm -rf "$BUILD_DIR" "$P"
  install -d -o "$INVOKING_USER" "$BUILD_DIR" "$BUILD_DIR/src"
  install -d -m 0755 "$P" "$STAGE"
  local part
  for part in "${STACK_PARTS[@]}"; do
    if [[ -f "$BUILD_DIR/.done-$part" ]]; then log_ok "$part already built"; continue; fi
    _part "$part"
    touch "$BUILD_DIR/.done-$part"
  done
  # What was installed outside the prefix becomes the payload for activation.
  mkdir -p "$P/payload"; cp -a "$STAGE/." "$P/payload/"
  _stack_verify "$P"
  grep -E '^[A-Z_]+_VERSION=' "$REPO_ROOT/versions.conf" >"$P/.complete"
  rm -rf "$BUILD_DIR"
  log_ok "Stack $id built — activate it with: sudo ./setup.sh stack activate"
}

stack_activate() {
  local id target; id="${1:-$(stack_id)}"; target="$(stack_root)/$id"
  [[ -f "$target/.complete" ]] || die "Stack $id is not built — run: sudo ./setup.sh stack build"
  local cur; cur="$(readlink "$(stack_current)" 2>/dev/null || true)"
  if [[ "$cur" == "$id" ]]; then
    log_ok "Stack $id is already active"
  else
    log_step "Activate stack $id"
    [[ -n "$cur" ]] && run ln -sfn "$cur" "$(stack_root)/previous"
    run ln -sfn "$id" "$(stack_root)/current.new"
    run mv -T "$(stack_root)/current.new" "$(stack_current)"
  fi
  # Always (re)wire the system to the active stack: idempotent.
  integrate_all
  _stack_prune
}

# _stack_prune — keep only the current and the previous stack; drop every
# other stack, unfinished build tree and outdated Go toolchain.
_stack_prune() {
  local keep d id
  keep=" $(readlink "$(stack_current)" 2>/dev/null || true) $(readlink "$(stack_root)/previous" 2>/dev/null || true) "
  for d in "$(stack_root)"/*/ "$DATA_DIR"/build/*/; do
    [[ -L "${d%/}" ]] && continue
    id="$(basename "$d")"
    [[ "$id" == toolchains || "$keep" == *" $id "* ]] && continue
    run rm -rf "${d%/}"
  done
  for d in "$DATA_DIR"/build/toolchains/go-*/; do
    [[ -d "$d" && "$(basename "$d")" != "go-$(ver_get GO_VERSION)" ]] && run rm -rf "${d%/}"
  done
  return 0
}

stack_rollback() {
  local prev; prev="$(readlink "$(stack_root)/previous" 2>/dev/null)" || die "No previous stack to roll back to"
  stack_activate "$prev"
}

stack_status() {
  local d id
  for d in "$(stack_root)"/*/; do
    [[ -L "${d%/}" || ! -f "$d/.complete" ]] && continue
    id="$(basename "$d")"
    printf '%s%s%s  %s\n' "$C_BOLD" "$id" "$C_RST" \
      "$( [[ "$(readlink "$(stack_current)" 2>/dev/null)" == "$id" ]] && echo '(current)'; \
          [[ "$(readlink "$(stack_root)/previous" 2>/dev/null)" == "$id" ]] && echo '(previous)')"
    sed 's/^/    /' "$d/.complete"
  done
  printf 'versions.conf pin: %s\n' "$(stack_id)"
}
