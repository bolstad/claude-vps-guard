#!/usr/bin/env bash
# common.sh - shared helpers for claude-vps-guard.
#
# Sourced by every script in bin/. Written for bash 3.2 so it runs on the
# stock /bin/bash that ships with macOS: no mapfile, no associative arrays.
#
# Platform differences (memory readings, process capping, service manager) are
# isolated here so the tools above stay identical on Linux and macOS.

GUARD_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_ROOT="$(cd "$GUARD_LIB_DIR/.." && pwd)"

GUARD_CONFIG_DIR="${CLAUDE_GUARD_CONFIG_DIR:-$HOME/.config/claude-vps-guard}"
GUARD_CONFIG="${CLAUDE_GUARD_CONFIG:-$GUARD_CONFIG_DIR/guard.conf}"
GUARD_STATE_DIR="${CLAUDE_GUARD_STATE_DIR:-$HOME/.cache/claude-vps-guard}"
GUARD_PAUSED_DIR="$GUARD_STATE_DIR/paused"
GUARD_LOG_DIR="${CLAUDE_GUARD_LOG_DIR:-$GUARD_STATE_DIR/logs}"
GUARD_LOG="$GUARD_LOG_DIR/memwatch.log"

# Precedence: environment > config file > built-in defaults. The config file
# uses plain assignments, so anything already set in the environment is saved
# before sourcing and restored afterwards - otherwise a one-off
# 'DRY_RUN=1 claude-memwatch' would be silently overridden by the file.
GUARD_TUNABLES="INTERVAL FLOOR_MB CRIT_MB PROC_HARD_MB SWAP_FLOOR_MB
NOTIFY_COOLDOWN DRY_RUN MAX_TICKS KEEP_LOG_BYTES CLAUDE_MEMORY_MAX CLAUDE_BIN
GUARD_USER CAND_RE NOTIFY_CMD CLAUDE_ACCOUNTS_DIR"

if [ -r "$GUARD_CONFIG" ]; then
    _guard_from_env=""
    for _v in $GUARD_TUNABLES; do
        if eval "[ -n \"\${$_v+set}\" ]"; then
            eval "_guard_env_$_v=\$$_v"
            _guard_from_env="$_guard_from_env $_v"
        fi
    done
    # shellcheck disable=SC1090
    . "$GUARD_CONFIG"
    for _v in $_guard_from_env; do
        eval "$_v=\$_guard_env_$_v"
    done
    unset _v _guard_from_env
fi

INTERVAL="${INTERVAL:-10}"
FLOOR_MB="${FLOOR_MB:-900}"
CRIT_MB="${CRIT_MB:-450}"
PROC_HARD_MB="${PROC_HARD_MB:-2800}"
SWAP_FLOOR_MB="${SWAP_FLOOR_MB:-400}"
NOTIFY_COOLDOWN="${NOTIFY_COOLDOWN:-60}"
DRY_RUN="${DRY_RUN:-0}"
MAX_TICKS="${MAX_TICKS:-0}"
CLAUDE_MEMORY_MAX="${CLAUDE_MEMORY_MAX:-3G}"
CLAUDE_BIN="${CLAUDE_BIN:-claude}"
CLAUDE_ACCOUNTS_DIR="${CLAUDE_ACCOUNTS_DIR:-$HOME/.claude-accounts}"
GUARD_USER="${GUARD_USER:-$(id -un)}"

# Which processes may be paused. Infrastructure (sshd, tmux, bash, the watchdog
# itself) deliberately does not match, so it can never be frozen.
CAND_RE="${CAND_RE:-^(claude|node|python|python3|Python|chromium|chrome|headless_shell|playwright)$}"

# --- platform ----------------------------------------------------------------

guard_os() {
    case "$(uname -s)" in
        Linux)  echo linux ;;
        Darwin) echo macos ;;
        *)      echo unknown ;;
    esac
}

GUARD_OS="$(guard_os)"

# The swap rule is Linux only. macOS sizes its swap file dynamically and grows
# it on demand, so free swap never trends toward zero under pressure: it
# oscillates inside a narrow band roughly one growth chunk wide. A floor under
# it is therefore permanently true, and the watchdog would pause a process on
# every tick with plenty of RAM free. Measured: SWAP_FLOOR_MB=1024 on a 16G Mac
# produced 4453 pauses, all logged 'low-mem', some with 8G available.
#
# Forcing the floor to 0 here makes 'swapfree < SWAP_FLOOR_MB' unsatisfiable,
# which disables the rule for every tool at once. A value set anyway (config
# file or environment) is kept in GUARD_SWAP_FLOOR_IGNORED so the tools can say
# they ignored it rather than dropping it silently. See docs/platforms.md.
GUARD_SWAP_FLOOR_IGNORED=""
if [ "$GUARD_OS" = macos ] && [ "${SWAP_FLOOR_MB:-0}" -gt 0 ] 2>/dev/null; then
    GUARD_SWAP_FLOOR_IGNORED="$SWAP_FLOOR_MB"
    SWAP_FLOOR_MB=0
