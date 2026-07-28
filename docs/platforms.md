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

### Swap, and why `SWAP_FLOOR_MB` does not work on macOS

Swap is read from `/proc/meminfo` on Linux and `sysctl vm.swapusage` on macOS.

**On macOS, free swap is not a pressure signal, and the swap rule should be disabled there.**
Set `SWAP_FLOOR_MB=0`, which makes the rule inert because `swapfree < 0` is never true.

On Linux with a fixed swap partition, `SwapFree` genuinely falls as swap fills, so a floor under
it detects real pressure. macOS instead sizes its swap file dynamically and grows it in chunks the
moment it starts running out. Free swap therefore never trends toward zero: it oscillates inside a
narrow band roughly the size of one growth chunk, no matter how much memory is under pressure. A
typical idle reading with several gigabytes of RAM free:

```
$ sysctl vm.swapusage
vm.swapusage: total = 3072.00M  used = 1934.81M  free = 1137.19M  (encrypted)
```

Any `SWAP_FLOOR_MB` at or above that band is then permanently satisfied, and rule 3 fires on every
tick forever. Measured on a 16G MacBook Air: `SWAP_FLOOR_MB=1024` produced 4453 `PAUSED` entries,
every single one with reason `low-mem`, many with 7 to 8G of available memory, far above a
`FLOOR_MB` of 2048. None of the pauses were driven by actual memory pressure. Two interactive
sessions sat frozen for over a day.

The failure is quiet by design. The watchdog is doing exactly what it was told, the log reason
says `low-mem`, and only the `avail=` figure in the same line reveals that memory was never low.
To check a machine:

```sh
grep -o 'reason=[a-z-]*' ~/.cache/claude-vps-guard/logs/memwatch.log | sort | uniq -c
grep PAUSED ~/.cache/claude-vps-guard/logs/memwatch.log | tail
```

If every pause is `low-mem` while `avail` is comfortably above `FLOOR_MB`, the swap rule is the
cause. The other two rules, `FLOOR_MB` and `PROC_HARD_MB`, work correctly on macOS and are what
the watchdog should rely on there.

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
