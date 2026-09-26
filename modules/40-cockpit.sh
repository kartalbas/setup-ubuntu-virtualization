# shellcheck shell=bash
# modules/40-cockpit.sh — Cockpit (with cockpit-machines) from the stack,
# listening on 127.0.0.1:9090 only; Caddy publishes it as COCKPIT_HOST.

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
  printf '[Socket]\nListenStream=\nListenStream=127.0.0.1:9090\n' \
    | atomic_write /etc/systemd/system/cockpit.socket.d/10-localhost.conf 0644
  if (( CHANGED )); then run systemctl daemon-reload; restart=1; fi
  run systemctl enable --now cockpit.socket
  if (( restart )); then run systemctl restart cockpit.socket; _restart_active cockpit.service; fi
  local code; code="$(curl -s -o /dev/null -w '%{http_code}' -H "Host: $(cfg_req COCKPIT_HOST)" http://127.0.0.1:9090/ || true)"
  [[ "$code" == 200 || "$code" == 301 || "$code" == 302 ]] || [[ "$DRY_RUN" == 1 ]] \
    || die "Cockpit does not answer on 127.0.0.1:9090 (HTTP $code)"
  log_ok "Cockpit answers on 127.0.0.1:9090"
}
