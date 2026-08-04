# claude-vps-guard

Keeps long-running [Claude Code](https://claude.com/claude-code) sessions from taking down the
machine they run on, and keeps them alive across dropped connections.

A single Claude Code session can grow to several gigabytes. On a small VPS that ends with the
kernel OOM killer picking a victim more or less at random, which in practice means losing sshd,
the web server, or every other session at once. This package puts two independent limits in the
way, and gives sessions a stable home in tmux so a lost connection is a reattach rather than lost
work.

Works on Linux and macOS. Bash 3.2 compatible, so the stock macOS shell is enough.

## What you get

| Command | Purpose |
| --- | --- |
| `ccx` | Start or reattach to a named tmux session running Claude Code, memory capped where the platform allows it. `-a <account>` runs it under a separate, persistent login. |
| `ccx ls` | List Claude sessions with memory used per session. |
| `claude-guard` | Inspect the watchdog, see and release paused processes, control the service. |

Two layers of protection:

1. **Per-session cap.** On Linux each session runs in its own systemd scope with `MemoryMax`
   (default 3G). A runaway session is OOM killed inside its own cgroup; the host and every other
   session survive.
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
commands keep working, just with the old behaviour. `claude-guard config` prints the effective
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
ccx ls                  # SESSION, MEMORY, WINDOWS, ACCOUNT, CREATED
```

The account only needs to be given when a session is first created; it is stored in that tmux
session's own environment, so plain `ccx <name>` reattaches with the same account already active.
Set `CLAUDE_CONFIG_DIR` yourself before calling `ccx` to point at an arbitrary directory instead,
or `CLAUDE_ACCOUNTS_DIR` to change where per-account directories are created.

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
