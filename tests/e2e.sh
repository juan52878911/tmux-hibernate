#!/usr/bin/env bash
# End-to-end test on a private tmux server. Does not touch your own server.
#   tests/e2e.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
SOCK="$WORK/tmux.sock"
export HIB_SOCKET="$SOCK" XDG_STATE_HOME="$WORK/state" HOME="$WORK/home"
mkdir -p "$HOME"
T() { tmux -S "$SOCK" "$@"; }
pass=0; fail=0
ok()  { echo "  ok   $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL $1"; fail=$((fail + 1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
cmd_of() { T display -p -t "$1" '#{pane_current_command}'; }
st() { T show -pqv -t "$1" @hibernate_state; }
cleanup() { T kill-server 2>/dev/null; sleep 0.5; rm -rf "$WORK"; }
trap cleanup EXIT

# A fake agent called "claude" (no session json -> uses the fallback command).
mkdir -p "$WORK/bin"
printf '#!/bin/sh\necho "fake claude $*"; sleep 3600\n' >"$WORK/bin/claude"
chmod +x "$WORK/bin/claude"
# One file per editor: two editors on one file stop at the swap-file prompt.
for f in nv dirty bare vim; do echo hello >"$WORK/$f.txt"; done

SH="${E2E_SHELL:-zsh -f}"
# shellcheck disable=SC2034  # used inside the eval'd checks
SHN="${SH%% *}"
T -f "${E2E_CONF:-/dev/null}" new-session -d -s S -x 120 -y 30 "env PATH=\"$WORK/bin:\$PATH\" $SH"
T set -g default-command "env PATH=\"$WORK/bin:\$PATH\" $SH"
T set -g @hibernate-busy-sample 1
T set -g @hibernate-quit-timeout 3
T set -g @hibernate-log "$WORK/hibernate.log"
T run-shell "$ROOT/hibernate.tmux"
sleep 0.5

P_TOP=$(T display -p -t S '#{pane_id}')
P_NV=$(T new-window -P -F '#{pane_id}' -t S)
P_DIRTY=$(T new-window -P -F '#{pane_id}' -t S)
P_BARE=$(T new-window -P -F '#{pane_id}' -t S "nvim --clean $WORK/bare.txt")
P_AG=$(T new-window -P -F '#{pane_id}' -t S)
P_ID=$(T new-window -P -F '#{pane_id}' -t S)
P_VIM=$(T new-window -P -F '#{pane_id}' -t S)
sleep 0.5
T send-keys -t "$P_TOP" 'sleep 3600' Enter
T send-keys -t "$P_NV" "nvim --clean $WORK/nv.txt" Enter
T send-keys -t "$P_DIRTY" "nvim --clean $WORK/dirty.txt" Enter
T send-keys -t "$P_AG" 'claude --model x' Enter
T send-keys -t "$P_ID" 'claude' Enter
T send-keys -t "$P_VIM" "vim -u NONE -N $WORK/vim.txt" Enter
sleep 1.5
# Give the second agent a session file like Claude Code writes, with its pid.
mkdir -p "$HOME/.claude/sessions"
ID_PID=$(T display -p -t "$P_ID" '#{pane_pid}' | xargs pgrep -P | head -1)
SESSION_JSON="$HOME/.claude/sessions/$ID_PID.json"
printf '{"pid":%s,"sessionId":"abc-123","status":"idle"}' "$ID_PID" >"$SESSION_JSON"
mkdir -p "$HOME/.claude/projects/p" && echo '{}' >"$HOME/.claude/projects/p/abc-123.jsonl"
T send-keys -t "$P_DIRTY" 'ihola' Escape        # unsaved change
sleep 0.5

echo "hibernate"
"$ROOT/scripts/daemon.sh" --force
check "unknown program frozen"      '[ "$(st $P_TOP)" = frozen ]'
check "sleep process is stopped"    'ps -o stat= -p $(pgrep -f "^sleep 3600" | head -1) | grep -q T'
check "clean nvim stopped"          '[ "$(st $P_NV)" = stopped ] && [ "$(cmd_of $P_NV)" = "$SHN" ]'
check "restore cmd uses session"    'T show -pqv -t $P_NV @hibernate_cmd | grep -q "nvim -S .*\.vim"'
check "dirty nvim frozen, not lost" '[ "$(st $P_DIRTY)" = frozen ]'
check "nvim --embed server frozen too" 'ps -o stat= -p $(T show -pqv -t $P_DIRTY @hibernate_pids) | grep -q T'
check "bare pane kept, nvim gone"   '[ "$(st $P_BARE)" = stopped ] && T display -p -t $P_BARE "#{pane_dead}" | grep -q 1'
check "agent stopped"               '[ "$(st $P_AG)" = stopped ] && [ "$(cmd_of $P_AG)" = "$SHN" ]'
check "vim stopped by keys"         '[ "$(st $P_VIM)" = stopped ] && T show -pqv -t $P_VIM @hibernate_cmd | grep -q "^vim -S"'
check "agent resumes by session id" '[ "$(T show -pqv -t $P_ID @hibernate_cmd)" = "claude --resume abc-123" ]'
check "agent uses fallback"         '[ "$(T show -pqv -t $P_AG @hibernate_cmd)" = "claude --continue" ]'
check "session marked asleep"       '[ -n "$(T show -qv -t S @hibernate_asleep)" ]'
"$ROOT/scripts/status.sh" | sed 's/^/    /'

echo "wake"
"$ROOT/scripts/wake.sh" S
sleep 2
check "frozen program running"      '! ps -o stat= -p $(pgrep -f "^sleep 3600" | head -1) | grep -q T'
check "frozen program back in fg"   '[ "$(cmd_of $P_TOP)" = sleep ]'
check "nvim relaunched"             '[ "$(cmd_of $P_NV)" = nvim ]'
check "nvim reopened the file"      'T capture-pane -p -t $P_NV | grep -q hello'
check "dirty nvim kept its edit"    'T capture-pane -p -t $P_DIRTY | grep -q hola || { T capture-pane -p -t $P_DIRTY | head -5; false; }'
check "bare pane respawned"         '[ "$(T display -p -t $P_BARE "#{pane_dead}")" = 0 ] && [ "$(cmd_of $P_BARE)" = nvim ]'
check "vim relaunched with its file" '[ "$(cmd_of $P_VIM)" = vim ] && T capture-pane -p -t $P_VIM | grep -q hello'
check "agent relaunched"            'T capture-pane -p -t $P_AG | grep -q "fake claude --continue"'
check "no state left"               '! T list-panes -s -t S -F "#{@hibernate_state}" | grep -q .'
check "session no longer asleep"    '[ -z "$(T show -qv -t S @hibernate_asleep)" ]'

echo "automatic: idle detach -> daemon -> attach hook"
T kill-window -t "$P_DIRTY"; T kill-window -t "$P_VIM"; T kill-window -t "$P_AG"; T kill-window -t "$P_ID"; T kill-window -t "$P_BARE"
T set -g @hibernate-idle-time 1
sleep 2
"$ROOT/scripts/daemon.sh" --once
check "idle session hibernated by daemon" '[ "$(st $P_NV)" = stopped ]'
python3 - "$SOCK" <<'PY'
import os, pty, sys, time, select
pid, fd = pty.fork()
if pid == 0:
    os.environ["TERM"] = "xterm-256color"
    os.execvp("tmux", ["tmux", "-S", sys.argv[1], "attach", "-t", "S"])
end = time.time() + 3
while time.time() < end:
    if select.select([fd], [], [], 0.1)[0]:
        try: os.read(fd, 65536)
        except OSError: break
os.kill(pid, 9)
PY
sleep 1
check "attach hook woke the session" '[ -z "$(st $P_NV)" ] && [ "$(cmd_of $P_NV)" = nvim ]'

echo "safety"
T send-keys -t "$P_TOP" C-c; sleep 0.3
T send-keys -t "$P_TOP" 'yes >/dev/null' Enter; sleep 0.5
"$ROOT/scripts/daemon.sh" --force
check "busy program left alone"     '[ -z "$(st $P_TOP)" ]'
T send-keys -t "$P_TOP" C-c

echo "$pass passed, $fail failed"
if [ "$fail" -gt 0 ]; then echo "--- plugin log"; cat "$WORK/hibernate.log" 2>/dev/null; fi
[ "$fail" -eq 0 ]
