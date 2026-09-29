# shellcheck shell=bash
# modules/40-cockpit.sh — Cockpit (with cockpit-machines) from the stack,
# listening on 127.0.0.1:9090 only; Caddy publishes it as COCKPIT_HOST. With
# ENTRY_HOST (another machine is the entry point) it listens on the LAN, and
# systemd lets only that machine and this host through.

COCKPIT_LISTEN="/etc/systemd/system/cockpit.socket.d/10-listen.conf"
COCKPIT_ENTRY_ONLY="/etc/systemd/system/cockpit.service.d/10-entry-only.conf"

# _cockpit_listen — the socket drop-in: localhost, or the LAN for ENTRY_HOST.
_cockpit_listen() {
  local entry; entry="$(cfg_get ENTRY_HOST)"
  if [[ -n "$entry" ]]; then
    printf '[Socket]\nListenStream=\nListenStream=0.0.0.0:9090\n# Only the entry point (%s) and this host get through.\nIPAddressDeny=any\nIPAddressAllow=localhost %s\n' "$entry" "$entry"
  else
    printf '[Socket]\nListenStream=\nListenStream=127.0.0.1:9090\n'
  fi
}

cockpit_setup() {
  log_step "Cockpit → https://$(cfg_req COCKPIT_HOST)"
  STACK_CURRENT="$(stack_current)" COCKPIT_HOST="$(cfg_req COCKPIT_HOST)"
  render cockpit.pam | atomic_write /etc/pam.d/cockpit 0644
  render cockpit.conf | atomic_write /etc/cockpit/cockpit.conf 0644
  local restart=$CHANGED
  [[ -f /etc/cockpit/disallowed-users ]] || echo root | atomic_write /etc/cockpit/disallowed-users 0644
  # cockpit-machines shows up only if libvirt-dbus's bus policy exists; ours
  # lives in /etc/dbus-1 (admin layer), which its manifest does not look at.
  echo '{ "conditions": [ { "path-exists": "/etc/dbus-1/system.d/org.libvirt.conf" } ] }' \
    | atomic_write /etc/cockpit/machines.override.json 0644
  local reload=0 entry; entry="$(cfg_get ENTRY_HOST)"
  _cockpit_listen | atomic_write "$COCKPIT_LISTEN" 0644; (( CHANGED )) && reload=1
  if [[ -n "$entry" ]]; then
    # The socket passes connections on; the service gets the same list.
    printf '[Service]\nIPAddressDeny=any\nIPAddressAllow=localhost %s\n' "$entry" \
      | atomic_write "$COCKPIT_ENTRY_ONLY" 0644; (( CHANGED )) && reload=1
  elif [[ -f "$COCKPIT_ENTRY_ONLY" ]]; then run rm -f "$COCKPIT_ENTRY_ONLY"; reload=1; fi
  # (earlier versions called the socket drop-in 10-localhost.conf)
  if [[ -f /etc/systemd/system/cockpit.socket.d/10-localhost.conf ]]; then
    run rm -f /etc/systemd/system/cockpit.socket.d/10-localhost.conf; reload=1
  fi
  if (( reload )); then run systemctl daemon-reload; restart=1; fi
  run systemctl enable --now cockpit.socket
  if (( restart )); then run systemctl restart cockpit.socket; _restart_active cockpit.service; fi
  local code; code="$(curl -s -o /dev/null -w '%{http_code}' -H "Host: $(cfg_req COCKPIT_HOST)" http://127.0.0.1:9090/ || true)"
  [[ "$code" == 200 || "$code" == 301 || "$code" == 302 ]] || [[ "$DRY_RUN" == 1 ]] \
    || die "Cockpit does not answer on 127.0.0.1:9090 (HTTP $code)"
  if [[ -n "$entry" ]]; then log_ok "Cockpit answers on :9090, for $entry and this host only"
  else log_ok "Cockpit answers on 127.0.0.1:9090"; fi
}
