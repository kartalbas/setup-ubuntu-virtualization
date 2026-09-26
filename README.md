# setup-ubuntu-virtualization

One script turns an Ubuntu 26.04 server into a KVM host for remote desktops:

- **Virtualization stack, newest upstream, built from source**: QEMU,
  virglrenderer, libvirt (+ libvirt-dbus, libvirt-python, virt-install),
  Cockpit + cockpit-machines, rdpgw. Versions and checksums are pinned in
  [`versions.conf`](versions.conf); a new stack is swapped in only once it
  built and passed its checks, and the previous one stays for rollback.
- **Ubuntu desktop VMs** built unattended from the official cloud image, reached
  with **native RDP** (GNOME Remote Desktop "Remote Login", no xrdp/VNC),
  desktops rendered by a host GPU (virtio-gpu 3D), RAM reserved per VM, vCPUs
  kept off the host's own CPUs.
- **One public port: 443.** Caddy routes by host name to Cockpit, to an
  RD Gateway (RDP over HTTPS) and to any other local service (e.g. an LLM
  server). Let's Encrypt certificates via TLS-ALPN-01, so port 80 stays closed.
- **Everything on the data disk** (`DATA_DIR`): stack, VM disks, images and
  libvirt's state. The host's own network configuration is never touched.

```
Internet :443 ─► Caddy ─┬─ COCKPIT_HOST ─► Cockpit        (127.0.0.1:9090)
                        ├─ GATEWAY_HOST ─► rdpgw ─► VMs   (NAT, RDP :3389)
                        └─ PROXY_SITES  ─► e.g. LLM server (127.0.0.1:8080)
```

## Setup

Prerequisites: Ubuntu 26.04 server, a mounted data disk, DNS records for the
host names pointing at the public address, and the router forwarding TCP 443
to this machine.

```bash
git clone <this-repo> setup-ubuntu-virtualization
cd setup-ubuntu-virtualization
sudo ./setup.sh init                                # config → /etc/setup-ubuntu-virtualization/
sudo ./setup.sh config set COCKPIT_HOST vm.example.com
sudo ./setup.sh config set GATEWAY_HOST rdp.example.com
sudo ./setup.sh config set VMS "desk1 desk2"        # … every key: config.example.conf
sudo ./setup.sh install                             # host: storage, stack, services, firewall
sudo ./setup.sh vm create desk1                     # ~10–20 min, unattended
sudo ./setup.sh doctor
```

The VM user's password (also used for RDP and the gateway) is generated once:
`sudo cat /etc/setup-ubuntu-virtualization/secrets/vm-user.password`.

## Connect with RDP

In any RDP client with RD Gateway support (Windows `mstsc`, Windows App on
macOS/iOS/Android, Remmina/FreeRDP):

| Setting  | Value                                           |
|----------|-------------------------------------------------|
| Computer | the VM name, e.g. `desk1`                       |
| Gateway  | `GATEWAY_HOST`, "use my gateway credentials for the remote computer" |
| User     | `VM_USER` and its password                      |

You land on the VM's GNOME login screen; log in with the same user.
FreeRDP 3: `xfreerdp3 /v:desk1 /u:vmadmin /gateway:g:rdp.example.com,u:vmadmin,type:auto`.

Browsing to `GATEWAY_HOST` shows "404 page not found": it is not a web page,
only RDP clients talk to it.

## SSH into the VMs

The admin account that runs `sudo ./setup.sh` gets key-based SSH into every VM
as `VM_USER`: just `ssh desk1`. Its ed25519 key is created if missing; the
VMs' host keys are fetched through the guest agent into
`/etc/ssh/ssh_known_hosts`, so there is no fingerprint prompt. Password logins
over SSH are off. `vm create` sets this up; `vm update NAME` repeats it (e.g.
for VMs made before).

## Passwords

`vm create` gives every VM one generated password for the VM login, RDP and
the gateway. Change them afterwards like this:

- **VM login** (per VM, inside it): `passwd`. If GNOME later asks for the
  keyring password, enter the old one once, then change it in "Passwords and
  Keys".
- **RDP** (per VM, inside it): Settings → System → Remote Desktop → Remote
  Login → Unlock → login details. Or in a terminal (asks for the password):

  ```bash
  sudo runuser -u gnome-remote-desktop -- env -i HOME=/var/lib/gnome-remote-desktop PATH=/usr/bin:/bin \
    grdctl rdp set-credentials USER
  ```

  Not `grdctl --system rdp set-credentials USER PASSWORD`: it re-runs itself
  through pkexec, which logs its command line with the password. Check with
  `sudo grdctl --system status --show-credentials` (prints the password).
  Takes effect with the next connection.
- **Gateway** (on the host): `sudo ./setup.sh gateway password` (asked twice).
  New VMs get this password too.

When the gateway and the VM password differ, untick "use my gateway
credentials for the remote computer" in the RDP client and enter both.
`doctor --rdp` logs in with the host's password; once a VM has its own, it
still checks that gateway and tunnel reach the VM, but not the login itself.

## Commands

| Command | What it does |
|---|---|
| `init`, `config show`, `config set KEY VALUE` | machine config (`/etc/setup-ubuntu-virtualization/config.conf`) |
| `install` | all host steps below, in order; idempotent |
| `storage` | `DATA_DIR` layout, `/var/lib/libvirt` bind mount |
| `stack build [--force]` / `activate [ID]` / `rollback` / `status` | build the pinned stack into `DATA_DIR/stack/<id>`, swap it in, roll back |
| `libvirt` | wire the active stack into the system, NAT network, storage pools |
| `cockpit`, `proxy`, `gateway`, `firewall` | the individual services |
| `gateway password` | change the gateway password (see Passwords) |
| `vm create NAME` / `update NAME` / `restart NAME` / `delete NAME --yes` / `list` / `exec NAME CMD` | desktop VMs; `update` applies config changes at the next boot and refreshes SSH access, `restart` reboots cleanly, `exec` runs a command inside (guest agent) |
| `doctor [--rdp]` | check of everything, incl. DNS and certificates; `--rdp` performs real RDP logins, directly and through the gateway |

Every command accepts `--dry-run`.

## Maintenance

- **Update the stack:** bump versions + SHA-256 in `versions.conf`, then
  `sudo ./setup.sh stack build && sudo ./setup.sh stack activate`. Running VMs
  keep running; `stack rollback` returns to the previous stack.
- **Caddy** comes from its official apt repository and updates with the system.
- **Guests** update themselves like any Ubuntu desktop.
- **GPU mode** (`VM_GPU_MODE`): `virgl` (OpenGL, default) or `venus` (OpenGL +
  Vulkan on the host GPU). Venus runs a render server next to QEMU, so it turns
  QEMU's seccomp sandbox off for all VMs. Change it, then `sudo ./setup.sh
  libvirt`, `vm update NAME` and `vm restart NAME`.
- **CPU split** (`HOST_CPUS`): keeps QEMU's I/O and display threads and host
  services (e.g. an LLM server) off the VMs' vCPUs. Measured on 16 cores / 32
  threads with two busy 28-vCPU VMs: the host LLM kept its full token rate;
  without the split, 32 vCPUs each gave the VMs ~12 % more throughput and cost
  the LLM up to ~5 %.

## Layout

```
setup.sh            entry point (commands above)
lib/common.sh       logging, config, templates, downloads
modules/NN-*.sh     one step each: storage, stack, integrate, libvirt, cockpit,
                    proxy, gateway, firewall, vm, doctor
templates/          every file the scripts write (units, profiles, cloud-init)
versions.conf       pinned upstream sources
config.example.conf documented machine config
```
