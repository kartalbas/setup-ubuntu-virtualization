#!/usr/bin/env bash
# tests/run.sh — lint + unit tests of the pure helpers. Needs no root and
# changes nothing on the machine. Requires shellcheck.
# `cond && ok … || bad …` is safe here: ok/bad always succeed.
# shellcheck disable=SC2015
set -uo pipefail
cd "$(dirname "$0")/.."
REPO_ROOT="$PWD"
pass=0 fail=0
ok()  { pass=$((pass + 1)); printf '  ✓ %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  ✗ %s\n' "$1"; }
eq()  { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1: expected [$3], got [$2]"; fi; }

echo "shellcheck"
if shellcheck -x -s bash setup.sh lib/*.sh modules/*.sh tests/run.sh; then ok "clean"; else bad "findings above"; fi

# Load the library and modules in a subshell-safe way, with a scratch config.
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
CONFIG_FILE="$tmp/config.conf"
cp config.example.conf "$CONFIG_FILE"
# shellcheck source=lib/common.sh
. lib/common.sh
set +e; trap - ERR
for m in modules/*.sh; do
  # shellcheck source=/dev/null
  . "$m"
done
cfg_load; ver_load

echo "config"
cfg_set VMS "alpha beta" >/dev/null 2>&1; cfg_load
eq "cfg_set changes a key in place" "$(cfg_get VMS)" "alpha beta"
eq "cfg_set keeps the comments" "$(grep -c '^#' "$CONFIG_FILE")" "$(grep -c '^#' config.example.conf)"
( cfg_set NO_SUCH_KEY x ) >/dev/null 2>&1 && bad "cfg_set rejects unknown keys" || ok "cfg_set rejects unknown keys"
( cfg_set VMS 'a"b' ) >/dev/null 2>&1 && bad "cfg_set rejects quotes" || ok "cfg_set rejects quotes"

echo "versions"
while read -r k; do
  p="${k%_VERSION}"
  [[ -n "$(ver_get "${p}_URL")" && "$(ver_get "${p}_SHA256")" =~ ^[0-9a-f]{64}$ ]] \
    && ok "$p has URL + SHA-256" || bad "$p lacks URL or SHA-256"
done < <(grep -hoE '^[A-Z_]+_VERSION' versions.conf tools.conf)
eq "stack id is stable" "$(stack_id)" "$(stack_id)"
before="$(stack_id)"; VER[LEGO_VERSION]="0.0.0"
grep -q '^LEGO_' versions.conf && bad "lego is pinned in versions.conf (it would change the stack id)" || ok "lego is pinned beside the stack (tools.conf), not in it"
eq "the stack id ignores tools.conf" "$(stack_id)" "$before"


echo "cpu sets"
eq "_cpu_list_expand" "$(_cpu_list_expand "0-3,8,10-11")" "0 1 2 3 8 10 11"
eq "_cpuset_minus 16c/32t minus two cores" "$(_cpuset_minus 0-31 0,1,16,17)" "2-15,18-31"
eq "_cpuset_minus single CPUs" "$(_cpuset_minus 0-5 1,3)" "0,2,4-5"
( _cpuset_minus 0-3 0-3 ) >/dev/null 2>&1 && bad "_cpuset_minus refuses an empty set" || ok "_cpuset_minus refuses an empty set"

echo "host name"
host_name_valid master2 && ok "a plain name is valid" || bad "a plain name is refused"
host_name_valid my-host-1 && ok "inner hyphens are valid" || bad "inner hyphens are refused"
for n in "-x" "x-" "a.b" "a b" ""; do host_name_valid "$n" && bad "\"$n\" is accepted" || ok "\"$n\" is refused"; done

echo "proxy"
[[ "$(_site a.example 127.0.0.1:1)" == *"stream_close_delay 24h"* ]] && ok "sites keep open streams on reload" || bad "sites close streams on reload"
( configs_run ) >/dev/null 2>&1 && bad "configs needs CONFIGS_REPO" || ok "configs needs CONFIGS_REPO"

echo "VM identity"
eq "vm_ip follows the VMS order" "$(vm_ip beta)" "10.77.0.12"
[[ "$(vm_mac alpha)" =~ ^52:54:00(:[0-9a-f]{2}){3}$ ]] && ok "vm_mac is a KVM MAC" || bad "vm_mac format: $(vm_mac alpha)"
eq "vm_mac is deterministic" "$(vm_mac alpha)" "$(vm_mac alpha)"
[[ "$(vm_mac alpha)" != "$(vm_mac beta)" ]] && ok "vm_mac differs per VM" || bad "vm_mac collides"
( vm_ip gamma ) >/dev/null 2>&1 && bad "vm_ip rejects unknown VMs" || ok "vm_ip rejects unknown VMs"

echo "VM swap"
CFG[VM_SWAP_GB]=16; eq "VM_SWAP_GB 16: cloud-init size 16G" "$(vm_swap_size)" "16G"
CFG[VM_SWAP_GB]=0; eq "VM_SWAP_GB 0: no swap file" "$(vm_swap_size)" "0"
unset 'CFG[VM_SWAP_GB]'; eq "VM_SWAP_GB not set: 16G" "$(vm_swap_size)" "16G"
CFG[VM_SWAP_GB]=16G; ( vm_swap_size ) >/dev/null 2>&1 && bad "VM_SWAP_GB=16G accepted" || ok "VM_SWAP_GB with a unit is refused"
unset 'CFG[VM_SWAP_GB]'
if python3 -c 'import yaml' 2>/dev/null; then
  VM_NAME=v VM_LOCALE=l VM_TIMEZONE=t VM_KEYBOARD=k VM_KEYBOARD_VARIANT="" VM_USER=u VM_PASSWORD_HASH=h \
    VM_SSH_KEY=s VM_PASSWORD=p VM_DESKTOP_PACKAGE=d VM_SWAP_SIZE=16G
  eq "user-data is YAML with the swap file" \
    "$(render user-data.yaml | python3 -c 'import sys, yaml; s = yaml.safe_load(sys.stdin)["swap"]; print(s["filename"], s["size"], s["maxsize"])')" "/swap.img 16G 16G"
else
  echo "  - skipped: no python3-yaml here"
fi

echo "storage"
mkdir -p "$tmp/disk"
eq "a DATA_DIR not made yet is checked on its nearest existing parent" "$(existing_parent "$tmp/disk/virt/stack")" "$tmp/disk"
eq "an existing path is itself" "$(existing_parent "$tmp/disk")" "$tmp/disk"

echo "two hosts: VMs on the LAN, entry point elsewhere"
CFG[VM_LAN]=eth9 CFG[VM_LAN_ADDRESSES]="192.168.1.201 192.168.1.202"
eq "VM_LAN: vm_ip is the VM's LAN address" "$(vm_ip beta)" "192.168.1.202"
CFG[VM_LAN_ADDRESSES]="192.168.1.201"; ( vm_ip beta ) >/dev/null 2>&1 && bad "a VM without LAN address accepted" || ok "a VM without LAN address is refused"
[[ "$(_vm_nic_xml 52:54:00:aa:bb:cc)" == *"<interface type='direct'>"*"<source dev='eth9' mode='bridge'/>"*"52:54:00:aa:bb:cc"* ]] \
  && ok "VM_LAN: the NIC is macvtap on the LAN interface" || bad "LAN NIC: $(_vm_nic_xml 52:54:00:aa:bb:cc)"
# shellcheck disable=SC2329  # stub: the host's interface
vm_lan_net() { printf '24 192.168.1.1 192.168.1.53'; }
if python3 -c 'import yaml' 2>/dev/null; then
  VM_MAC=52:54:00:aa:bb:cc VM_NET_V4="$(_vm_net_v4 alpha)"
  eq "VM_LAN: cloud-init gives the VM its fixed address, gateway and DNS" \
    "$(render network-config.yaml | python3 -c 'import sys, yaml; n = yaml.safe_load(sys.stdin); e = n["ethernets"]["lan"]; print(n["renderer"], e["addresses"], e["routes"][0]["via"], e["nameservers"]["addresses"], "dhcp4" in e)')" \
    "networkd ['192.168.1.201/24'] 192.168.1.1 ['192.168.1.53'] False"
fi
CFG[VM_LAN]="" CFG[VM_LAN_ADDRESSES]=""
[[ "$(_vm_nic_xml 52:54:00:aa:bb:cc)" == *"<source network='$(cfg_get NAT_NAME)'/>"* ]] && ok "no VM_LAN: the NIC is on the NAT network" || bad "NAT NIC"
eq "no VM_LAN: DHCP (the reservation)" "$(_vm_net_v4 alpha)" "    dhcp4: true"
CFG[RDP_CERT_DOMAIN]="host.example.com"
eq "RDP certificate name: VM.RDP_CERT_DOMAIN" "$(rdp_cert_name alpha)" "alpha.host.example.com"
eq "the gateway lets each VM through by its certificate's name too" "$(gateway_vms | tr '\n' ',')" \
  "alpha 10.77.0.11,alpha.host.example.com 10.77.0.11,beta 10.77.0.12,beta.host.example.com 10.77.0.12,"
CFG[RDP_CERT_DOMAIN]=""
eq "no RDP_CERT_DOMAIN: no certificate name" "$(rdp_cert_name alpha)" ""
CFG[REMOTE_VMS]="desk3=192.168.1.201"
eq "the gateway lets this host's and other hosts' VMs through" "$(gateway_vms | tr '\n' ',')" "alpha 10.77.0.11,beta 10.77.0.12,desk3 192.168.1.201,"
CFG[REMOTE_VMS]="desk3"; ( gateway_vms ) >/dev/null 2>&1 && bad "REMOTE_VMS without address accepted" || ok "REMOTE_VMS entries need NAME=ADDRESS"
CFG[REMOTE_VMS]="desk3=192.168.1.201"
( STACK_CURRENT=/s DATA_DIR=/d GATEWAY_ALLOW="localhost 10.77.0.11 10.77.0.12 192.168.1.201"
  render rdpgw.service | grep -qx 'IPAddressAllow=localhost 10.77.0.11 10.77.0.12 192.168.1.201' ) \
  && ok "rdpgw may reach its VMs, other hosts' too (systemd IPAddressAllow)" || bad "rdpgw.service IPAddressAllow"
CFG[REMOTE_VMS]=""
( STACK_CURRENT=/s GATEWAY_HOST=g GATEWAY_HOSTS="" SESSION_KEY=k SESSION_ENC_KEY=k PAA_SIGN_KEY=k PAA_ENC_KEY=k
  render rdpgw.yaml | grep -A3 '^  Authentication:' | grep -qx '    - local' ) \
  && ok "the gateway offers Basic beside NTLM (Windows App on macOS/iOS/Android)" || bad "rdpgw.yaml: no local authentication"
( STACK_CURRENT=/s DATA_DIR=/d GATEWAY_CONF_DIR=/c; render rdpgw-auth.service | grep -qx 'LoadCredential=rdpgw-basic.passwd:/c/rdpgw-basic.passwd' ) \
  && grep -q 'pwdfile=/run/credentials/rdpgw-auth.service/rdpgw-basic.passwd' templates/rdpgw.pam \
  && ok "PAM reads the hash from the credential rdpgw-auth receives" || bad "rdpgw-auth credential and PAM pwdfile differ"
( STACK_CURRENT=/s GATEWAY_HOST=g GATEWAY_HOSTS="" SESSION_KEY=k SESSION_ENC_KEY=k PAA_SIGN_KEY=k PAA_ENC_KEY=k
  render rdpgw.yaml | grep -qx '  CertFile: /run/credentials/rdpgw.service/rdpgw-tls.crt' ) \
  && ( STACK_CURRENT=/s DATA_DIR=/d GATEWAY_CONF_DIR=/c GATEWAY_ALLOW=localhost; render rdpgw.service | grep -qx 'LoadCredential=rdpgw-tls.key:/c/rdpgw-tls.key' ) \
  && ok "rdpgw speaks TLS with its own certificate (Basic needs it)" || bad "rdpgw TLS: CertFile or credential missing"
gw="$(_gateway_site rdp.example.com)"
[[ "$gw" == *"reverse_proxy https://127.0.0.1:$GATEWAY_PORT"* && "$gw" == *"tls_trust_pool file $GATEWAY_TLS_CRT"* && "$gw" == *"versions 1.1"* ]] \
  && ok "Caddy reaches rdpgw over TLS, trusting rdpgw's certificate alone" || bad "gateway site: $gw"
if command -v caddy >/dev/null; then
  ( ACME_EMAIL_LINE="#" PROXY_SITE_BLOCKS="$gw"; render Caddyfile ) | caddy adapt --adapter caddyfile --config /dev/stdin >/dev/null 2>&1 \
    && ok "Caddy accepts the gateway site" || bad "caddy adapt refuses the gateway site"
fi
l1="$(_gateway_basic_line vmadmin 'pass word 1')"
# shellcheck disable=SC2016  # a literal $6$, the crypt prefix
[[ "$l1" == 'vmadmin:$6$'* ]] && ok "Basic: a SHA-512 crypt hash for VM_USER" || bad "Basic line: $l1"
eq "Basic: the same password keeps its line (no restart on every run)" "$(_gateway_basic_line vmadmin 'pass word 1' "$l1")" "$l1"
[[ "$(_gateway_basic_line vmadmin 'changed' "$l1")" != "$l1" ]] && ok "Basic: a new password gives a new line" || bad "Basic: new password kept the old hash"
eq "entry point: Cockpit on localhost only" "$(_cockpit_listen | grep -c '^ListenStream=127.0.0.1:9090$')" "1"
CFG[ENTRY_HOST]=192.168.1.250
[[ "$(_cockpit_listen)" == *"ListenStream=0.0.0.0:9090"*"IPAddressDeny=any"*"IPAddressAllow=localhost 192.168.1.250"* ]] \
  && ok "ENTRY_HOST: Cockpit on the LAN, for the entry point and this host only" || bad "cockpit listen: $(_cockpit_listen)"
# shellcheck disable=SC2329  # stubs: nothing may be installed or started
_caddy_install() { echo caddy >>"$tmp/called"; }
# shellcheck disable=SC2329
apt_install() { echo apt >>"$tmp/called"; }
: >"$tmp/called"; proxy_setup 2>/dev/null; gateway_setup 2>/dev/null
eq "ENTRY_HOST: no Caddy and no gateway here" "$(wc -l <"$tmp/called")" "0"
CFG[ENTRY_HOST]=""
CFG[FIREWALL]=0; : >"$tmp/called"; firewall_setup 2>/dev/null
eq "FIREWALL=0: the firewall is left alone" "$(wc -l <"$tmp/called")" "0"
unset 'CFG[FIREWALL]'

echo "templates"
NAT_NAME=n NAT_BRIDGE=b NAT_PREFIX=10.0.0
eq "render fills placeholders" "$(render network.xml | grep -c "<name>n</name>")" "1"
( unset NAT_BRIDGE; render network.xml ) >/dev/null 2>&1 && bad "render fails on a missing value" || ok "render fails on a missing value"
X="a&b"; printf '@X@' >"$tmp/t"; mkdir -p "$tmp/templates"; cp "$tmp/t" "$tmp/templates/t"
eq "render keeps & literal" "$(REPO_ROOT="$tmp" render t)" "a&b"
for t in templates/*; do
  n="$(grep -oE '@[A-Z_][A-Z0-9_]*@' "$t" | sort -u | wc -l)"
  [[ -f "$t" ]] && ok "$(basename "$t"): $n placeholders"
done

echo
echo "$pass passed, $fail failed"
(( fail == 0 ))
