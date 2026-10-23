# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[semantic versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.6.0] - 2026-10-23

### Added

- The account next to the machine name. The `ccx` tmux status bar and `ccx-statusline` show which
  account a session runs as (the `CLAUDE_CONFIG_DIR` name, or a grey `default`), each account in a
  colour derived from its name. `CCX_ACCOUNT_COLORS="name=colour ..."` in `guard.conf` overrides
  the colours. Running sessions get the label the next time `ccx` attaches to the server.

## [1.5.0] - 2026-10-22

### Added

- `ccx <name> -a <account>` asks before creating an account that does not exist yet. It lists the
  existing accounts under `CLAUDE_ACCOUNTS_DIR` and creates the new directory only after a `y`; a
  typo such as `carnabhy` for `carnaby` used to create a new, empty account without a word and
  start a fresh login in it. Not interactive: nothing is started unless `--new-account` is given.
  Reattaching to a running session is unaffected.

### Fixed

- `ccx -c <session-id>` resumes under the account the conversation belongs to. An inherited
  `CLAUDE_CONFIG_DIR` (inside tmux: the server's global environment) won over the account `-c`
  looked up, so Claude Code found no conversation and the pane closed at once.
- An explicit `-a` now wins over an inherited `CLAUDE_CONFIG_DIR`. Inside a `ccx` session that
  variable is always set, so `ccx other -a <account>` started from there quietly ran under the
  calling session's account.

## [1.4.0] - 2026-10-19

### Added

- Scrolling in `ccx` sessions. `ccx`'s own tmux server now has the mouse on, PgUp/PgDn bound and
  50 000 lines of history per pane, where stock tmux has the mouse off and 2 000 lines, so neither
  the wheel nor PgUp reached Claude Code's earlier output. In a normal pane the wheel and PgUp enter
  copy-mode; in alternate screen (Claude Code's `"tui": "fullscreen"`, `less`, `vim`) they go to
  the program. The history limit is set before the session's first pane is created, so it applies
  to new sessions straight away. `CCX_TMUX_SCROLL=off` and `CCX_TMUX_HISTORY=0` opt out. The
  shared default server is left alone.

## [1.3.0] - 2026-10-19

### Added

- The machine name in the tmux status bar and window titles. `ccx` puts `CCX_HOST_LABEL` (default
  `hostname -s`) first in `status-left` of its own tmux server, in a colour derived from the label
  (or `CCX_HOST_COLOR`), and titles windows `<host>: <session>`, so a session reached over ssh can
  no longer be mistaken for a local one. Set the label in `guard.conf` when the hostname is not
  what you call the machine. Applied when a session is created or attached on the `ccx` server; the
  shared default server is left alone.
- `ccx-statusline`, a status line for Claude Code that shows the same machine name and colour
  outside tmux too (plain terminal, ssh, IDE), followed by the model and directory. Linked into
  `~/.local/bin` by the installer; enable it with
  `"statusLine": {"type": "command", "command": "~/.local/bin/ccx-statusline"}` in `settings.json`.

## [1.2.0] - 2026-10-17

### Added

- `ccx --version` (`-V`): print the version of the installed copy. The version is a constant in
  `bin/ccx`, bumped together with the changelog on each release, because `git describe` only works
  inside a clone and an installed copy could not otherwise tell which version it is. Copies older
  than 1.2.0 do not recognise the flag.
- Daily snapshots of the session list in `~/.cache/claude-vps-guard/snapshots/`, one file a day
  holding every session seen that day (newest row wins per name), pruned after 30 days
  (`CCX_SNAPSHOT_KEEP_DAYS`). `ccx snapshots` lists them and `ccx up --from YYYY-MM-DD` restores from
  a day's file.
- The list from before a restart is copied to `snapshots/ccx-sessions.before-restart-<date>.tsv`
  before the first save after the restart replaces it.
- A warning before a session is started from scratch after a restart. If the saved list is older
  than the last boot, nothing is running and saved sessions are not, `ccx` asks whether to run
  `ccx up`, continue, or quit (default). Only in a terminal and only after a restart; `ccx up` passes
  `--no-warn` to its own tabs, and `CCX_WARN=never` disables it.

### Fixed

- `ccx save` replaced `<list>.prev` on every run, because the timestamp column differs each time, so
  `.prev` was only ever the list from a minute ago. It now changes only when the sessions do.

## [1.1.1] - 2026-10-16

### Fixed

- The directory probe behind `ccx doctor` and the pre-flight check before creating a session put the
  path inside single quotes in a shell command, so a directory with an apostrophe in its name (or
  anything else a quote can break out of) was reported as "NO ACCESS" even though it was readable,
  and the stray quote was interpreted by the shell. The path is now quoted properly. `sq()`, the
  quoting helper, is written so that it also works on the bash 3.2 that ships with macOS, which
  mangles the backslashes of the usual inline form.
- The same probe passes the command through `tmux run-shell`, which expands tmux formats in its
  argument, so a `#(command)` in a directory name was run by tmux itself. `#` is now escaped as
  `##` (tmux's own escape for a literal `#`). `new-session -c` and `-s` do not run commands from
  formats and needed no change.

## [1.1.0] - 2026-10-16

### Added

- `ccx up [--windows] [-n]`: reopen every session in one sweep on macOS with Ghostty 1.3 or later,
  which exposes AppleScript. One tab per session in a new window (`--windows` for a window each,
  `CCX_OPEN_MODE=windows` to make that the default, `-n` to only print the plan). A session that
  is still running in tmux is attached to; a lost one is recreated with `claude --resume <id>` in
  its old directory and account; sessions that already have a client attached are skipped.
  Every tab runs `ccx` itself through the user's own shell (`exec ccx ...` as initial input), so
  the tmux server is born inside Ghostty and inherits its access to external volumes, and the tab
  closes when `ccx` ends.
- `ccx save [file]`: record every running session - name, account, working directory and Claude
  Code conversation id - in `~/.cache/claude-vps-guard/ccx-sessions.tsv`, or in `<file>`. With a
  server alive the whole list is rewritten; with no server running the previous list is kept, which
  is the list needed after a crash or reboot. Quiet unless run in a terminal, so it suits a
  scheduled job.
- `ccx up --from <file>`: restore from a list saved earlier, for ending sessions on purpose while a
  save job keeps rewriting the default list.
- `ccx doctor [directory]`: report whether each tmux server can read a directory.
- `docs/platforms.md`: why a long-lived tmux server can lose access to external volumes on macOS,
  and why that shows up as a misleading "low max file descriptors" crash.
- `docs/blog.html`: a longer write-up, "Built to survive the machine it runs on", covering the
  problem, the two layers of protection, and the use cases the tool was actually built for. Linked
  from the README; served as a static page by GitHub Pages alongside the README-as-index site.
- `docs/platforms.md`: documented why the per-session cap disables swap (`MemorySwapMax=0`) rather
  than just capping RAM - without it, hitting `MemoryMax` triggers reclaim-via-swap before any OOM
  kill, which turns a contained memory limit into host-wide disk I/O contention while the session
  thrashes, and can exhaust the swap headroom the watchdog's own `SWAP_FLOOR_MB` rule depends on.
- `ccx -c`/`--continue <session-id>`: the one-step version of `ccx resumable` + `ccx <name> -a
  <account> -r`. Looks up which directory and account a specific session id belongs to (across
  every account, same lookup `resumable` uses) and builds a new tmux session there running `claude
  --resume <session-id>`, named after the target directory and deduped against whatever tmux
  sessions already exist so several `-c` calls in a row do not pile into the same session. If that
  id is already `active` rather than `resumable`, it does not start a duplicate conversation -
  it jumps straight to the tmux pane already holding it (via the `tmux` target Claude Code records
  in `sessions/<pid>.json` when launched inside one), or reports the live pid if that pane is not
  reachable through tmux. An explicit name (`ccx work -c <id>`) reattaches to an existing tmux
  session of that name first, same as `-a` and `-r`.
- `ccx resumable [N|all]`: list Claude Code conversations you can resume, newest first, across
  the default account *and* every `-a` account under `CLAUDE_ACCOUNTS_DIR`. Reads each session's
  own recorded working directory instead of decoding it back out of the encoded project directory
  name, which is ambiguous the moment a real path contains a dash (`~/.claude/projects` turns every
  `/` into `-`). Pairs with `ccx <name> -a <account> -r`: this finds which directory and account a
  dropped session needs, that one rebuilds it. Solves the same problem as `-r` above, one level up -
  `-r` resumes a session once you already know where it lived; `resumable` is how you find that out
  after a reboot wipes every tmux session at once. Each row also reports `STATUS` and `NAME`,
  cross-checked against Claude Code's own `sessions/<pid>.json` lock files: `active (busy|idle)`
  when a live process still holds that conversation (a `kill -0` check on the recorded pid, since a
  crashed process leaves its lock file behind looking identical to a running one), `resumable` when
  it only exists on disk. `NAME` is the name Claude Code derives for a run and only exists while
  that process is up, so it reads `-` for anything not currently active.
- `ccx <name> -r`/`--resume`: build the same tmux session, memory cap and
  account as usual, but hand Claude Code `--resume` instead of starting a
  blank conversation. For picking sessions back up after a reboot wipes tmux
  but leaves Claude Code's own conversation history on disk. Only takes
  effect when a new session is actually created; reattaching to a session
  that is still running ignores it, same as `-a`.

### Changed

- **`ccx` now runs its sessions on its own tmux server** (socket `ccx`, `CCX_TMUX_SOCKET` to
  override) instead of the shared default one, so a default server that has lost its macOS
  permissions can no longer take new sessions down with it. Sessions that are still on the default
  server keep working: `ccx ls` lists both servers with a new `SERVER` column, and `ccx <name>`,
  `ccx -c <id>` and `ccx up` find them there (`CCX_LEGACY_SOCKET` to override, mainly for tests).
  Upgrading needs no action; existing sessions simply live on until they end.
- New sessions are created detached and then attached, and the tmux server sets the window title to
  the session name, so several Ghostty windows or tabs can be told apart.
- `ccx` puts `~/.local/bin`, `/opt/homebrew/bin` and `/usr/local/bin` on `PATH` itself, so it also
  works from launchd jobs and AppleScript-launched windows that start with a minimal `PATH`.

### Fixed

- Before creating a session `ccx` now checks that the tmux server can read the target directory. If
  it cannot, it says so and what to do, instead of letting Claude Code crash with the misleading
  `low max file descriptors` message.
- **`make install` built a stale copy of the installer instead of running it.**
  With no makefile in the tree, the target `install` matched make's built-in
  `%: %.sh` rule, whose recipe is `cat $< >$@` followed by `chmod a+x $@`. The
  result was an executable file named `install`, byte-identical to `install.sh`
  at that moment and silently out of date from the next edit onwards, sitting in
  the repository root looking exactly like a real installer. Added a makefile
  with phony `install`, `uninstall` and `help` targets, so `make install` runs
  the installer. Environment variables such as `NO_SERVICE=1` and `PREFIX` pass
  through unchanged.

## [1.0.0] - 2026-08-04

First tagged release. Everything below was developed between 2026-07-18 and
2026-08-04 and is bundled here as the initial version.

### Added

- `ccx`: start or reattach to a named tmux session running Claude Code, memory
  capped where the platform allows it. Several names give several parallel
  sessions, and a dropped connection becomes a reattach rather than lost work.
- `ccx ls`: list Claude sessions with memory used, windows, account and creation
  time per session.
- `claude-guard`: inspect the watchdog, list and release paused processes,
  control the service.
- `claude-memwatch`: user service that samples available memory every 10 seconds
  and `SIGSTOP`s the largest candidate before the system reaches OOM. Only
  processes matching a whitelist can be paused; sshd, tmux and the shell never
  match, and the watchdog never pauses itself.
- Per-session memory cap on Linux via a systemd scope with `MemoryMax`, so a
  runaway session is OOM killed inside its own cgroup instead of taking the host
  with it.
- Multi-account support: `ccx <name> -a <account>` points that session's Claude
  Code at its own config directory (`~/.claude-accounts/<account>` by default),
  so several Anthropic accounts stay logged in side by side without
  re-authenticating. The account is recorded in the tmux session's own
  environment, so a plain `ccx <name>` reattaches with the same account.
- `install.sh` and `uninstall.sh`, with `PREFIX`, `BINDIR`, `CC_COMMAND_NAME`
  and `NO_SERVICE` as knobs. Service registration through systemd on Linux and
  launchd on macOS.
- Optional alerts: a bundled SMTP sender, or any command given as `NOTIFY_CMD`.
- `docs/platforms.md` covering the Linux and macOS differences, and the README
  published as a GitHub Pages site.

### Fixed

- **`-a <account>` was silently ignored whenever a tmux server was already
  running.** A new tmux session does not inherit the calling shell's
  environment: it starts from the tmux *server's* environment, refreshed only
  for the variables listed in `update-environment`. `CLAUDE_CONFIG_DIR` is not
  one of those, so exporting it before `new-session` reached the session only
  when that same call also happened to start the server. On any host with a
  session already up, every later `ccx <name> -a <account>` quietly ran under
  whichever account the server was started with. The variable is now handed to
  the command explicitly with `env(1)` and recorded with `tmux set-environment`,
  which also makes the `ACCOUNT` column in `ccx ls` report the real account
  instead of `-`.
- Candidate matching on macOS: read the untruncated `comm` and recognise
  framework Python, which the truncated name missed.
- Reinstalling over a running watchdog restarts the service instead of relying
  on `systemctl enable --now`, which does nothing when the unit is already
  running and would otherwise leave the old code in memory under a unit file
  claiming otherwise.
- `claude-guard`'s help block derives where it ends rather than hardcoding a
  line number.

### Changed

- The session command is named `ccx`, not the shorter `cc`, because `cc` is the
  traditional name of the C compiler: shadowing it in a directory ahead of
  `/usr/bin` on `PATH` would send builds to tmux. `CC_COMMAND_NAME=cc` opts into
  the short name anyway, and the installer warns when the chosen name already
  resolves elsewhere.
- **`SWAP_FLOOR_MB` is forced to `0` on macOS and the swap rule is disabled
  there.** macOS grows its swap file on demand, so free swap stays inside a
  narrow band instead of falling under pressure. Any floor at or above that band
  makes the rule permanently true. Measured before it was disabled:
  `SWAP_FLOOR_MB=1024` on a 16G Mac produced 4453 spurious pauses, all logged as
  `low-mem`, some with 8G still available. A value set anyway is now reported as
  ignored rather than dropped silently. The setting works as intended on Linux.

[1.0.0]: https://github.com/bolstad/claude-vps-guard/releases/tag/v1.0.0
[1.1.0]: https://github.com/bolstad/claude-vps-guard/releases/tag/v1.1.0
[1.1.1]: https://github.com/bolstad/claude-vps-guard/compare/v1.1.0...v1.1.1
[1.2.0]: https://github.com/bolstad/claude-vps-guard/compare/v1.1.1...v1.2.0
[1.3.0]: https://github.com/bolstad/claude-vps-guard/compare/v1.2.0...v1.3.0
[1.4.0]: https://github.com/bolstad/claude-vps-guard/compare/v1.3.0...v1.4.0
[1.5.0]: https://github.com/bolstad/claude-vps-guard/compare/v1.4.0...v1.5.0
[1.6.0]: https://github.com/bolstad/claude-vps-guard/compare/v1.5.0...v1.6.0
[Unreleased]: https://github.com/bolstad/claude-vps-guard/compare/v1.6.0...HEAD
