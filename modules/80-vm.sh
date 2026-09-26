# shellcheck shell=bash
# modules/80-vm.sh — Ubuntu desktop VMs, built unattended from the official
# cloud image: cloud-init installs the desktop, creates VM_USER and enables
# GNOME Remote Desktop's "Remote Login" (RDP straight into GDM), then powers
# the VM off; the host detaches the seed and starts the finished VM.

SECRETS_DIR="/etc/setup-ubuntu-virtualization/secrets"
VM_PROVISION_TIMEOUT_MIN=120
SSH_CONFIG="/etc/ssh/ssh_config.d/50-setup-ubuntu-virtualization.conf"
SSH_KNOWN_HOSTS="/etc/ssh/ssh_known_hosts"

# vm_password — the password new VMs get (login + RDP) and the gateway uses;
# generated once, changed with `setup.sh gateway password`.
vm_password() {
  local f="$SECRETS_DIR/vm-user.password"
  if [[ ! -s "$f" ]]; then
    run install -d -m 0700 "$SECRETS_DIR"
    [[ "$DRY_RUN" == 1 ]] && { echo dry-run-password; return 0; }
    local pw; pw="$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9')"
    (umask 077; printf '%s' "${pw:0:24}" >"$f")
    log_ok "Generated the VM user password in $f"
  fi
  printf '%s' "$(cat "$f")"
}

# ---- SSH from the host into the VMs ----------------------------------------
# The admin account that runs setup.sh (via sudo) logs in to every VM as
# VM_USER with its key: `ssh NAME`. The VMs' host keys are fetched through the
# guest agent (a trusted channel), so there is no fingerprint prompt.

# _admin_pubkey — the admin account's ed25519 public key (created if missing).
_admin_pubkey() {
  local home key
  home="$(getent passwd "$INVOKING_USER" | cut -d: -f6)"; key="$home/.ssh/id_ed25519"
  if [[ ! -f "$key.pub" ]]; then
    as_user install -d -m 0700 "$home/.ssh"
    as_user ssh-keygen -q -t ed25519 -N "" -C "$INVOKING_USER@$(hostname)" -f "$key"
  fi
  [[ "$DRY_RUN" == 1 && ! -f "$key.pub" ]] && { echo "ssh-ed25519 DRYRUN"; return 0; }
  cat "$key.pub"
}

# _vm_ssh_access NAME — authorize the admin key in the VM, trust its host key
# on the host, and check that `ssh NAME` gets in without a password.
_vm_ssh_access() {
  local name="$1" user pub hostkey
  user="$(cfg_req VM_USER)"; pub="$(_admin_pubkey)"
  vm_exec "$name" "set -e
    h=\$(getent passwd $user | cut -d: -f6); f=\$h/.ssh/authorized_keys
    install -d -m 0700 -o $user -g $user \$h/.ssh; touch \$f
    grep -qxF $(printf %q "$pub") \$f || printf '%s\\n' $(printf %q "$pub") >>\$f
    chown $user:$user \$f; chmod 0600 \$f
    systemctl enable --now ssh.socket >/dev/null 2>&1" >/dev/null
  hostkey="$(vm_exec "$name" 'cat /etc/ssh/ssh_host_ed25519_key.pub' | awk '{print $1, $2}')"
  [[ "$hostkey" == ssh-ed25519\ * ]] || die "Could not read the SSH host key of $name"
  { grep -vE "^$name,[^ ]+ " "$SSH_KNOWN_HOSTS" 2>/dev/null || true
    echo "$name,$(vm_ip "$name") $hostkey"; } | atomic_write "$SSH_KNOWN_HOSTS" 0644
  { echo "# Managed by setup-ubuntu-virtualization: \`ssh NAME\` logs in to a VM."
    echo "Host $(cfg_req VMS)"
    echo "    User $user"; } | atomic_write "$SSH_CONFIG" 0644
  [[ "$DRY_RUN" == 1 ]] && return 0
  sudo -u "$INVOKING_USER" -H ssh -o BatchMode=yes -o ConnectTimeout=5 "$name" true \
    || die "ssh $name as $INVOKING_USER does not work"
  log_ok "ssh $name works for $INVOKING_USER (logs in as $user, key only)"
}

