#!/usr/bin/env bash
# Shared helpers for tmux-hibernate. Sourced by every other script.
# Portable: bash 3.2 (macOS) and Linux; needs only tmux >= 3.0, ps and awk.

# Talk to the same tmux server that launched us, even from a background job.
HIB_SOCKET="${HIB_SOCKET:-${TMUX%%,*}}"
T() { if [ -n "$HIB_SOCKET" ]; then tmux -S "$HIB_SOCKET" "$@"; else tmux "$@"; fi; }

# shellcheck disable=SC2034  # used by the scripts that source this file
HIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ─── Options ─────────────────────────────────────────────────────────────────

# opt NAME DEFAULT  ->  value of the global option @hibernate-NAME
opt() {
  local v
  v="$(T show-option -gqv "@hibernate-$1" 2>/dev/null)"
  if [ -n "$v" ]; then printf '%s' "$v"; else printf '%s' "$2"; fi
}

# Built-in defaults per program. Every one can be overridden with
# @hibernate-<program>-<field>. Fields: match action id resume fallback script.
program_default() {
  local p="$1" f="$2"
  case "$p:$f" in
    nvim:match)      echo '^nvim$' ;;
    nvim:action)     echo 'editor' ;;
    nvim:resume)     echo 'nvim -S {session}' ;;
    vim:match)       echo '^vim$' ;;
    vim:action)      echo 'editor' ;;
    vim:resume)      echo 'vim -S {session}' ;;
    nvim:rpc)        echo 'nvim' ;;
    nvim:sessionoptions) echo 'buffers,curdir,folds,tabpages,winsize' ;;
    vim:redraw)      echo 'Escape :redraw! Enter' ;;
    claude:action)   echo 'agent' ;;
    claude:id)       echo 'claude-json' ;;
    claude:resume)   echo 'claude --resume {id}' ;;
    claude:fallback) echo 'claude --continue' ;;
    claude:fresh)    echo 'claude' ;;
    codex:action)    echo 'agent' ;;
    codex:id)        echo 'openfile:rollout-.*([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.jsonl' ;;
    codex:resume)    echo 'codex resume {id}' ;;
    codex:fallback)  echo 'codex resume --last' ;;
    opencode:action) echo 'agent' ;;
    opencode:resume) echo 'opencode --continue' ;;
    gemini:action)   echo 'agent' ;;
    gemini:resume)   echo 'gemini --resume latest' ;;
    aider:action)    echo 'agent' ;;
    aider:resume)    echo 'aider --restore-chat-history' ;;
    *:match)         echo "^${p}\$" ;;
    *:action)        echo 'restart' ;;
    *)               echo '' ;;
  esac
}

# popt PROGRAM FIELD  ->  user override or built-in default
popt() { opt "$1-$2" "$(program_default "$1" "$2")"; }

# "90" "90s" "15m" "3h" "1d"  ->  seconds
to_seconds() {
  local v="$1" n
  n="${v%[smhd]}"
  case "$n" in ''|*[!0-9]*) echo 0; return ;; esac
  case "$v" in
    *m) echo $((n * 60)) ;;
    *h) echo $((n * 3600)) ;;
    *d) echo $((n * 86400)) ;;
    *)  echo "$n" ;;
  esac
}

now() { date +%s; }

# ─── State and logging ───────────────────────────────────────────────────────

HIB_STATE="${XDG_STATE_HOME:-$HOME/.local/state}/tmux-hibernate"
mkdir -p "$HIB_STATE" 2>/dev/null

log() {
  local f
  f="$(opt log '')"
  [ -n "$f" ] || return 0
  printf '%s %s\n' "$(date '+%F %T')" "$*" >>"${f/#\~/$HOME}"
}

# ─── Processes ───────────────────────────────────────────────────────────────

# Every process attached to a pane's terminal:
#   pid pgid tpgid cputime-seconds name1 name2 args...
# name1/name2 are the basenames of argv[0] and argv[1], so interpreted programs
# (node .../claude, python -m aider) match by script name as well.
tty_procs() {
  ps -t "${1#/dev/}" -o pid=,pgid=,tpgid=,time=,args= 2>/dev/null | awk '{
    t = $4; d = 0
    if (index(t, "-")) { split(t, dd, "-"); d = dd[1]; t = dd[2] }
    n = split(t, p, ":"); s = 0; m = 1
    for (i = n; i >= 1; i--) { s += p[i] * m; m *= 60 }
    a0 = $5; sub(/.*\//, "", a0); sub(/^-/, "", a0)
    a1 = $6; sub(/.*\//, "", a1); if (a1 == "") a1 = "-"
    args = ""; for (i = 5; i <= NF; i++) args = args (i > 5 ? " " : "") $i
    printf "%s %s %s %.2f %s %s %s\n", $1, $2, $3, s + d * 86400, a0, a1, args
  }'
}

# Whole process table: pid ppid pgid cputime-seconds
proc_table() {
  ps -A -o pid=,ppid=,pgid=,time= 2>/dev/null | awk '{
    t = $4; d = 0
    if (index(t, "-")) { split(t, dd, "-"); d = dd[1]; t = dd[2] }
    n = split(t, p, ":"); s = 0; m = 1
    for (i = n; i >= 1; i--) { s += p[i] * m; m *= 60 }
    printf "%s %s %s %.2f\n", $1, $2, $3, s + d * 86400
  }'
}

