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
| `cc` | Start or reattach to a named tmux session running Claude Code, memory capped where the platform allows it. |
| `cc ls` | List Claude sessions with memory used per session. |
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
./install.sh
```

The installer copies the tools to `~/.local/share/claude-vps-guard`, links `cc` and
`claude-guard` into `~/.local/bin`, writes a default config to
`~/.config/claude-vps-guard/guard.conf`, and registers the watchdog with systemd (Linux) or
launchd (macOS).

Requirements: `bash`, `tmux`, `awk`, `ps`, and Claude Code on `PATH`. Python 3 only if you want
the bundled SMTP alerts.

Useful variables:

```sh
PREFIX=/opt/claude-vps-guard ./install.sh    # install elsewhere
BINDIR=~/bin ./install.sh                    # link the commands elsewhere
CC_COMMAND_NAME=ccx ./install.sh             # avoid clashing with the C compiler
NO_SERVICE=1 ./install.sh                    # files only, no watchdog service
```

`cc` shares its name with the traditional C compiler. If `~/.local/bin` precedes `/usr/bin` on
your `PATH`, builds that invoke `cc` would reach this tool instead. The installer warns when it
detects the clash; `CC_COMMAND_NAME` picks another name.

On Linux, enable lingering so the watchdog keeps running when no one is logged in:

```sh
sudo loginctl enable-linger "$USER"
```

Remove everything with `./uninstall.sh` (`PURGE=1` also drops config and logs).

## Use

```sh
cc                 # session "claude"
cc review          # a second, parallel session named "review"
cc ls              # sessions with memory per session

claude-guard              # memory, candidates, paused processes
claude-guard list         # paused processes only
claude-guard resume 4711  # unfreeze
claude-guard resume all
claude-guard kill 4711    # when memory is still critical
claude-guard log 100      # watchdog log
claude-guard config       # effective settings and paths
claude-guard restart      # restart the watchdog service
```

Detach from a session with `Ctrl-b d`; `cc <name>` reattaches. A `claude -p` run from cron is
untouched by any of this.

## Configuration

Everything lives in `~/.config/claude-vps-guard/guard.conf`; environment variables override it.
See [`config/guard.conf.example`](config/guard.conf.example) for the annotated defaults.

| Setting | Default | Meaning |
| --- | --- | --- |
| `INTERVAL` | `10` | Seconds between checks. |
| `FLOOR_MB` | `900` | Pause the largest candidate below this much available memory. |
| `CRIT_MB` | `450` | Emergency: pause up to three at once. |
| `PROC_HARD_MB` | `2800` | Pause any single process above this, regardless of free memory. |
| `SWAP_FLOOR_MB` | `400` | Treat low free swap as pressure, when swap exists. |
| `CLAUDE_MEMORY_MAX` | `3G` | Per-session cap (Linux only). |
| `DRY_RUN` | `0` | `1` logs intended actions without pausing or notifying. |
| `CAND_RE` | see example | Command names eligible for pausing. |

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
