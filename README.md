# setup-ubuntu-virtualization

One script turns an Ubuntu 26.04 server into a KVM host for remote desktops:

- **Virtualization stack, newest upstream, built from source**: QEMU,
  virglrenderer, libvirt (+ libvirt-dbus, libvirt-python, virt-install),
  Cockpit + cockpit-machines, rdpgw. Versions and checksums are pinned in
  [`versions.conf`](versions.conf); a new stack is swapped in only once it
  built and passed its checks, and the previous one stays for rollback.
- **Ubuntu desktop VMs** built unattended from the official cloud image (with
  a swap file, as the installer makes one: `VM_SWAP_GB`), reached
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

The gateway takes both ways clients sign in: `mstsc` uses NTLM, the Windows
App on macOS, iOS and Android HTTP Basic (it has no NTLM). Basic is checked by
rdpgw-auth through PAM (`pam_pwdfile`) against a hash of the same password,
never against the host's own accounts. rdpgw allows Basic only with TLS of its
own, so Caddy reaches it over TLS too, trusting exactly rdpgw's certificate for
127.0.0.1.

You land on the VM's GNOME login screen; log in with the same user.
FreeRDP 3: `xfreerdp3 /v:desk1 /u:vmadmin /gateway:g:rdp.example.com,u:vmadmin,type:auto`.

Browsing to `GATEWAY_HOST` shows "404 page not found": it is not a web page,
only RDP clients talk to it.

### Public certificates for the VMs (`RDP_CERT_DOMAIN`)

An RDP client checks the certificate of the computer it connects to, also
through the gateway. GNOME Remote Desktop's own is self-signed: clients warn,
and Windows refuses saved passwords for such a computer. With
`RDP_CERT_DOMAIN="host.example.com"` every VM presents a Let's Encrypt
certificate for `VM.host.example.com`; enter that name as the computer. The
gateway lets the VM through by both names.

- The certificates come from lego (pinned in `tools.conf`) with the DNS-01
  challenge at Cloudflare: nothing has to reach the host from outside, so a
  host behind another host's entry point gets them too. Put an API token
  allowed to edit the zone's DNS ("Edit zone DNS", that zone only) into
  `secrets/cloudflare-dns.token` (one line, root only; `configs save` keeps it).
- `sudo ./setup.sh certs` obtains them, gives each running VM its own through
  the guest agent and installs a daily timer that renews and deploys them
  (`certs renew`). GNOME Remote Desktop takes a new certificate at once,
  without a restart; open sessions stay.
- The name need not lead anywhere: the client reaches the VM through the
  gateway, the name is only its identity. `doctor` checks that each VM
  presents its certificate with 14 days left and that the timer is on.

## SSH into the VMs

The admin account that runs `sudo ./setup.sh` gets key-based SSH into every VM
as `VM_USER`: just `ssh desk1`. Its ed25519 key is created if missing; the
VMs' host keys are fetched through the guest agent into
`/etc/ssh/ssh_known_hosts`, so there is no fingerprint prompt. Password logins
over SSH are off. `vm create` sets this up; `vm update NAME` repeats it (e.g.
for VMs made before).

## Two hosts, one entry point

A second machine can run VMs too while the first stays the only public entry
point, e.g. when port 443 of the second one belongs to something else, such as
a Kubernetes ingress. Nothing of the second machine is published directly:

```
Internet :443 ─► Caddy on the entry point ─┬─ its COCKPIT_HOST ─► its Cockpit
                                           ├─ PROXY_SITES ─► second host :9090  (its Cockpit, LAN)
                                           └─ GATEWAY_HOST ─► rdpgw ─┬─ its VMs (NAT)
                                                                     └─ REMOTE_VMS ─► the second host's VMs (LAN)
```

On the **second host**:

| Key | Value |
|---|---|
| `ENTRY_HOST` | the entry point's LAN address: no Caddy and no gateway here; Cockpit listens on :9090 for that address and this host alone (systemd `IPAddressAllow`, no firewall rule) |
| `COCKPIT_HOST`, `GATEWAY_HOST` | the names the entry point serves for it |
| `VM_LAN`, `VM_LAN_ADDRESSES` | the VMs straight on the LAN (macvtap), each with a fixed address; prefix, gateway and DNS are the host's own on that interface; no NAT network |
| `FIREWALL` | `0` leaves the host's packet filter alone, e.g. on a Kubernetes node whose network plugin owns it |
| `HOST_CPUS` | empty: the VMs' vCPUs and the host share all CPUs |

On the **entry point**, `PROXY_SITES` gets `SECOND-COCKPIT-HOST=SECOND-HOST:9090` and
`REMOTE_VMS` the second host's VMs as `NAME=ADDRESS`; `sudo ./setup.sh proxy` and
`sudo ./setup.sh gateway` apply them. RDP to such a VM goes through the same
gateway, with the VM name as computer. The gateway checks its password and the
VM its own, so give both hosts the same VM password (the config repository keeps
it per host in `secrets/vm-user.password`).

