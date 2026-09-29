# shellcheck shell=bash
# modules/50-proxy.sh — Caddy, the single public entry point on TCP 443.
# Routes by host name: COCKPIT_HOST → Cockpit, GATEWAY_HOST → rdpgw,
# PROXY_SITES → any HTTP upstream (streamed). Certificates via Let's Encrypt
# TLS-ALPN-01 on 443 itself, so port 80 is neither needed nor opened.

GATEWAY_PORT=3443     # rdpgw, reachable from Caddy on localhost only

_caddy_install() {
  local key=/etc/apt/keyrings/caddy-stable.gpg tmp fprs
  if [[ ! -f "$key" ]]; then
    tmp="$(mktemp)"
    run curl -fsSL -o "$tmp" "$(ver_get CADDY_APT_KEY_URL)"
    fprs="$(gpg --show-keys --with-colons "$tmp" 2>/dev/null | awk -F: '/^fpr/{print $10}')"
    [[ "$fprs" == *"$(ver_get CADDY_APT_KEY_FPR)"* ]] || { rm -f "$tmp"; die "Caddy apt key fingerprint mismatch"; }
    run install -d -m 0755 /etc/apt/keyrings
    gpg --dearmor <"$tmp" | atomic_write "$key" 0644
    rm -f "$tmp"
  fi
  printf 'Types: deb\nURIs: %s\nSuites: any-version\nComponents: main\nSigned-By: %s\n' \
    "$(ver_get CADDY_APT_URI)" "$key" | atomic_write /etc/apt/sources.list.d/caddy-stable.sources 0644
  if (( CHANGED )) || ! have caddy; then
    run apt-get update -q
    DEBIAN_FRONTEND=noninteractive run apt-get install -y -q caddy
  fi
}

# proxy_hosts — every host name Caddy serves, one per line.
proxy_hosts() {
  local pair
  cfg_req COCKPIT_HOST; echo
  cfg_req GATEWAY_HOST; echo
  for pair in $(cfg_get PROXY_SITES); do echo "${pair%%=*}"; done
}
proxy_has_cert() { [[ -n "$(find /var/lib/caddy -path '*certificates*' -name "$1.crt" -print -quit 2>/dev/null)" ]]; }

# _site HOST UPSTREAM — one reverse-proxy site block, responses streamed.
# A reload closes open streams (WebSockets: RDP through the gateway, Cockpit)
# right away by default; stream_close_delay keeps them for up to a day.
_site() {
  printf '%s {\n\timport acme_tls_alpn\n\treverse_proxy %s {\n\t\tflush_interval -1\n\t\tstream_close_delay 24h\n\t}\n}\n\n' "$1" "$2"
}

proxy_setup() {
  if [[ -n "$(cfg_get ENTRY_HOST)" ]]; then
    log_info "Caddy: not on this host — $(cfg_get ENTRY_HOST) is the entry point (ENTRY_HOST)"; return 0
  fi
  log_step "Caddy on :443"
  _caddy_install
  local email sites="" pair
  email="$(cfg_get ACME_EMAIL)"
  ACME_EMAIL_LINE="# no ACME contact address (ACME_EMAIL) configured"
  [[ -n "$email" ]] && ACME_EMAIL_LINE="email $email"
  sites+="$(_site "$(cfg_req COCKPIT_HOST)" 127.0.0.1:9090)"$'\n\n'
  sites+="$(_site "$(cfg_req GATEWAY_HOST)" "127.0.0.1:$GATEWAY_PORT")"$'\n\n'
  for pair in $(cfg_get PROXY_SITES); do
    [[ "$pair" == *=* ]] || die "PROXY_SITES entry '$pair' is not HOST=UPSTREAM"
    sites+="$(_site "${pair%%=*}" "${pair#*=}")"$'\n\n'
  done
  PROXY_SITE_BLOCKS="$sites"
  render Caddyfile | caddy fmt - | atomic_write /etc/caddy/Caddyfile 0644
  local changed=$CHANGED
  run caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
  run systemctl enable --now caddy
  if (( changed )); then run systemctl reload caddy; fi
  # Caddy retries failed certificate requests with a growing back-off; once
  # DNS and the port forward are in place, a (forced) reload asks right away —
  # and unlike a restart it keeps open connections.
  local h missing=() waited=0
  while read -r h; do proxy_has_cert "$h" || missing+=("$h"); done < <(proxy_hosts)
  if (( ${#missing[@]} )) && [[ "$DRY_RUN" != 1 ]]; then
    log_info "No certificate yet for ${missing[*]} — asking Let's Encrypt now"
    run systemctl reload caddy
    while (( waited < 90 )); do
      missing=()
      while read -r h; do proxy_has_cert "$h" || missing+=("$h"); done < <(proxy_hosts)
      (( ${#missing[@]} )) || break
      sleep 3; waited=$((waited + 3))
    done
    if (( ${#missing[@]} )); then
      log_warn "Still no certificate for ${missing[*]}: check DNS (→ this host's public address) and that TCP 443 is forwarded here; see journalctl -u caddy"
    fi
  fi
  log_ok "Caddy serves: $(proxy_hosts | tr '\n' ' ')"
}
