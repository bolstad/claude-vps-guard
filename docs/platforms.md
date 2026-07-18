# Platform differences

The tools behave the same way on both platforms; what differs is what the operating system can
enforce and how the same numbers are obtained. Everything below is isolated in `lib/common.sh`.

## Per-session memory cap

| | Linux | macOS |
| --- | --- | --- |
| Mechanism | `systemd-run --user --scope -p MemoryMax=...` | none |
| Effect | Runaway session is OOM killed inside its own cgroup | Session runs uncapped |

macOS has no per-process equivalent of a cgroup memory limit. `ulimit -v` exists but bounds
virtual address space, which a modern JavaScript runtime reserves generously without ever
touching, so it either does nothing or kills a healthy session. The package therefore leaves
sessions uncapped on macOS and relies on the watchdog, which works identically on both platforms.

Practical consequence: on macOS a runaway session keeps growing until the watchdog freezes it at
`PROC_HARD_MB` or when available memory crosses `FLOOR_MB`. On a laptop with swap that is an
inconvenience; on a small VPS the Linux cap is what prevents an outage.

## Available memory

Linux reads `MemAvailable` from `/proc/meminfo`.

macOS has no single equivalent, so the reading is approximated from `vm_stat` as
free + inactive + speculative + purgeable pages, which matches what Activity Monitor treats as
available. It is an estimate: under heavy file caching macOS may report more headroom than a
single process can actually claim at once.

Swap: `/proc/meminfo` on Linux, `sysctl vm.swapusage` on macOS. macOS swap grows dynamically, so
`SWAP_FLOOR_MB` triggers later there than on a VPS with a fixed swap partition.

## Per-session memory in `ccx ls`

On Linux a capped session has its own systemd scope, and the cgroup's `memory.current` is exact,
including every child process. Everywhere else the resident memory of the pane's process tree is
summed instead, which double counts shared pages and is therefore an upper bound.

## Service manager

| | Linux | macOS |
| --- | --- | --- |
| Unit | `~/.config/systemd/user/claude-memwatch.service` | `~/Library/LaunchAgents/io.github.claude-vps-guard.memwatch.plist` |
| Control | `systemctl --user ...` | `launchctl bootstrap` / `bootout` / `kickstart` |
| Survives logout | Requires `loginctl enable-linger` | Yes, a `gui/` agent runs while the user is logged in |

`claude-guard start|stop|restart|service` wraps both, so the same command works either way.

The systemd unit caps the watchdog itself at `MemoryMax=128M`; launchd offers no equivalent, but
the watchdog is a bash loop calling `ps` and stays in the low single-digit megabytes.

## Shell compatibility

macOS ships bash 3.2. The scripts avoid `mapfile`, associative arrays and other bash 4 features,
and use `wc -c` rather than the incompatible `stat` flags on GNU and BSD. `ps` is invoked with
options common to both, and command names are reduced to their basename because macOS reports
`comm` as an absolute path.