`REMOTE_VMS` takes any RDP server the gateway should let through, also one on
another port: `NAME=ADDRESS:PORT`, and the client enters `NAME:PORT` as the
computer.

Macvtap leaves the second host's network as it is, but that host itself cannot
reach its LAN VMs over the network: `vm create`, `vm restart` and `doctor` check
them through the guest agent, `vm exec` works as always, and SSH comes from other
machines (`ssh VM_USER@ADDRESS`; the second host's admin key is in the VM). The
entry point's `doctor --rdp` logs in to them over RDP, directly and through the
gateway. The LAN hop from the entry point to the second host's Cockpit is plain
HTTP, like every other `PROXY_SITES` upstream.

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
| `host` | the host's name (`HOST_NAME`) and its `/etc/hosts` line |
| `storage` | `DATA_DIR` layout, `/var/lib/libvirt` bind mount |
| `stack build [--force]` / `activate [ID]` / `rollback` / `status` | build the pinned stack into `DATA_DIR/stack/<id>`, swap it in, roll back |
| `libvirt` | wire the active stack into the system, NAT network (none with `VM_LAN`), storage pools |
| `cockpit`, `proxy`, `gateway`, `firewall` | the individual services |
| `gateway password` | change the gateway password (see Passwords) |
| `certs [renew]` | Let's Encrypt certificates for the VMs' RDP and their daily renewal (`RDP_CERT_DOMAIN`, above); `renew` only renews and deploys |
| `vm create NAME` / `update NAME` / `restart NAME` / `delete NAME --yes` / `list` / `exec NAME CMD` | desktop VMs; `update` applies config changes at the next boot and refreshes SSH access, `restart` reboots cleanly, `exec` runs a command inside (guest agent) |
| `vm snapshot NAME [TAG]` / `snapshots NAME` / `revert NAME TAG --yes` / `snapshot-delete NAME TAG` | disk snapshots (below) |
| `doctor [--rdp]` | check of everything, incl. DNS and certificates; `--rdp` performs real RDP logins, directly and through the gateway |
| `configs [save]` | this host's settings from / to your own private config repository (below) |

Every command accepts `--dry-run`.

**Snapshots** keep a VM's disk as it is at that moment: `vm snapshot vm2
before-update` (TAG defaults to date and time) is taken while the VM runs —
the guest agent freezes its file systems for it, so the disk is consistent.
From then on the VM writes into an overlay file next to its disk
(`NAME.TAG.qcow2`). `vm revert vm2 before-update --yes` shuts the VM down,
returns its disk to that moment (what it wrote since is gone) and starts it;
`vm snapshot-delete vm2 before-update` merges the overlay down and keeps the
current state. RAM and the UEFI variables are not part of a snapshot. They are
external disk snapshots because libvirt refuses internal ones for UEFI VMs with
a raw NVRAM; `vm update` and `vm delete` follow the overlays.

## Your own config repository

Keep this host's settings in a private repository of your own and put them
back on a rebuilt host with one command. `config.conf` and the VM password
are kept there as they are, so the repository must stay private.

```bash
sudo ./setup.sh config set CONFIGS_REPO OWNER/NAME
sudo ./setup.sh config set CONFIGS_HOST NAME   # only when hosts share a host name
sudo ./setup.sh configs save   # copy this host's files there, commit, push
sudo ./setup.sh configs        # on a rebuilt host (after init): put them back
```

The repository is cloned as you to `~/repos/<owner>/<name>` (sign in to
GitHub first for a private one); this host's files are in
`setup-ubuntu-virtualization/hosts/<CONFIGS_HOST>/`.

## Maintenance

- **Update the stack:** bump versions + SHA-256 in `versions.conf`, then
  `sudo ./setup.sh stack build && sudo ./setup.sh stack activate`. Running VMs
  keep running; `stack rollback` returns to the previous stack.
- **Caddy** comes from its official apt repository and updates with the system.
  `proxy` applies changes with a reload: open connections (RDP through the
  gateway, Cockpit, streamed answers) stay up for up to a day.
- **Guests** update themselves like any Ubuntu desktop.
- **Host reboot** (`VM_HOST_SHUTDOWN`): `suspend` saves running VMs to disk
  and resumes them 1:1 at boot, open programs included; QEMU cannot save 3D
  graphics, so it needs `VM_RENDER_NODE=""` (the desktop is drawn by the CPU).
  `shutdown` (default) shuts them down cleanly and boots them again. After a
  change: `sudo ./setup.sh libvirt`.
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
                    proxy, gateway, certs, firewall, vm, doctor
templates/          every file the scripts write (units, profiles, cloud-init)
versions.conf       pinned upstream sources of the stack
tools.conf          pinned tools beside the stack (lego)
config.example.conf documented machine config
```
