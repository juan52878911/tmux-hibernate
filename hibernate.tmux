#!/usr/bin/env bash
# tmux-hibernate: put forgotten sessions to sleep, wake them when you return.
# Entry point for TPM (or `run-shell /path/to/hibernate.tmux`).
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/scripts/common.sh"

# Pane options and indexed hooks need tmux 3.0.
v="$(tmux -V | sed -E 's/[^0-9.]*([0-9]+)\.([0-9]+).*/\1\2/')"
if [ "${v:-0}" -lt 30 ]; then
  tmux display-message "tmux-hibernate needs tmux >= 3.0"
  exit 0
fi

# Wake on attach and on switching into a session. Fixed array index so that
# reloading the config never duplicates it nor clobbers the user's hooks.
idx="$(opt hook-index 77)"
wake="run-shell -b \"'$DIR/scripts/wake.sh' '#{session_id}' '#{client_name}'\""
tmux set-hook -g "client-attached[$idx]" "$wake"
tmux set-hook -g "client-session-changed[$idx]" "$wake"

k="$(opt key-now '')"
[ -n "$k" ] && tmux bind-key "$k" run-shell -b "'$DIR/scripts/daemon.sh' --force"
k="$(opt key-status '')"
[ -n "$k" ] && tmux bind-key "$k" run-shell "'$DIR/scripts/status.sh'"

# The watcher outlives this script; it stops on its own with the server.
HIB_SOCKET="${TMUX%%,*}" nohup "$DIR/scripts/daemon.sh" >/dev/null 2>&1 &
