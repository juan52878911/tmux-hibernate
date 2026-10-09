# tmux-hibernate

[![test](https://github.com/juan52878911/tmux-hibernate/actions/workflows/test.yml/badge.svg)](https://github.com/juan52878911/tmux-hibernate/actions/workflows/test.yml)

Sessions you forgot about stop using CPU and memory, and come back as they were
the moment you return to them.

```
session without a client for @hibernate-idle-time
  └─ each pane, by what it runs
      ├─ editor (nvim, vim)        save a session, quit      → reopened with it
      ├─ AI agent (claude, codex…) quit when idle            → resumed by session id
      ├─ known program             quit                      → relaunched
      └─ anything else             frozen with SIGSTOP       → thawed (SIGCONT)
attach or switch to it → everything restored before you notice
```

Independent of your configuration: it uses no keys by default, does not touch
your status bar, theme or hooks, and works with any shell (bash, zsh, fish…),
any `base-index`, `default-shell`, `remain-on-exit` or plugin set.

## Why

A tmux server accumulates sessions. Each one keeps its editors, language
servers and AI agents alive: hundreds of MB each and constant timer wakeups,
for work you will not look at until tomorrow. Killing them loses state;
keeping them wastes resources. This plugin does the boring part for you.

## Install

With [TPM](https://github.com/tmux-plugins/tpm):

```tmux
set -g @plugin 'juan52878911/tmux-hibernate'
```

Or by hand:

```tmux
run-shell /path/to/tmux-hibernate/hibernate.tmux
```

Needs tmux ≥ 3.0, bash (3.2 is enough), `ps` and `awk`. Editors: Neovim ≥ 0.5
(driven over its RPC socket) or any Vim with `+mksession`. `lsof` is optional
(nvim started with a custom `--listen` path, codex session ids).

## What it never does

- Touch a session that has a client attached, or a window linked into one.
- Stop something busy: a job using more than `@hibernate-busy-cpu` over the
  sample, or an agent that reports itself as working.
- Lose unsaved work: an editor with modified buffers or running terminal jobs
  is frozen instead of closed. So is one that does not answer within 5 s, for
  example because it is waiting at a prompt (swap file, hit-enter).
- Touch remote shells (`ssh`, `mosh`…) or anything in `@hibernate-ignore`.
- Type into a pane that is not sitting at a shell prompt when restoring.

## How each pane is handled

The foreground job of every pane (its process group plus all descendants, so
daemons like `nvim --embed` or MCP servers are included) is matched against
`@hibernate-programs`, in order, by the name of the executable or of the
script an interpreter runs (`node …/claude` matches `claude`).

| Action    | Sleep                                                | Wake                                  |
|-----------|------------------------------------------------------|---------------------------------------|
| `editor`  | Neovim over RPC (your mappings can't interfere), Vim with keys: `mksession`, quit | `{resume}` (default `nvim -S {session}`) |
| `agent`   | quit the whole process tree                          | `{resume}` with the session id, or `{fallback}` |
| `restart` | quit                                                 | `{resume}`, or the original command line |
| `freeze`  | `SIGSTOP` the tree                                   | `SIGCONT`, back to foreground, repaint |
| `script`  | your adapter decides (see below)                      | the command it printed               |
| `ignore`  | nothing                                              | nothing                               |

Anything not in the list gets `@hibernate-default-action` (`freeze`).

If the program *is* the pane (`tmux new-window nvim`), the pane is kept with
`remain-on-exit` and respawned on wake.

### Built-in programs

| Program    | Action  | Resume                          | Session id from                    |
|------------|---------|---------------------------------|------------------------------------|
| `nvim`     | editor  | `nvim -S {session}`             | —                                  |
| `vim`      | editor  | `vim -S {session}`              | —                                  |
| `claude`   | agent   | `claude --resume {id}`          | `<config>/sessions/<pid>.json` (honours `CLAUDE_CONFIG_DIR`); opened but unused → plain `claude` |
| `codex`    | agent   | `codex resume {id}`             | the rollout file it has open       |
| `opencode` | agent   | `opencode --continue`           | —                                  |
| `gemini`   | agent   | `gemini --resume latest`        | —                                  |
| `aider`    | agent   | `aider --restore-chat-history`  | —                                  |

Restore commands are typed into your shell, so aliases, functions and wrappers
you normally use (`claude` behind a shim, for example) apply as usual.

## Options

```tmux
set -g @hibernate-idle-time '3h'        # without a client for this long: s m h d
set -g @hibernate-check-interval '60'   # seconds between checks (min 10)
set -g @hibernate-count-output 'on'     # output in the session counts as activity
set -g @hibernate-exclude-sessions ''   # ERE of session names to never touch
set -g @hibernate-default-action 'freeze'   # for unlisted programs: freeze|restart|ignore
set -g @hibernate-busy-cpu '5'          # % of a core above which a job is busy
set -g @hibernate-busy-sample '2'       # seconds the CPU is sampled for
set -g @hibernate-quit-timeout '10'     # seconds to wait for a program to quit
set -g @hibernate-editor-dirty 'freeze' # editor with unsaved changes: freeze|ignore
set -g @hibernate-ignore 'ssh mosh mosh-client et autossh sudo su tmux'
set -g @hibernate-shells 'sh bash zsh fish dash ksh mksh tcsh csh nu xonsh elvish'
set -g @hibernate-programs 'nvim vim claude codex opencode gemini aider'
set -g @hibernate-notify 'on'           # "N pane(s) restored" when waking
set -g @hibernate-log ''                # file to log every decision to
set -g @hibernate-enabled 'on'          # pause it without unloading
set -g @hibernate-key-now ''            # e.g. 'M-h': hibernate every detached session now
set -g @hibernate-key-status ''         # e.g. 'M-H': list what is asleep
set -g @hibernate-hook-index '77'       # array index of its two hooks
```

Options are re-read on every check: `tmux source` is enough after a change.

### Per program

Every field of every program can be overridden with
`@hibernate-<program>-<field>`, and new programs are added by naming them:

```tmux
# the list replaces the built-in one: keep the ones you want
set -g @hibernate-programs 'nvim vim claude codex opencode gemini aider lazygit k9s btop myrepl'

# restart = quit and relaunch; with no resume, the original command line
set -g @hibernate-k9s-action 'restart'
set -g @hibernate-k9s-resume 'k9s {args}'

# match by regular expression on the executable/script name
set -g @hibernate-btop-match '^b?top$'
set -g @hibernate-btop-action 'restart'

# your own adapter
set -g @hibernate-myrepl-action 'script'
set -g @hibernate-myrepl-script '~/bin/myrepl-hibernate'

# never touch it
set -g @hibernate-lazygit-action 'ignore'
```

Fields: `match` (ERE, default `^<program>$`), `action`, `resume`, `fallback`
(used when `{id}` could not be found), `fresh`, `id` (`claude-json` or
`openfile:<ERE with the id in group 1>`), `redraw` (keys sent after thawing),
`rpc` (`nvim`), `sessionoptions` (nvim).

Placeholders in `resume`/`fallback`/`fresh`: `{name}`, `{id}`, `{session}`,
`{args}` (arguments after the matched program), `{cwd}`.

An adapter script receives `<pane> <pgid> <matched pid> <cwd>`, must stop the
program itself and print the command that restores it. A non-zero exit means
"leave it alone".

## Commands

```sh
scripts/status.sh        # what is asleep and how it will come back
scripts/daemon.sh --force  # hibernate every detached session now
scripts/wake.sh <session>  # wake one by hand
```

## Pause, uninstall, troubleshoot

- **Pause** without unloading: `tmux set -g @hibernate-enabled off`.
- **Uninstall**: remove the plugin line, then drop its hooks from the running
  server (while disabled the watcher does nothing, and it exits with the server):
  ```sh
  tmux set -g @hibernate-enabled off
  tmux set-hook -gu 'client-attached[77]'
  tmux set-hook -gu 'client-session-changed[77]'
  ```
- **Why didn't it hibernate X?** Set `@hibernate-log` and read it: every
  freeze, stop, skip (busy, editor with changes) and wake is written there.
  Idle time counts from the last time a client was in the session or the last
  output in it, not from when the session was created.
- **Why didn't something come back?** `scripts/status.sh` shows what is asleep
  and the exact command each pane will run.

## How it works

- A watcher per tmux server (`scripts/daemon.sh`) runs a pass every
  `@hibernate-check-interval`; a pass with nothing to do costs about 0.07 s of
  CPU. It records when each session was last seen with a client, because tmux
  only keeps when a client attached, not when it left.
- `scripts/hibernate.sh` samples CPU of every pane's job, then handles each
  pane. State lives in pane options (`@hibernate_state`, `@hibernate_cmd`…),
  so it needs no files and disappears with the server.
- The `client-attached` and `client-session-changed` hooks run
  `scripts/wake.sh`, which returns immediately for sessions that are awake.
- Freezing stops the job's children and leaves its leader running when it has
  any (a TUI waiting on its server, a wrapper): the shell never notices. When
  the leader itself has to be stopped, the shell takes the terminal back, so
  waking runs `fg` and makes the program repaint.

## Limitations

- Only the tmux server's own state is kept: if the server dies while a session
  sleeps, frozen programs die with it and stopped ones are not relaunched.
- Restoring an agent drops flags you typed that the resume template does not
  carry; use `{args}` if you need them.
- A frozen program's network connections stall and may time out (that is why
  `ssh`/`mosh` are ignored by default).
- Tested in CI on Linux and macOS with bash, zsh and fish.

## Tests

```sh
tests/e2e.sh                               # private tmux server, nothing of yours is touched
E2E_SHELL='bash --norc' tests/e2e.sh
E2E_SHELL='fish --no-config' E2E_CONF=/path/to/tmux.conf tests/e2e.sh
```

## License

MIT