# _cpu_list_expand "0-3,8" → "0 1 2 3 8"
_cpu_list_expand() {
  local part out=() range
  for part in ${1//,/ }; do
    if [[ "$part" == *-* ]]; then
      mapfile -t range < <(seq "${part%-*}" "${part#*-}"); out+=("${range[@]}")
    else
      out+=("$part")
    fi
  done
  echo "${out[@]}"
}
# _cpuset_minus ALL EXCLUDE — ALL without EXCLUDE, as a compact cpuset:
# "0-31" "0,1,16,17" → "2-15,18-31".
_cpuset_minus() {
  local skip c list=() start="" prev="" out=()
  skip=" $(_cpu_list_expand "$2") "
  for c in $(_cpu_list_expand "$1"); do
    [[ "$skip" == *" $c "* ]] || list+=("$c")
  done
  (( ${#list[@]} )) || die "HOST_CPUS leaves no CPU for the VMs"
  for c in "${list[@]}" ""; do
    if [[ -n "$prev" && "$c" == "$((prev + 1))" ]]; then prev="$c"; continue; fi
    if [[ -n "$start" ]]; then
      if [[ "$start" == "$prev" ]]; then out+=("$start"); else out+=("$start-$prev"); fi
    fi
    start="$c"; prev="$c"
  done
  (IFS=,; echo "${out[*]}")
}
# vm_cpuset — every online CPU that is not in HOST_CPUS.
vm_cpuset() { _cpuset_minus "$(cat /sys/devices/system/cpu/online)" "$(cfg_req HOST_CPUS)"; }

# vm_base_image — current cloud image, verified against its SHA256SUMS.
vm_base_image() {
  local url; url="$(cfg_req VM_IMAGE_URL)"
  local name="${url##*/}" sums want img
  sums="$(curl -fsSL "${url%/*}/SHA256SUMS")" || die "Cannot fetch ${url%/*}/SHA256SUMS"
  want="$(awk -v n="$name" '$2 == n || $2 == "*" n { print $1 }' <<<"$sums")"
  [[ -n "$want" ]] || die "$name is not listed in ${url%/*}/SHA256SUMS"
  img="$DATA_DIR/images/$name"
  if [[ -f "$img" ]] && echo "$want  $img" | sha256sum -c --quiet - 2>/dev/null; then
    printf '%s' "$img"; return 0
  fi
  run curl -fL --retry 3 -o "$img.part" "$url" >&2
  echo "$want  $img.part" | sha256sum -c --quiet - || die "Checksum mismatch for $url"
  run mv -f "$img.part" "$img"
  printf '%s' "$img"
}

# _vm_xml NAME [SEED] — the domain XML (with the provisioning seed or without).
_vm_xml() {
  local name="$1" seed="${2:-}"
  VM_NAME="$name" VM_RAM_GIB="$(cfg_req VM_RAM_GIB)" VM_VCPUS="$(cfg_req VM_VCPUS)"
  # A redefinition must keep the VM's identity.
  VM_UUID="$(virsh -c qemu:///system domuuid "$name" 2>/dev/null || true)"
  VM_UUID="${VM_UUID//[[:space:]]/}"
  [[ -n "$VM_UUID" ]] || VM_UUID="$(cat /proc/sys/kernel/random/uuid)"
  local host_cpus; host_cpus="$(cfg_get HOST_CPUS)"
  if [[ -n "$host_cpus" ]]; then
    VM_CPU_XML="  <vcpu placement='static' cpuset='$(vm_cpuset)'>$VM_VCPUS</vcpu>
  <iothreads>1</iothreads>
  <cputune>
    <emulatorpin cpuset='$host_cpus'/>
    <iothreadpin iothread='1' cpuset='$host_cpus'/>
  </cputune>"
  else
    VM_CPU_XML="  <vcpu placement='static'>$VM_VCPUS</vcpu>
  <iothreads>1</iothreads>"
  fi
  VM_DISK="$DATA_DIR/vms/$name.qcow2" VM_MAC="$(vm_mac "$name")" NAT_NAME="$(cfg_req NAT_NAME)"
  if (( VM_VCPUS % 2 == 0 )); then VM_CORES=$((VM_VCPUS / 2)) VM_THREADS=2; else VM_CORES=$VM_VCPUS VM_THREADS=1; fi
  VM_SEED_XML=""
  [[ -n "$seed" ]] && VM_SEED_XML="    <disk type='file' device='cdrom'>
      <driver name='qemu' type='raw'/>
      <source file='$seed'/>
      <target dev='sda' bus='sata'/>
      <readonly/>
    </disk>"
  local node mode; node="$(cfg_get VM_RENDER_NODE)"; mode="$(cfg_get VM_GPU_MODE virgl)"
  VM_GPU_XML="    <video>
      <model type='virtio' heads='1' primary='yes'/>
    </video>"
  VM_QEMU_XML=""
  if [[ -n "$node" ]]; then
    [[ -e "$node" ]] || die "VM_RENDER_NODE $node does not exist"
    local blob=""
    [[ "$mode" == virgl ]] || blob=" blob='on'"
    VM_GPU_XML="    <graphics type='egl-headless'>
      <gl rendernode='$node'/>
    </graphics>
    <video>
      <model type='virtio' heads='1' primary='yes'$blob>
        <acceleration accel3d='yes'/>
      </model>
    </video>"
    # EGL through Mesa only: glvnd would otherwise also load other vendors'
    # EGL libraries (e.g. NVIDIA's) into QEMU. Venus: only the Vulkan driver
    # of the render node's GPU (not e.g. llvmpipe or another GPU).
    local env="    <qemu:env name='__EGL_VENDOR_LIBRARY_FILENAMES' value='/usr/share/glvnd/egl_vendor.d/50_mesa.json'/>"
    if [[ "$mode" == venus ]]; then
      env+=$'\n'"    <qemu:env name='VK_DRIVER_FILES' value='$(_vulkan_icd "$node")'/>"
    fi
    VM_QEMU_XML="  <qemu:commandline>
$env
  </qemu:commandline>"
    case "$mode" in
      virgl) ;;
      venus)
        local prop="venus"
        VM_QEMU_XML+="
  <qemu:override>
    <qemu:device alias='video0'>
      <qemu:frontend>
        <qemu:property name='hostmem' type='unsigned' value='$((8 * 1024 * 1024 * 1024))'/>
        <qemu:property name='$prop' type='bool' value='true'/>
      </qemu:frontend>
    </qemu:device>
  </qemu:override>" ;;
      *) die "VM_GPU_MODE must be virgl or venus (is: $mode)" ;;
    esac
  fi
  render domain.xml
}

# _vulkan_icd RENDER_NODE — Vulkan ICD manifest of the GPU behind the node.
_vulkan_icd() {
  local drv icd
  drv="$(basename "$(readlink -f "/sys/class/drm/$(basename "$(readlink -f "$1")")/device/driver")")"
  case "$drv" in
    amdgpu|radeon) icd=radeon_icd ;;
    i915|xe)       icd=intel_icd ;;
    nouveau)       icd=nouveau_icd ;;
    nvidia)        icd=nvidia_icd ;;
    *) die "No known Vulkan driver for render node $1 (kernel driver: $drv)" ;;
  esac
  local f
  for f in /usr/share/vulkan/icd.d/"$icd".json /usr/share/vulkan/icd.d/"$icd".x86_64.json; do
    [[ -f "$f" ]] && { printf '%s' "$f"; return 0; }
  done
  die "Vulkan driver manifest $icd not installed (package mesa-vulkan-drivers)"
}

# _vm_start NAME — start; right after a shutdown virtlogd may still hold the
# old QEMU's log for a moment ("Device or resource busy"), so retry briefly.
_vm_start() {
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    if virsh -c qemu:///system start "$1" >/dev/null 2>&1; then log_ok "Started $1"; return 0; fi
    sleep 1
  done
  _virsh start "$1"
}

_vm_state() {
  local st; st="$(virsh -q -c qemu:///system domstate "$1" 2>/dev/null)" || st=undefined
  printf '%s' "${st//$'\n'/}"
}
_vm_define() { # NAME [SEED]
  local xml; xml="$(mktemp)"
  _vm_xml "$@" >"$xml"
  _virsh define "$xml"; rm -f "$xml"
}

vm_create() {
  local name="$1"; vm_index "$name" >/dev/null
  [[ "$(_vm_state "$name")" == undefined ]] || die "VM $name exists already (see: sudo ./setup.sh vm list)"
  log_step "Create VM $name ($(cfg_req VM_VCPUS) vCPU, $(cfg_req VM_RAM_GIB) GiB, $(cfg_req VM_DISK_GB) GB, $(vm_ip "$name"))"
  apt_install genisoimage openssl
  local base disk="$DATA_DIR/vms/$name.qcow2" seed="$DATA_DIR/vms/$name-seed.iso" pw
  base="$(vm_base_image)"
  [[ ! -e "$disk" ]] || die "$disk exists but no VM uses it — remove it or pick another name"
  # The disk holds the whole guest: readable by root and QEMU only.
  (umask 077; run qemu-img convert -O qcow2 "$base" "$disk")
  run qemu-img resize "$disk" "$(cfg_req VM_DISK_GB)G"

  # cloud-init seed (NoCloud). It carries the password, so it lives only
  # until provisioning is done.
  pw="$(vm_password)"
  local work; work="$(mktemp -d)"
  VM_NAME="$name" VM_USER="$(cfg_req VM_USER)" VM_PASSWORD="$pw" VM_MAC="$(vm_mac "$name")"
  VM_PASSWORD_HASH="$(openssl passwd -6 -stdin <<<"$pw")" VM_INSTANCE="$(date +%s)"
  VM_LOCALE="$(cfg_req VM_LOCALE)" VM_TIMEZONE="$(cfg_req VM_TIMEZONE)"
  VM_KEYBOARD="$(cfg_req VM_KEYBOARD)" VM_KEYBOARD_VARIANT="$(cfg_get VM_KEYBOARD_VARIANT)"
  VM_DESKTOP_PACKAGE="$(cfg_req VM_DESKTOP_PACKAGE)" VM_SSH_KEY="$(_admin_pubkey)"
  render user-data.yaml >"$work/user-data"
  render meta-data.yaml >"$work/meta-data"
  render network-config.yaml >"$work/network-config"
  (umask 077; run genisoimage -quiet -output "$seed" -volid cidata -joliet -rock \
    "$work/user-data" "$work/meta-data" "$work/network-config")
  rm -rf "$work"

  _vm_define "$name" "$seed"
  _virsh start "$name"
  log_info "Provisioning $name (desktop install, may take ~20 min); it powers off when done"
  local waited=0
  while [[ "$(_vm_state "$name")" == running ]]; do
    if (( waited >= VM_PROVISION_TIMEOUT_MIN * 60 )); then
      die "$name still provisioning after $VM_PROVISION_TIMEOUT_MIN min — check its console in Cockpit"
    fi
    sleep 30; waited=$((waited + 30))
    if (( waited % 300 == 0 )); then log_info "… $((waited / 60)) min"; fi
  done

  _vm_define "$name"               # the same VM without the seed
  run rm -f "$seed"
  _virsh autostart "$name"
  _vm_start "$name"
  log_info "Waiting for $name to answer RDP on $(vm_ip "$name"):3389"
  waited=0
  until timeout 2 bash -c ">/dev/tcp/$(vm_ip "$name")/3389" 2>/dev/null; do
    if (( waited >= 600 )); then die "$name does not answer RDP — check its console in Cockpit"; fi
    sleep 5; waited=$((waited + 5))
  done
  local status; status="$(vm_exec "$name" 'grdctl --system status --show-credentials 2>/dev/null' || true)"
  grep -qE "^[[:space:]]*Status: enabled" <<<"$status" || die "$name: GNOME Remote Desktop RDP is not enabled"
  grep -qE "^[[:space:]]*Username: $(cfg_req VM_USER)\$" <<<"$status" || die "$name: RDP login credentials are not set"
  _vm_ssh_access "$name"
  log_ok "VM $name is ready: RDP via gateway $(cfg_get GATEWAY_HOST) → computer $name, user $(cfg_req VM_USER)"
  log_info "Password: sudo cat $SECRETS_DIR/vm-user.password"
}

vm_delete() {
  local name="$1" confirm="${2:-}"
  [[ "$confirm" == --yes ]] || die "This destroys $name and its disk. Repeat with: sudo ./setup.sh vm delete $name --yes"
  log_step "Delete VM $name"
  local st; st="$(_vm_state "$name")"
  [[ "$st" == running ]] && _virsh destroy "$name"
  [[ "$st" == undefined ]] || _virsh undefine "$name" --nvram
  run rm -f "$DATA_DIR/vms/$name.qcow2" "$DATA_DIR/vms/$name-seed.iso"
  log_ok "VM $name deleted"
}

vm_list() {
  local vm
  printf '%-10s %-10s %-12s %s\n' NAME STATE ADDRESS AUTOSTART
  for vm in $(cfg_req VMS); do
    local info; info="$(virsh -c qemu:///system dominfo "$vm" 2>/dev/null || true)"
    printf '%-10s %-10s %-12s %s\n' "$vm" "$(_vm_state "$vm")" "$(vm_ip "$vm")" \
      "$(sed -nE 's/^Autostart:[[:space:]]+//p' <<<"$info")"
  done
}

# vm_exec NAME COMMAND — run a shell command inside the VM as root through
# the QEMU guest agent (no network or SSH needed); prints its output.
vm_exec() {
  local name="$1" cmd="$2" req pid out i
  [[ "$(_vm_state "$name")" == running ]] || die "VM $name is not running"
  virsh -c qemu:///system qemu-agent-command "$name" '{"execute":"guest-ping"}' >/dev/null 2>&1 \
    || die "The guest agent in $name does not answer (still booting or shutting down?)"
  req="$(python3 -c 'import json,sys; print(json.dumps({"execute":"guest-exec","arguments":{"path":"/bin/bash","arg":["-c",sys.argv[1]],"capture-output":True}}))' "$cmd")"
  pid="$(virsh -c qemu:///system qemu-agent-command "$name" "$req" | python3 -c 'import json,sys; print(json.load(sys.stdin)["return"]["pid"])')"
  for i in $(seq 1 600); do
    out="$(virsh -c qemu:///system qemu-agent-command "$name" "{\"execute\":\"guest-exec-status\",\"arguments\":{\"pid\":$pid}}")"
    [[ "$out" == *'"exited":true'* ]] && break
    sleep 0.5
  done
  python3 -c '
import base64, json, sys
r = json.loads(sys.argv[1])["return"]
sys.stdout.write(base64.b64decode(r.get("out-data", "")).decode(errors="replace"))
sys.stderr.write(base64.b64decode(r.get("err-data", "")).decode(errors="replace"))
sys.exit(r.get("exitcode", 1))' "$out"
}

# vm_update NAME — apply the current config (CPU, RAM, GPU mode, …) to an
# existing VM; its disk, identity and NVRAM stay. Takes effect at next boot.
vm_update() {
  local name="$1"; vm_index "$name" >/dev/null
  [[ "$(_vm_state "$name")" != undefined ]] || die "VM $name does not exist"
  log_step "Update VM $name from the config"
  _vm_define "$name"
  run chmod 0600 "$DATA_DIR/vms/$name.qcow2"
  if [[ "$(_vm_state "$name")" == running ]]; then
    _vm_ssh_access "$name"
    log_info "$name is running — the new settings apply after: sudo ./setup.sh vm restart $name"
  fi
  log_ok "VM $name redefined"
}

# vm_restart NAME [--force] — clean shutdown (guest agent, else ACPI), then
# start (e.g. after `vm update`); --force powers a hung VM off hard.
vm_restart() {
  local name="$1" force="${2:-}" waited=0
  vm_index "$name" >/dev/null
  if [[ "$(_vm_state "$name")" == running && "$force" == --force ]]; then
    _virsh destroy "$name"
  elif [[ "$(_vm_state "$name")" == running ]]; then
    _virsh shutdown "$name" --mode agent,acpi
    while [[ "$(_vm_state "$name")" != "shut off" ]]; do
      if (( waited >= 180 )); then die "$name did not shut down within 3 min (hung? then: vm restart $name --force)"; fi
      sleep 2; waited=$((waited + 2))
    done
  fi
  _vm_start "$name"
  waited=0
  until timeout 2 bash -c ">/dev/tcp/$(vm_ip "$name")/3389" 2>/dev/null; do
    if (( waited >= 300 )); then die "$name does not answer RDP after the restart"; fi
    sleep 3; waited=$((waited + 3))
  done
  log_ok "VM $name restarted and answers RDP"
}
