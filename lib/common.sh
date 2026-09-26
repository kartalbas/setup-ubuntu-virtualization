# shellcheck shell=bash
# lib/common.sh — logging, command execution, privileges, config and file
# helpers shared by setup.sh and every module.
[[ -n "${_COMMON_SH_LOADED:-}" ]] && return 0
_COMMON_SH_LOADED=1

set -Eeuo pipefail
# The last element of a pipeline runs in this shell, so `render | atomic_write`
# can report CHANGED back.
shopt -s lastpipe
# `&` in ${var//pat/repl} must stay a literal (bash 5.2 default is on).
shopt -u patsub_replacement

# ---- logging ---------------------------------------------------------------
if [[ -t 2 ]]; then
  C_RST=$'\e[0m' C_BOLD=$'\e[1m' C_DIM=$'\e[2m' C_RED=$'\e[31m'
  C_GRN=$'\e[32m' C_YEL=$'\e[33m' C_BLU=$'\e[34m' C_CYN=$'\e[36m'
else
  C_RST='' C_BOLD='' C_DIM='' C_RED='' C_GRN='' C_YEL='' C_BLU='' C_CYN=''
fi

log_info() { printf '%s•%s %s\n' "$C_BLU" "$C_RST" "$*" >&2; }
log_ok()   { printf '%s✓%s %s\n' "$C_GRN" "$C_RST" "$*" >&2; }
log_warn() { printf '%s!%s %s\n' "$C_YEL" "$C_RST" "$*" >&2; }
log_err()  { printf '%s✗%s %s\n' "$C_RED" "$C_RST" "$*" >&2; }
log_step() { printf '\n%s━━ %s%s\n' "$C_BOLD$C_CYN" "$*" "$C_RST" >&2; }
die()      { log_err "$*"; exit 1; }
have()     { command -v "$1" >/dev/null 2>&1; }

_on_err() {
  local rc=$? line=${BASH_LINENO[0]} src=${BASH_SOURCE[1]:-?}
  log_err "Failed (exit $rc) at ${src##*/}:$line: ${BASH_COMMAND}"
}
trap _on_err ERR

# run CMD... — echo the command, then execute it (skipped under --dry-run).
DRY_RUN="${DRY_RUN:-0}"
run() {
  printf '%s  ▶ %s%s\n' "$C_DIM" "$*" "$C_RST" >&2
  [[ "$DRY_RUN" == 1 ]] && return 0
  "$@"
}

# ---- privileges ------------------------------------------------------------
# Builds run as the invoking (non-root) user; installation runs as root.
INVOKING_USER="${SUDO_USER:-$(id -un)}"

require_root() { [[ $EUID -eq 0 ]] || die "Run as root: sudo $0 $*"; }
as_user() {
  if [[ $EUID -eq 0 && "$INVOKING_USER" != root ]]; then
    run sudo -u "$INVOKING_USER" -H -- "$@"
  else
    run "$@"
  fi
}

# ---- config ----------------------------------------------------------------
# KEY="value" lines, parsed (never sourced) into CFG.
CONFIG_FILE="${CONFIG_FILE:-/etc/setup-ubuntu-virtualization/config.conf}"
declare -gA CFG=()

_parse_kv_file() { # FILE ARRAY_NAME
  local -n _dst="$2"
  local line k v
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
    [[ "$line" == *=* ]] || continue
    k="${line%%=*}"; v="${line#*=}"
    k="${k//[[:space:]]/}"
    [[ "$k" =~ ^[A-Z_][A-Z0-9_]*$ ]] || continue
    v="${v%\"}"; v="${v#\"}"
    _dst["$k"]="$v"
  done <"$1"
}

cfg_load() {
  CFG=()
  [[ -f "$CONFIG_FILE" ]] || die "No config at $CONFIG_FILE — copy config.example.conf there (mode 0600) and edit it."
  _parse_kv_file "$CONFIG_FILE" CFG
}
cfg_get() { printf '%s' "${CFG[$1]:-${2-}}"; }

# cfg_init — install config.example.conf as the machine config (once).
cfg_init() {
  if [[ -f "$CONFIG_FILE" ]]; then log_ok "$CONFIG_FILE exists — kept"; return 0; fi
  run install -d -m 0755 "$(dirname "$CONFIG_FILE")"
  run install -m 0600 "$REPO_ROOT/config.example.conf" "$CONFIG_FILE"
  log_ok "Created $CONFIG_FILE — set your values with: sudo ./setup.sh config set KEY VALUE"
}

