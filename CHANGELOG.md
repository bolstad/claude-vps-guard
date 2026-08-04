# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[semantic versioning](https://semver.org/spec/v2.0.0.html).

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
