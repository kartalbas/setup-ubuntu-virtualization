# shellcheck shell=bash
# modules/05-host.sh — the host's own name (HOST_NAME): hostnamectl and the
# 127.0.1.1 line in /etc/hosts, so names resolve and sudo stays quiet.

# host_name_valid NAME — one DNS label: letters, digits, inner hyphens.
host_name_valid() { [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]]; }

host_setup() {
  local name; name="$(cfg_get HOST_NAME)"
  [[ -n "$name" ]] || return 0
  host_name_valid "$name" || die "HOST_NAME is no valid host name: $name"
  log_step "Host name $name"
  [[ "$(hostnamectl --static)" == "$name" ]] || run hostnamectl set-hostname "$name"
  if grep -qE '^127\.0\.1\.1[[:space:]]' /etc/hosts; then
    awk -v n="$name" '/^127\.0\.1\.1[[:space:]]/ { print "127.0.1.1 " n; next } { print }' /etc/hosts \
      | atomic_write /etc/hosts 0644
  else
    { cat /etc/hosts; echo "127.0.1.1 $name"; } | atomic_write /etc/hosts 0644
  fi
  log_ok "This host is $(hostnamectl --static)"
}