# job_pids TABLE PGID  ->  members of the process group plus all their
# descendants. Daemons that setsid() away (nvim --embed, language servers)
# leave the group but stay in the tree, and they are often the ones burning CPU.
job_pids() {
  printf '%s\n' "$1" | awk -v g="$2" '
    { pp[$1] = $2; grp[$1] = $3; all[++n] = $1 }
    END {
      for (i = 1; i <= n; i++) if (grp[all[i]] == g) inj[all[i]] = 1
      do {
        added = 0
        for (i = 1; i <= n; i++) { p = all[i]; if (!(p in inj) && (pp[p] in inj)) { inj[p] = 1; added = 1 } }
      } while (added)
      for (p in inj) printf "%s ", p
    }'
}

# RPC socket of a Neovim among PIDS (the TUI's --embed server owns it).
nvim_socket() {
  local p s
  for p in $1; do
    for s in "${TMPDIR:-/tmp}"/nvim."${USER:-$(id -un)}"/*/nvim."$p".0 \
             "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"/nvim."$p".0 \
             /tmp/nvim."${USER:-$(id -un)}"/*/nvim."$p".0; do
      [ -S "$s" ] && { echo "$s"; return 0; }
    done
    if command -v lsof >/dev/null; then
      # --listen with a custom path
      s="$(lsof -a -p "$p" -U -Fn 2>/dev/null | sed -n 's/^n//p' | grep -v '^->' | grep '/' | head -1)"
      [ -S "$s" ] && { echo "$s"; return 0; }
    fi
  done
  return 1
}

# proc_env PID VAR  ->  value of VAR in another process's environment
proc_env() {
  if [ -r "/proc/$1/environ" ]; then
    tr '\0' '\n' <"/proc/$1/environ" | sed -n "s/^$2=//p" | head -1
  else
    # BSD/macOS ps prints the environment after the command with -E/e
    ps -E -ww -o command= -p "$1" 2>/dev/null | tr ' ' '\n' | sed -n "s/^$2=//p" | head -1
  fi
}

# Is this process name a shell?
is_shell() {
  local re
  re="^($(opt shells 'sh bash zsh fish dash ksh mksh tcsh csh nu xonsh elvish' | tr ' ' '|'))\$"
  printf '%s' "$1" | grep -Eq "$re"
}

# with_timeout SECONDS CMD...  ->  run CMD, killed if it takes longer (macOS has
# no timeout(1)). Its stdin is /dev/null so it can never wait on a terminal.
with_timeout() {
  local secs="$1" pid watcher rc
  shift
  "$@" </dev/null &
  pid=$!
  ( sleep "$secs"; kill -TERM "$pid" 2>/dev/null; sleep 1; kill -KILL "$pid" 2>/dev/null ) >/dev/null 2>&1 &
  watcher=$!
  wait "$pid"; rc=$?
  kill "$watcher" 2>/dev/null; wait "$watcher" 2>/dev/null
  return "$rc"
}

# Wait up to $2 seconds for process group $1 to disappear.
wait_group_gone() {
  local g="$1" i=0 max=$(( ${2:-5} * 10 ))
  while kill -0 -"$g" 2>/dev/null; do
    i=$((i + 1)); [ "$i" -ge "$max" ] && return 1
    sleep 0.1
  done
}

# stop_job PGID "PIDS": TERM the group and its detached descendants, then
# KILL whatever ignored it.
stop_job() {
  local p
  kill -TERM -"$1" 2>/dev/null
  for p in $2; do kill -TERM "$p" 2>/dev/null; done
  wait_group_gone "$1" "$(opt quit-timeout 10)" || kill -KILL -"$1" 2>/dev/null
  sleep 0.2
  for p in $2; do kill -KILL "$p" 2>/dev/null; done
  wait_group_gone "$1" 2
}

# Make a TUI repaint itself: bounce the terminal size (the kernel sends
# SIGWINCH with a real change, which most programs honour), then send the
# program's own redraw keys if it has any.
repaint() {  # pane tty keys
  local rows sflag=-F
  case "$(uname)" in *BSD|Darwin|DragonFly) sflag=-f ;; esac
  rows="$(T display -p -t "$1" '#{pane_height}')"
  if [ -n "$rows" ] && [ "$rows" -gt 2 ]; then
    stty "$sflag" "$2" rows $((rows - 1)) 2>/dev/null
    sleep 0.05
    stty "$sflag" "$2" rows "$rows" 2>/dev/null
  fi
  # shellcheck disable=SC2086  # keys are a list
  [ -n "$3" ] && T send-keys -t "$1" $3
}