# cfg_set KEY VALUE — change one key in place (comments and order stay).
cfg_set() {
  local key="$1" val="$2"
  grep -qE "^${key}=" "$REPO_ROOT/config.example.conf" || die "Unknown config key: $key (see config.example.conf)"
  [[ "$val" != *'"'* && "$val" != *$'\n'* ]] || die "Config values must not contain quotes or newlines"
  [[ -f "$CONFIG_FILE" ]] || die "No config yet — run: sudo ./setup.sh init"
  local line="${key}=\"${val}\""
  if grep -qE "^${key}=" "$CONFIG_FILE"; then
    awk -v k="$key" -v l="$line" 'index($0, k "=") == 1 { print l; next } { print }' "$CONFIG_FILE" \
      | atomic_write "$CONFIG_FILE" 0600
  else
    { cat "$CONFIG_FILE"; echo "$line"; } | atomic_write "$CONFIG_FILE" 0600
  fi
}
cfg_req() { [[ -n "${CFG[$1]:-}" ]] || die "Config key $1 is empty in $CONFIG_FILE"; printf '%s' "${CFG[$1]}"; }

# Pinned upstream versions and checksums (versions.conf, part of the repo).
declare -gA VER=()
ver_load() { _parse_kv_file "$REPO_ROOT/versions.conf" VER; }
ver_get() { [[ -n "${VER[$1]:-}" ]] || die "versions.conf has no $1"; printf '%s' "${VER[$1]}"; }

# ---- files -----------------------------------------------------------------
# atomic_write PATH [MODE] — write stdin to PATH via a temp file in the same
# directory. Sets CHANGED=1 when the content differs from what was there.
CHANGED=0
atomic_write() {
  local path="$1" mode="${2:-0644}" tmp
  CHANGED=0
  if [[ "$DRY_RUN" == 1 ]]; then
    printf '%s  ▶ write %s (mode %s)%s\n' "$C_DIM" "$path" "$mode" "$C_RST" >&2
    cat >/dev/null; return 0
  fi
  mkdir -p "$(dirname "$path")"
  tmp="$(mktemp "$(dirname "$path")/.tmp.XXXXXX")"
  cat >"$tmp"
  chmod "$mode" "$tmp"
  if [[ -f "$path" ]] && cmp -s "$tmp" "$path" && [[ "$(stat -c %a "$path")" == "${mode#0}" ]]; then
    rm -f "$tmp"; return 0
  fi
  mv -f "$tmp" "$path"
  CHANGED=1
  log_ok "Wrote $path"
}

# render TEMPLATE — replace @KEY@ placeholders with the values of the shell
# variables of the same name; fails on any placeholder left unresolved.
render() {
  local tpl="$REPO_ROOT/templates/$1" out key
  out="$(<"$tpl")"
  while [[ "$out" =~ @([A-Z_][A-Z0-9_]*)@ ]]; do
    key="${BASH_REMATCH[1]}"
    [[ -v "$key" ]] || die "Template $1: no value for @$key@"
    out="${out//@"$key"@/${!key}}"
  done
  printf '%s\n' "$out"
}

# download URL SHA256 DEST — fetch once into the source cache, verify always.
download() {
  local url="$1" sum="$2" dest="$3"
  if [[ ! -f "$dest" ]]; then
    run curl -fL --retry 3 -o "$dest.part" "$url"
    [[ "$DRY_RUN" == 1 ]] || mv -f "$dest.part" "$dest"
  fi
  [[ "$DRY_RUN" == 1 ]] && return 0
  echo "$sum  $dest" | sha256sum -c --quiet - \
    || die "Checksum mismatch for $dest (expected $sum) — delete it and check versions.conf"
}

apt_install() {
  local missing=() p
  for p in "$@"; do
    [[ "$(dpkg-query -W -f='${Status}' "$p" 2>/dev/null)" == *"ok installed"* ]] || missing+=("$p")
  done
  (( ${#missing[@]} )) || return 0
  run apt-get update -q
  DEBIAN_FRONTEND=noninteractive run apt-get install -y -q --no-install-recommends "${missing[@]}"
}
