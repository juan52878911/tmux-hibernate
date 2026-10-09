#!/usr/bin/env bash
# Background watcher, one per tmux server. Every @hibernate-check-interval it
# looks for sessions nobody has looked at for @hibernate-idle-time and
# hibernates them. It re-reads the options on every pass, so `tmux source`
# changes take effect without restarting it, and it exits with the server.
#
#   daemon.sh            run the loop (started by hibernate.tmux)
#   daemon.sh --once     one pass, then exit (also used by the "now" key)
#   daemon.sh --force    one pass that ignores idle time
. "$(dirname "$0")/common.sh"

MODE="$1"
KEY="$(printf '%s' "${HIB_SOCKET:-default}" | cksum | cut -d' ' -f1)"
PIDFILE="$HIB_STATE/daemon-$KEY.pid"

pass() {
  local force="$1" t idle_limit count_output exclude
  t="$(now)"
  [ "$(opt enabled on)" = on ] || return 0
  idle_limit="$(to_seconds "$(opt idle-time 3h)")"
  count_output="$(opt count-output on)"
  exclude="$(opt exclude-sessions '')"

  T list-sessions -F '#{session_id} #{session_attached} #{session_created} #{?session_last_attached,#{session_last_attached},0} #{?@hibernate_seen,#{@hibernate_seen},0} #{?@hibernate_asleep,#{@hibernate_asleep},0} #{session_name}' 2>/dev/null |
  while read -r id attached created last seen asleep name; do
    if [ "$attached" -gt 0 ]; then
      # Remember when it was last seen: tmux only records when a client
      # attached, not when it left.
      T set -t "$id" @hibernate_seen "$t"
      # A wake hook can be missed (plugin reloaded, race with a pass): catch up.
      [ "$asleep" != 0 ] && "$HIB_DIR/scripts/wake.sh" "$id"
      continue
    fi
    [ -n "$exclude" ] && printf '%s' "$name" | grep -Eq "$exclude" && continue

    if [ "$force" != 1 ]; then
      latest="$created"
      for v in "$last" "$seen"; do [ -n "$v" ] && [ "$v" -gt "$latest" ] && latest="$v"; done
      if [ "$count_output" = on ]; then
        out="$(T list-windows -t "$id" -F '#{window_activity}' | sort -n | tail -1)"
        [ -n "$out" ] && [ "$out" -gt "$latest" ] && latest="$out"
      fi
      [ $((t - latest)) -ge "$idle_limit" ] || continue
    fi
    "$HIB_DIR/scripts/hibernate.sh" "$id" </dev/null
  done

  # Editor session files older than a week are leftovers.
  find "$HIB_STATE/sessions" -name '*.vim' -mtime +7 -delete 2>/dev/null
}

case "$MODE" in
  --once)  pass 0; exit 0 ;;
  --force) pass 1; exit 0 ;;
esac

# Single instance per server.
if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then exit 0; fi
echo $$ >"$PIDFILE"
trap 'rm -f "$PIDFILE"' EXIT

while T list-sessions >/dev/null 2>&1; do
  pass 0
  interval="$(to_seconds "$(opt check-interval 60)")"
  [ "${interval:-0}" -ge 10 ] || interval=10
  sleep "$interval"
done
