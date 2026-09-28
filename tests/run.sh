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
done < <(grep -oE '^[A-Z_]+_VERSION' versions.conf)
eq "stack id is stable" "$(stack_id)" "$(stack_id)"

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
