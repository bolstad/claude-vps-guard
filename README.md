# claude-vps-guard

Keeps long-running [Claude Code](https://claude.com/claude-code) sessions from taking down the
machine they run on, and keeps them alive across dropped connections.

A single Claude Code session can grow to several gigabytes. On a small VPS that ends with the
kernel OOM killer picking a victim more or less at random, which in practice means losing sshd,
the web server, or every other session at once. This package puts two independent limits in the
way, and gives sessions a stable home in tmux so a lost connection is a reattach rather than lost
work.

Works on Linux and macOS. Bash 3.2 compatible, so the stock macOS shell is enough.

Longer write-up: [Built to survive the machine it runs on](docs/blog.html).

## What you get

| Command | Purpose |
| --- | --- |
| `ccx` | Start or reattach to a named tmux session running Claude Code, memory capped where the platform allows it. `-a <account>` runs it under a separate, persistent login; `-r` resumes the previous conversation instead of starting a blank one. |
| `ccx -c <session-id>` | Continue one specific Claude Code conversation by id: finds its directory and account automatically, or jumps to its tmux pane if it is already running. |
| `ccx ls` | List Claude sessions with memory used per session. |
| `ccx resumable` | List Claude Code conversations you can resume, across every account, newest first - flags which ones already have a live process attached. |
| `ccx up` | macOS + Ghostty: reopen every session in one sweep, one tab per session. Attaches to the ones still alive in tmux and recreates the lost ones with `claude --resume`. |
| `ccx save [file]` | Save the list of running sessions (name, account, directory, conversation id) that `ccx up` restores from. |
| `ccx --version` | Print the version of the installed copy, so you can tell which machines have been upgraded. |
| `ccx snapshots` | List the daily snapshots of the session list, the safety net if the list itself gets replaced. |
| `ccx doctor` | Check that the tmux server can read a directory; explains the misleading "low max file descriptors" crash on macOS. |
| `claude-guard` | Inspect the watchdog, see and release paused processes, control the service. |

Two layers of protection:

1. **Per-session cap.** On Linux each session runs in its own systemd scope with `MemoryMax`
   (default 3G) and swap disabled for that scope. A runaway session is OOM killed inside its own
   cgroup instead of thrashing the host's swap first; the host and every other session survive.
2. **Watchdog.** A user service samples memory every 10 seconds and `SIGSTOP`s the largest
   offender before the system reaches OOM. Freezing does not free RAM, but it stops the growth,
   and it is reversible: `claude-guard resume <pid>`.

Only processes matching a whitelist can be paused (`claude`, `node`, `python`, browsers used by
tooling). Infrastructure such as sshd, tmux and the shell never matches, and the watchdog never
pauses itself.

## Install

```sh
git clone https://github.com/bolstad/claude-vps-guard.git
cd claude-vps-guard
./install.sh          # or: make install
```

The installer copies the tools to `~/.local/share/claude-vps-guard`, links `ccx` and
`claude-guard` into `~/.local/bin`, writes a default config to
`~/.config/claude-vps-guard/guard.conf`, and registers the watchdog with systemd (Linux) or
launchd (macOS).

Requirements: `bash`, `tmux`, `awk`, `ps`, and Claude Code on `PATH`. Python 3 only if you want
the bundled SMTP alerts.

Useful variables:

```sh
PREFIX=/opt/claude-vps-guard ./install.sh    # install elsewhere
BINDIR=~/bin ./install.sh                    # link the commands elsewhere
CC_COMMAND_NAME=cc ./install.sh              # shorter name, clashes with the C compiler
NO_SERVICE=1 ./install.sh                    # files only, no watchdog service
```

The session command is deliberately named `ccx` rather than the shorter `cc`, which is the
traditional name of the C compiler: if `~/.local/bin` precedes `/usr/bin` on your `PATH`, builds
that invoke `cc` would reach this tool instead. `CC_COMMAND_NAME=cc` opts into the short name
anyway; the installer warns when the chosen name already resolves to something else.

On Linux, enable lingering so the watchdog keeps running when no one is logged in:

```sh
sudo loginctl enable-linger "$USER"
```

Remove everything with `./uninstall.sh` (`PURGE=1` also drops config and logs).

## Upgrade

The installer copies files rather than linking to the clone, so pulling new commits changes
nothing until you install again:

```sh
git pull
./install.sh          # also restarts the watchdog so it runs the new code
```

Worth doing deliberately, because an out-of-date install fails quietly rather than loudly: the
commands keep working, just with the old behaviour. `ccx --version` prints which version an installed
copy is, to compare with the latest tag; copies installed before 1.2.0 have no such flag, so a
`ccx --version` that is not recognised means the copy is older than that. `claude-guard config` prints the effective
paths and settings, so you can at least confirm which files are in play and compare them against
the clone.

`NO_SERVICE=1 ./install.sh` updates the files without touching the running watchdog, which is the
safer choice mid-session, but the service then keeps the old code until the next
`claude-guard restart`.

Changes are listed in [CHANGELOG.md](CHANGELOG.md).

## Use

```sh
ccx                # session "claude"
ccx review         # a second, parallel session named "review"
ccx ls             # sessions with memory per session
ccx resumable      # Claude Code conversations you can resume, across every account
ccx up             # reopen every session in Ghostty, one tab each (macOS)
ccx save           # write the session list that 'ccx up' restores from

claude-guard              # memory, candidates, paused processes
claude-guard list         # paused processes only
claude-guard resume 4711  # unfreeze
claude-guard resume all
claude-guard kill 4711    # when memory is still critical
claude-guard log 100      # watchdog log
claude-guard config       # effective settings and paths
claude-guard restart      # restart the watchdog service
```

Detach from a session with `Ctrl-b d`; `ccx <name>` reattaches. A `claude -p` run from cron is
untouched by any of this.

### When `resume` looks like it did not work

A session that is a background job of a terminal cannot be revived from outside that terminal.
`resume` does send `SIGCONT` and the process does start running, but the moment it touches the
terminal that another job holds in the foreground, the kernel stops it again with `SIGTTIN` or
`SIGTTOU`. Within seconds it is back in state `T`, which looks exactly like the watchdog freezing
it a second time.

Tell the two apart in the log: a watchdog pause always writes a `PAUSED` line and a marker file
under `~/.cache/claude-vps-guard/paused/`, job control writes neither. To actually use such a
session again, bring it to the foreground with `fg` in its own terminal.

The same mechanism makes `SIGTERM` useless on those processes. They wake, try to write their
shutdown output to the terminal, get stopped, and never process the signal. `claude-guard kill`
sends `SIGKILL`, which cannot be blocked or deferred, and is the way to clear an abandoned
session.

### Multiple accounts

`ccx <name> -a <account>` runs that session's Claude Code against its own config directory
(`~/.claude-accounts/<account>` by default), so two or more Anthropic accounts can stay logged in
side by side without re-authenticating - the same trick as `CLAUDE_CONFIG_DIR`, wired into
sessions instead of shell aliases:

```sh
ccx work -a acme       # first run: log in, credentials saved under ~/.claude-accounts/acme
ccx personal -a other  # a second account, fully independent
ccx work                # later: reattaches to "work", still the "acme" account
ccx ls                  # SESSION, MEMORY, WINDOWS, ACCOUNT, SERVER, CREATED
```

The account only needs to be given when a session is first created; it is stored in that tmux
session's own environment, so plain `ccx <name>` reattaches with the same account already active.
Set `CLAUDE_CONFIG_DIR` yourself before calling `ccx` to point at an arbitrary directory instead,
or `CLAUDE_ACCOUNTS_DIR` to change where per-account directories are created.

### Resuming after a reboot

A reboot kills every tmux session, but Claude Code's own conversation history on disk survives it.
`ccx <name> -r` rebuilds the same session, memory cap and account as usual, but hands Claude Code
`--resume` instead of starting a blank conversation:

```sh
ccx work -r          # new "work" session, running 'claude --resume'
```

`-r` only takes effect when a new tmux session is actually created; reattaching to a session that
is still running ignores it, same as `-a`.

The catch is knowing *which* directory and account each dropped session was running under - a
reboot leaves no tmux to remind you. `ccx resumable` answers that by reading Claude Code's own
conversation history directly (`~/.claude/projects` for the default account, plus
`<CLAUDE_ACCOUNTS_DIR>/*/projects` for every `-a` account), newest first:

```sh
ccx resumable       # last 30 conversations, across every account
ccx resumable 100   # last 100
ccx resumable all   # everything
```

```
TIME              ACCOUNT      STATUS         NAME                 SESSION                                PATH
2026-08-15 19:51  -            resumable      -                    f1c49de2-4654-45d8-aaaf-cb2baf940bff   /home/me/claude-vps-guard
2026-08-15 19:51  atdt         active (busy)  some-project-7d      44b6663b-7fa9-406c-9559-e57fe093752d   /home/me/some-project
```

`ACCOUNT` is `-` for the default account, matching the `ACCOUNT` column in `ccx ls`.

`STATUS` and `NAME` come from Claude Code's own `sessions/<pid>.json` lock file, which only exists
for the life of a running process - so `NAME` (a name Claude Code derives when it starts) is only
known while that process is up, and reads `-` for anything dormant on disk. A `pid` with a lock
file is checked for being alive before it counts as `active`; a crashed or `kill -9`'d process
leaves its lock file behind exactly like a live one, so the check is what actually tells the two
apart, not just the file's presence:

- **`active (busy|idle)`** already has a Claude Code process running - somewhere with a live PID,
  possibly in a tmux pane `ccx` never created (or in one from before a rename). Reattach to it
  rather than starting a second `--resume` of the same conversation; `ccx ls` finds the tmux side
  of it if the pane is still around.
- **`resumable`** exists only in Claude Code's history on disk. Pick a row and resume it with:

```sh
cd /home/me/some-project
ccx work -a atdt -r   # drop '-a' for a '-' (default account) row
```

Or skip the `cd` and the account bookkeeping entirely and hand `ccx` the session id straight from the
`resumable` list:

```sh
ccx -c f1c49de2-4654-45d8-aaaf-cb2baf940bff
```

`-c`/`--continue <session-id>` looks the id up itself - directory, account, everything - and builds a
new tmux session there, named after the target directory (`claude-vps-guard`, deduped against
whatever tmux sessions already exist), running `claude --resume` for that exact conversation. Give it
an explicit name to control that instead (`ccx work -c <id>`), with the same caveat as `-a` and `-r`:
an existing tmux session of that name is reattached as-is, ignoring `-c`.

If the id turns out to be `active` rather than `resumable`, `-c` does not start a second, duplicate
conversation - it jumps straight to the tmux pane that already has it (found through the same
`sessions/<pid>.json` lock file `resumable` reads `STATUS` from), or says so if that process is not
reachable through tmux.

### Reopening everything in one sweep

tmux keeps the sessions alive when the terminal dies, but reattaching a dozen of them means opening
a dozen windows and typing a dozen commands. On macOS with [Ghostty](https://ghostty.org) 1.3 or
later (the version that added AppleScript support), `ccx up` does it in one go:

```sh
ccx up              # one tab per session, in a new Ghostty window
ccx up --windows    # a window per session instead (CCX_OPEN_MODE=windows makes it the default)
ccx up -n           # dry run: show what would be done
```

For each session on the list it either attaches to the tmux session if it is still running, or
recreates it with `claude --resume <id>` in its old directory and under its old account. Sessions
that already have a client attached are skipped, so it is safe to run twice. Each tab is the
tab title `ccx` sets to the session name.

The list comes from `ccx save`, which records every running session - name, account, working
directory and Claude Code conversation id - in `~/.cache/claude-vps-guard/ccx-sessions.tsv`. `ccx
up` saves first, so after Ghostty dies it can restore straight from the live tmux server. The
list matters when the server itself is gone, after a crash or a reboot: a save with no server
running keeps the previous list instead of overwriting it with nothing.

While a server is alive, every save rewrites the whole list, so a session you ended with `/exit`
drops out at the next save. To end sessions on purpose and bring them back later, save to a file of
your own first and restore from it:

```sh
ccx save ~/ccx-before-update.tsv
# ... end the sessions, update, reboot ...
ccx up --from ~/ccx-before-update.tsv
```

### Daily snapshots and the restart warning

The default list is rewritten on every save, so on its own it is only as good as the last minute.
Two things keep an earlier picture around:

- **Daily snapshots.** Every save also updates one file a day in
  `~/.cache/claude-vps-guard/snapshots/` holding every session seen that day (the newest row wins
  per name), so a session ended on purpose in the afternoon is still in the morning's picture.
  They are kept 30 days (`CCX_SNAPSHOT_KEEP_DAYS`). `ccx snapshots` lists them, and
  `ccx up --from 2026-10-16` restores from that day's file.
- **A copy of the list from before a restart.** The first session started after a reboot would make
  the next save rewrite the list with just that session, so the old list is copied to
  `snapshots/ccx-sessions.before-restart-<date>.tsv` before anything replaces it.

When you start a session from scratch after a restart, with nothing running and saved sessions that
are not, `ccx` stops and asks instead of silently going ahead:

```
ccx: this computer restarted after the session list was saved (2026-10-16 19:46),
     and 9 saved session(s) are not running:
       work                   acme      /home/me/some-project
       ...
     Starting a new session now replaces that list within a minute.
     A copy is kept in ~/.cache/claude-vps-guard/snapshots.
     [u] run ccx up and restore them   [c] continue with this session   [q] quit (default q):
```

`u` runs `ccx up`, `c` carries on with the session you asked for (the old list is copied first), and
Enter or `q` quits without starting anything. The question is only asked in a terminal, and only when
the list is older than the last boot; `ccx up` starts its own tabs with `--no-warn`, and
`CCX_WARN=never` turns the question off.

To keep the default list fresh without thinking about it, run `ccx save` on a schedule. On macOS a
launchd agent does it:

```xml
<!-- ~/Library/LaunchAgents/ccx-save.plist -->
<plist version="1.0"><dict>
  <key>Label</key><string>ccx-save</string>
  <key>ProgramArguments</key><array>
    <string>/Users/you/.local/bin/ccx</string><string>save</string>
  </array>
  <key>StartInterval</key><integer>60</integer>
  <key>RunAtLoad</key><true/>
</dict></plist>
```

```sh
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/ccx-save.plist
```

When Ghostty is not running there is no terminal to type `ccx up` into, so wrap it in a tiny app
you can start from Spotlight or the Dock:

```sh
osacompile -o ~/Applications/ccx-up.app -e 'do shell script "$HOME/.local/bin/ccx up > /tmp/ccx-up.log 2>&1 &"'
```

The first run asks macOS whether the app may control Ghostty (Automation permission).

`ccx up` is macOS and Ghostty only. `ccx save` and `ccx doctor` work wherever `ccx` does.

### One tmux server of its own

`ccx` runs its sessions on its own tmux server (socket `ccx`, override with `CCX_TMUX_SOCKET`)
rather than the shared default one. On macOS a long-lived default server can lose its access to
external volumes, and from then on every session it starts crashes at once with Claude Code's
`error: An unknown error occurred, possibly due to low max file descriptors`, whatever the
`ulimit`. See [docs/platforms.md](docs/platforms.md#macos-tmux-and-external-volumes) for the cause.
Sessions that are still on the default server keep working: `ccx ls` lists both (the `SERVER`
column) and `ccx <name>` and `ccx up` attach to them. `ccx doctor [directory]` tells you whether a
server can read a directory.

## Configuration

Everything lives in `~/.config/claude-vps-guard/guard.conf`; environment variables override it.
See [`config/guard.conf.example`](config/guard.conf.example) for the annotated defaults.

| Setting | Default | Meaning |
| --- | --- | --- |
| `INTERVAL` | `10` | Seconds between checks. |
| `FLOOR_MB` | `900` | Pause the largest candidate below this much available memory. |
| `CRIT_MB` | `450` | Emergency: pause up to three at once. |
| `PROC_HARD_MB` | `2800` | Pause any single process above this, regardless of free memory. |
| `SWAP_FLOOR_MB` | `400` | Treat low free swap as pressure, when swap exists. Linux only, see below. |
| `CLAUDE_MEMORY_MAX` | `3G` | Per-session cap (Linux only). |
| `CLAUDE_ACCOUNTS_DIR` | `~/.claude-accounts` | Where `ccx -a <account>` keeps per-account config dirs. |
| `DRY_RUN` | `0` | `1` logs intended actions without pausing or notifying. |
| `CAND_RE` | see example | Command names eligible for pausing. |

The defaults are sized for a small VPS. On a machine with more RAM, scale the thresholds up:
on a 32G workstation something like `FLOOR_MB=2048`, `CRIT_MB=1024`, `PROC_HARD_MB=8192`.
`claude-guard restart` picks up the new values.

**`SWAP_FLOOR_MB` does nothing on macOS; the swap rule is disabled there.** macOS grows its swap
file on demand, so free swap stays inside a narrow band instead of falling under pressure, and any
floor at or above that band would make the rule permanently true, freezing a process every tick
with plenty of RAM free. Measured before it was disabled: `SWAP_FLOOR_MB=1024` on a 16G Mac
produced 4453 spurious pauses, all logged as `low-mem`, some with 8G available. The value is now
forced to `0` on macOS, and a value set anyway is reported as ignored rather than dropped
silently. On Linux the setting works as intended and the default is fine. Details in
[docs/platforms.md](docs/platforms.md).

Tune on a quiet machine with `DRY_RUN=1` first:

```sh
DRY_RUN=1 MAX_TICKS=5 ~/.local/share/claude-vps-guard/bin/claude-memwatch
claude-guard log
```

### Alerts

Every pause is written to `~/.cache/claude-vps-guard/logs/memwatch.log`. For alerts that reach
you elsewhere, either configure the bundled SMTP sender (copy `config/mail.env.example` to
`~/.config/claude-vps-guard/mail.env`, `chmod 600`), or point `NOTIFY_CMD` at any command that
takes a subject argument and a body on stdin:

```sh
NOTIFY_CMD="$HOME/bin/webhook-alert.sh"
```

## Platform differences

macOS has no per-process equivalent of cgroup memory limits, so sessions there start uncapped and
the watchdog is the only guard. Details in [docs/platforms.md](docs/platforms.md).

## License

MIT. See [LICENSE](LICENSE).
