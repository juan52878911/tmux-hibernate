#!/usr/bin/env bash
# Bring a hibernated session back: thaw frozen programs and relaunch the ones
# that were stopped, each in its own pane.
#
#   wake.sh <session> [client]
. "$(dirname "$0")/common.sh"

SESSION="$1"; CLIENT="$2"
[ -n "$SESSION" ] || exit 1
# Cheap exit for the common case: the hook fires on every attach/switch.
[ -n "$(T show -qv -t "$SESSION" @hibernate_asleep 2>/dev/null)" ] || exit 0

getp() { T show -pqv -t "$1" "@hibernate_$2"; }
unsetp() { for k in state cmd cwd pgid pids fgfix redraw bare; do T set -pu -t "$1" "@hibernate_$k"; done; }

n=0
for PANE in $(T list-panes -s -t "$SESSION" -F '#{pane_id}'); do
  STATE="$(getp "$PANE" state)"
  [ -n "$STATE" ] || continue
  PANE_PID="$(T display -p -t "$PANE" '#{pane_pid}')"
  TTY="$(T display -p -t "$PANE" '#{pane_tty}')"

  case "$STATE" in
    frozen)
      G="$(getp "$PANE" pgid)"
      # shellcheck disable=SC2046
      kill -CONT $(getp "$PANE" pids) 2>/dev/null
      if [ "$(getp "$PANE" fgfix)" = 1 ]; then
        # The leader itself was stopped, so the shell took the terminal back.
        sleep 0.1
        FG="$(tty_procs "$TTY" | awk 'NR==1{print $3}')"
        if [ "$FG" = "$PANE_PID" ]; then
          T send-keys -t "$PANE" 'fg' Enter
          i=0   # wait until the program owns the terminal again
          while [ "$(tty_procs "$TTY" | awk 'NR==1{print $3}')" != "$G" ] && [ "$i" -lt 20 ]; do
            sleep 0.05; i=$((i + 1))
          done
        fi
        repaint "$PANE" "$TTY" "$(getp "$PANE" redraw)"
      fi
      ;;
    stopped)
      CMD="$(getp "$PANE" cmd)"; CWD="$(getp "$PANE" cwd)"
      if [ "$(getp "$PANE" bare)" = 1 ]; then
        T respawn-pane -k -t "$PANE" -c "${CWD:-$HOME}" "$CMD"
        T set -pu -t "$PANE" remain-on-exit
      else
        # Only type into a shell that is sitting at its prompt.
        FG="$(tty_procs "$TTY" | awk 'NR==1{print $3}')"
        [ "$FG" = "$PANE_PID" ] && T send-keys -t "$PANE" -l "$CMD" && T send-keys -t "$PANE" Enter
      fi
      ;;
  esac
  unsetp "$PANE"
  n=$((n + 1))
  log "woke $SESSION $PANE ($STATE)"
done

T set -u -t "$SESSION" @hibernate_asleep
if [ "$n" -gt 0 ] && [ "$(opt notify on)" = on ]; then
  T display-message ${CLIENT:+-c "$CLIENT"} "hibernate: $n pane(s) restored"
fi
