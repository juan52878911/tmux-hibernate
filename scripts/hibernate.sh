#!/usr/bin/env bash
# Hibernate one tmux session: stop or freeze what runs in its panes and leave
# per-pane notes so wake.sh can bring it all back.
#
#   hibernate.sh <session>          (session name or $id)
#
# Panes that are busy, visible in an attached session, or running something
# in @hibernate-ignore are left alone.
. "$(dirname "$0")/common.sh"

SESSION="$1"
[ -n "$SESSION" ] || exit 1
T has-session -t "$SESSION" 2>/dev/null || exit 0

PROGRAMS="$(opt programs 'nvim vim claude codex opencode gemini aider')"
IGNORE_RE="^($(opt ignore 'ssh mosh mosh-client et autossh sudo su tmux' | tr ' ' '|'))\$"
DEFAULT_ACTION="$(opt default-action 'freeze')"
BUSY_CPU="$(opt busy-cpu 5)"
SAMPLE="$(opt busy-sample 2)"
SESS_DIR="$HIB_STATE/sessions"
mkdir -p "$SESS_DIR"

# Windows shown in some attached session are never touched (linked windows).
VISIBLE=" $(T list-windows -a -F '#{session_attached} #{window_id}' | awk '$1>0{printf "%s ", $2}')"

# ─── Helpers ─────────────────────────────────────────────────────────────────

setp() { T set -p -t "$1" "@hibernate_$2" "$3"; }