fi

# Megabytes of memory that can be handed out without swapping or reclaiming.
mem_available_mb() {
    if [ "$GUARD_OS" = linux ]; then
        awk '/^MemAvailable:/ {printf "%d", $2/1024; exit}' /proc/meminfo
    elif [ "$GUARD_OS" = macos ]; then
        # No single equivalent of MemAvailable: approximate it as the pages the
        # kernel can reclaim without pressure (free + inactive + speculative +
        # purgeable), which is what Activity Monitor treats as available.
        vm_stat | awk '
            /page size of/ { for (i = 1; i <= NF; i++) if ($i == "of") { ps = $(i+1); break } }
            /^Pages free/            { f  = $3 }
            /^Pages inactive/        { ia = $3 }
            /^Pages speculative/     { sp = $3 }
            /^Pages purgeable/       { pu = $3 }
            END {
                if (ps == "") ps = 4096
                gsub(/\./, "", f); gsub(/\./, "", ia)
                gsub(/\./, "", sp); gsub(/\./, "", pu)
                printf "%d", (f + ia + sp + pu) * ps / 1048576
            }'
    else
        echo 0
    fi
}

swap_total_mb() {
    if [ "$GUARD_OS" = linux ]; then
        awk '/^SwapTotal:/ {printf "%d", $2/1024; exit}' /proc/meminfo
    elif [ "$GUARD_OS" = macos ]; then
        sysctl -n vm.swapusage 2>/dev/null | awk '{ for (i = 1; i <= NF; i++) if ($i == "total") { v = $(i+2); sub(/M$/, "", v); printf "%d", v; exit } }'
    else
        echo 0
    fi
}

swap_free_mb() {
    if [ "$GUARD_OS" = linux ]; then
        awk '/^SwapFree:/ {printf "%d", $2/1024; exit}' /proc/meminfo
    elif [ "$GUARD_OS" = macos ]; then
        sysctl -n vm.swapusage 2>/dev/null | awk '{ for (i = 1; i <= NF; i++) if ($i == "free") { v = $(i+2); sub(/M$/, "", v); printf "%d", v; exit } }'
    else
        echo 0
    fi
}

# "pid rss_mb stat comm args..." for every process owned by GUARD_USER.
# comm is derived from argv[0] rather than the ps comm column: with args= in
# the same invocation, macOS truncates comm to a fixed width, so a long
# interpreter path like /opt/homebrew/Cellar/python@3.12/... comes back as
# "/opt/homebrew/Ce" and the process would escape CAND_RE. argv[0] is not
# truncated; strip its directory to keep CAND_RE identical across platforms.
guard_ps() {
    ps -u "$GUARD_USER" -o pid=,rss=,stat=,args= 2>/dev/null | awk '
        {
            n = split($4, parts, "/")
            comm = parts[n]
            args = ""
            for (i = 4; i <= NF; i++) args = args (i > 4 ? " " : "") $i
            printf "%s %d %s %s %s\n", $1, int($2/1024), $3, comm, args
        }'
}

# Resident memory of a process and all its descendants, in kB.
rss_tree_kb() {
    ps -eo pid=,ppid=,rss= 2>/dev/null | awk -v root="$1" '
        { pid[NR] = $1; ppid[NR] = $2; rss[NR] = $3; n = NR }
        END {
            want[root] = 1
            # Repeat until no new descendants are picked up; process tables are
            # small enough that the quadratic sweep is not worth optimising.
            do {
                added = 0
                for (i = 1; i <= n; i++)
                    if (!want[pid[i]] && want[ppid[i]]) { want[pid[i]] = 1; added = 1 }
            } while (added)
            total = 0
            for (i = 1; i <= n; i++) if (want[pid[i]]) total += rss[i]
            printf "%d", total
        }'
}

pid_alive()  { kill -0 "$1" 2>/dev/null; }
pid_stopped() { case "$(ps -o stat= -p "$1" 2>/dev/null | tr -d ' ')" in [Tt]*) return 0 ;; *) return 1 ;; esac; }

file_size_bytes() { wc -c < "$1" 2>/dev/null | tr -d ' '; }

# --- notification ------------------------------------------------------------

# Send an alert. Subject is $1, body arrives on stdin.
#
# NOTIFY_CMD is the extension point: any command taking a subject argument and
# a body on stdin works (mail, curl to a webhook, terminal-notifier, ...).
# Unset, the bundled SMTP sender is used when it has been configured; otherwise
# the alert only reaches the log.
#
# Exit: 0 sent, 3 not configured, other = delivery failure.
guard_notify() {
    local subject="$1"
    if [ -n "${NOTIFY_CMD:-}" ]; then
        # shellcheck disable=SC2086
        $NOTIFY_CMD "$subject"
        return $?
    fi
    if [ -x "$GUARD_LIB_DIR/notify-mail.py" ]; then
        "$GUARD_LIB_DIR/notify-mail.py" "$subject"
        return $?
    fi
    cat >/dev/null
    return 3
}
