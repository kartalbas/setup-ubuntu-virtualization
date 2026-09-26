# shellcheck shell=bash
# modules/95-configs.sh — this host's settings in your own private config
# repository. CONFIGS_REPO=OWNER/NAME is cloned (as you) to
# ~/repos/<owner>/<name>; this host's files live there, as they are, in
# setup-ubuntu-virtualization/hosts/<CONFIGS_HOST>/ — keep it private.
#   sudo ./setup.sh configs        pull it, put this host's files in place
#   sudo ./setup.sh configs save   copy this host's files back, commit, push

# path below hosts/<name>/ | path on this host
CONFIGS_FILES=(
  "config.conf|$CONFIG_FILE"
  "secrets/vm-user.password|$SECRETS_DIR/vm-user.password"
)

configs_run() { # [save]
  local mode="${1:-apply}" repo host home dir sub entry src dst
  repo="$(cfg_get CONFIGS_REPO)"
  [[ "$repo" == */* ]] || die "No config repository set: sudo ./setup.sh config set CONFIGS_REPO OWNER/NAME"
  [[ "$INVOKING_USER" != root ]] || die "Run it with sudo from your own account: the repository is cloned and pushed as you"
  host="$(cfg_get CONFIGS_HOST)"; host="${host:-$(hostname -s)}"
  home="$(getent passwd "$INVOKING_USER" | cut -d: -f6)"
  dir="$home/repos/$(tr '[:upper:]' '[:lower:]' <<<"${repo%%/*}")/${repo#*/}"
  sub="$dir/setup-ubuntu-virtualization/hosts/$host"
  log_step "This host's settings: $repo, hosts/$host"
  if [[ ! -d "$dir/.git" ]]; then
    as_user mkdir -p "$(dirname "$dir")"
    as_user git clone -q "https://github.com/$repo.git" "$dir" || die "Could not clone $repo (is $INVOKING_USER signed in to GitHub?)"
  fi
  as_user git -C "$dir" pull -q --ff-only || log_warn "$repo not updated (offline or local changes) — using it as it is"
  case "$mode" in
    apply)
      [[ -d "$sub" ]] || die "Nothing saved for $host in $repo yet: sudo ./setup.sh configs save on that host"
      run install -d -m 0755 "$(dirname "$CONFIG_FILE")"
      run install -d -m 0700 "$SECRETS_DIR"
      for entry in "${CONFIGS_FILES[@]}"; do
        src="$sub/${entry%%|*}" dst="${entry#*|}"
        [[ -f "$src" ]] || continue
        atomic_write "$dst" 0600 <"$src"
        log_ok "$dst"
      done ;;
    save)
      for entry in "${CONFIGS_FILES[@]}"; do
        src="${entry#*|}" dst="$sub/${entry%%|*}"
        [[ -f "$src" ]] || continue
        as_user mkdir -p "$(dirname "$dst")"
        cmp -s "$src" "$dst" || run install -m 0600 -o "$INVOKING_USER" -g "$(id -gn "$INVOKING_USER")" "$src" "$dst"
      done
      as_user git -C "$dir" add -A
      if as_user git -C "$dir" diff --cached --quiet; then log_ok "Nothing changed"
      else
        as_user git -C "$dir" commit -q -m "setup-ubuntu-virtualization settings from $host"
        as_user git -C "$dir" push -q && log_ok "Saved to $repo"
      fi ;;
    *) die "configs [save]" ;;
  esac
}