# Session id of an agent, using the program's resolver.
resolve_id() {
  local how="$1" pid="$2" f re
  case "$how" in
    claude-json)
      # Claude Code writes <config>/sessions/<pid>.json; the config dir can be
      # moved per process with CLAUDE_CONFIG_DIR.
      dir="$(proc_env "$pid" CLAUDE_CONFIG_DIR)"; dir="${dir:-$HOME/.claude}"
      f="$dir/sessions/$pid.json"
      [ -f "$f" ] || return 0
      id="$(sed -n 's/.*"sessionId":"\([^"]*\)".*/\1/p' "$f")"
      [ -n "$id" ] || return 0
      # Opened but never used: there is no conversation to resume.
      if ls "$dir"/projects/*/"$id".jsonl >/dev/null 2>&1; then echo "$id"; else echo -; fi ;;
    openfile:*)
      re="${how#openfile:}"
      command -v lsof >/dev/null || return 0
      lsof -p "$pid" -Fn 2>/dev/null | sed -n 's/^n//p' | grep -E "$re" | head -1 |
        sed -E "s#.*${re}.*#\\1#" ;;
  esac
}

# Is the agent known to be working right now (beyond the CPU check)?
agent_busy() {
  [ "$1" = claude-json ] || return 1
  local dir
  dir="$(proc_env "$2" CLAUDE_CONFIG_DIR)"
  grep -q '"status":"busy"' "${dir:-$HOME/.claude}/sessions/$2.json" 2>/dev/null
}

# expand TEMPLATE  (uses NAME ID SESSFILE ARGS CWD from the caller)
expand() {
  local s="$1"
  s="${s//\{name\}/$NAME}"
  s="${s//\{id\}/$ID}"
  s="${s//\{session\}/$SESSFILE}"
  s="${s//\{args\}/$ARGS}"
  s="${s//\{cwd\}/$CWD}"
  printf '%s' "$s"
}

# Freeze the job with SIGSTOP. If its leader has children, freeze only those:
# the leader (often a thin TUI or wrapper) then just waits, and the shell never
# sees a stopped job. Otherwise the leader stops too and wake.sh has to `fg` it.
freeze() {  # pane pgid
  local pids targets="" p fgfix=0
  pids="$(job_pids "$AFTER" "$2")"
  for p in $pids; do [ "$p" != "$2" ] && targets="$targets $p"; done
  if [ -z "$targets" ]; then targets="$2"; fgfix=1; fi
  # shellcheck disable=SC2086
  kill -STOP $targets 2>/dev/null || return 1
  setp "$1" pids "${targets# }"
  setp "$1" fgfix "$fgfix"
  setp "$1" pgid "$2"
  setp "$1" state frozen
  log "froze $SESSION $1 (pids$targets)"
}

# Remember how to start it again; wake.sh types it into the shell, or respawns
# the pane when the program was the pane's own command.
remember() {  # pane cmd bare
  setp "$1" cmd "$2"
  setp "$1" cwd "$CWD"
  [ "$3" = 1 ] && setp "$1" bare 1
  setp "$1" state stopped
  log "stopped $SESSION $1 -> $2"
}

# ─── Take a CPU sample of every pane at once ─────────────────────────────────

PANES="$(T list-panes -s -t "$SESSION" -F '#{pane_id} #{pane_pid} #{pane_tty} #{window_id} #{?@hibernate_state,#{@hibernate_state},-} #{pane_current_path}')"
[ -n "$PANES" ] || exit 0

BEFORE="$(proc_table)"
sleep "$SAMPLE"
AFTER="$(proc_table)"

# CPU % of a job (group + descendants) over the sample
job_cpu() {
  local pids
  pids=" $(job_pids "$AFTER" "$1")"
  printf '%s\n--\n%s\n' "$BEFORE" "$AFTER" | awk -v want="$pids" -v s="$SAMPLE" '
    BEGIN { n = split(want, w, " "); for (i = 1; i <= n; i++) in_job[w[i]] = 1 }
    $1 == "--" { phase = 1; next }
    $1 in in_job { if (phase) b += $4; else a += $4 }
    END { printf "%d", (b - a) / s * 100 }'
}

# ─── Pane by pane ────────────────────────────────────────────────────────────

echo "$PANES" | while read -r PANE PANE_PID TTY WIN STATE CWD_RAW; do
  [ "$STATE" = - ] || continue                        # already asleep
  case "$VISIBLE" in *" $WIN "*) continue ;; esac     # someone is looking at it

  PROCS="$(tty_procs "$TTY")"
  FG="$(echo "$PROCS" | awk 'NR==1{print $3}')"
  [ -n "$FG" ] || continue
  SHELL_NAME="$(echo "$PROCS" | awk -v p="$PANE_PID" '$1==p{print $5}')"

  BARE=0
  if is_shell "$SHELL_NAME"; then
    [ "$FG" = "$PANE_PID" ] && continue               # just a prompt: nothing to save
  else
    BARE=1                                            # the program IS the pane
  fi

  JOB="$(echo "$PROCS" | awk -v g="$FG" '$2==g')"
  [ -n "$JOB" ] || continue
  if echo "$JOB" | awk '{print $5; print $6}' | grep -Eq "$IGNORE_RE"; then continue; fi

  if [ "$(job_cpu "$FG")" -ge "$BUSY_CPU" ]; then
    log "busy, skipped $SESSION $PANE"; continue
  fi

  # Which configured program is this? First match in @hibernate-programs wins.
  NAME=""; ACTION="$DEFAULT_ACTION"; MPID=""; ARGS=""
  for p in $PROGRAMS; do
    re="$(popt "$p" match)"
    line="$(echo "$JOB" | awk -v re="$re" '$5 ~ re || $6 ~ re {print; exit}')"
    if [ -n "$line" ]; then
      NAME="$p"; ACTION="$(popt "$p" action)"; MPID="${line%% *}"
      # {args}: everything after the word that matched
      ARGS="$(echo "$line" | awk -v re="$re" '{
        for (i = 7; i <= NF; i++) { w = $i; sub(/.*\//, "", w); if (w ~ re) break }
        o = ""; for (j = i + 1; j <= NF; j++) o = o (o == "" ? "" : " ") $j; print o }')"
      break
    fi
  done
  LEADER="$(echo "$JOB" | awk -v g="$FG" '$1==g' | cut -d' ' -f7-)"
  [ -n "$LEADER" ] || LEADER="$(echo "$JOB" | head -1 | cut -d' ' -f7-)"
  CWD="$CWD_RAW"
  ID=""; SESSFILE=""

  # A bare pane would close with its program: keep it so it can be respawned.
  [ "$BARE" = 1 ] && [ "$ACTION" != ignore ] && [ "$ACTION" != freeze ] &&
    T set -p -t "$PANE" remain-on-exit on

  case "$ACTION" in
    ignore) ;;

    freeze)
      freeze "$PANE" "$FG" && [ -n "$NAME" ] && setp "$PANE" redraw "$(popt "$NAME" redraw)" ;;

    editor)
      SESSFILE="$SESS_DIR/${PANE#%}-$(now).vim"
      JOBP="$(job_pids "$AFTER" "$FG")"
      SOCK=""; [ "$(popt "$NAME" rpc)" = nvim ] && SOCK="$(nvim_socket "$JOBP")"
      if [ -n "$SOCK" ]; then
        # Neovim: over RPC, immune to the user's key mappings.
        q() { printf '%s' "$1" | sed "s/'/''/g"; }
        RES="$(nvim --headless --clean --server "$SOCK" --remote-expr \
          "luaeval('dofile(_A[1])(_A[2], _A[3])', ['$(q "$HIB_DIR/scripts/nvim-save.lua")', '$(q "$SESSFILE")', '$(q "$(popt "$NAME" sessionoptions)")'])" 2>/dev/null)"
      else
        # Vim (or Neovim without a socket): type the command. Escape is the
        # one key nobody remaps in normal mode.
        T send-keys -t "$PANE" Escape
        T send-keys -t "$PANE" -l ":silent! mksession! ${SESSFILE// /\\ } | qa"
        T send-keys -t "$PANE" Enter
        RES=saved
      fi
      if [ "$RES" = saved ] && wait_group_gone "$FG" "$(opt quit-timeout 10)"; then
        remember "$PANE" "$(expand "$(popt "$NAME" resume)")" "$BARE"
      else
        # Unsaved changes or running jobs: it refused (or was told not) to quit.
        rm -f "$SESSFILE"
        if [ "$(opt editor-dirty freeze)" = freeze ]; then
          freeze "$PANE" "$FG" && setp "$PANE" redraw "$(popt "$NAME" redraw)"
        fi
        log "editor kept open in $SESSION $PANE ($RES)"
      fi ;;

    agent)
      how="$(popt "$NAME" id)"
      if agent_busy "$how" "$MPID"; then log "agent busy $SESSION $PANE"; continue; fi
      [ -n "$how" ] && ID="$(resolve_id "$how" "$MPID")"
      tpl="$(popt "$NAME" resume)"
      if [ "$ID" = - ]; then   # nothing to resume: start it fresh
        ID=""; tpl="$(popt "$NAME" fresh)"; tpl="${tpl:-$NAME}"
      fi
      case "$tpl" in *'{id}'*) [ -n "$ID" ] || tpl="$(popt "$NAME" fallback)" ;; esac
      if [ -z "$tpl" ]; then freeze "$PANE" "$FG"; continue; fi
      CMD="$(expand "$tpl")"
      stop_job "$FG" "$(job_pids "$AFTER" "$FG")" && remember "$PANE" "$CMD" "$BARE" ;;

    script)
      # User adapter: gets pane, pgid, matched pid; prints the restore command
      # and must stop the program itself. Non-zero exit = leave it alone.
      CMD="$("$(popt "$NAME" script | sed "s#^~#$HOME#")" "$PANE" "$FG" "$MPID" "$CWD" </dev/null)" || continue
      [ -n "$CMD" ] && remember "$PANE" "$CMD" "$BARE" ;;

    restart|*)
      [ -n "$NAME" ] && tpl="$(popt "$NAME" resume)" || tpl=""
      CMD="${tpl:+$(expand "$tpl")}"; CMD="${CMD:-$LEADER}"
      stop_job "$FG" "$(job_pids "$AFTER" "$FG")" && remember "$PANE" "$CMD" "$BARE" ;;
  esac
done

# Mark the session if anything in it went to sleep.
if T list-panes -s -t "$SESSION" -F '#{@hibernate_state}' | grep -q .; then
  T set -t "$SESSION" @hibernate_asleep "$(now)"
fi
