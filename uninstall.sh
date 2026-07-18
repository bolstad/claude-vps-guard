#!/usr/bin/env bash
# uninstall.sh - remove claude-vps-guard for the current user.
#
# Stops and unregisters the watchdog, removes the installed files and the
# command links. Config and logs are left in place unless PURGE=1.
set -euo pipefail

PREFIX="${PREFIX:-$HOME/.local/share/claude-vps-guard}"
BINDIR="${BINDIR:-$HOME/.local/bin}"
CC_COMMAND_NAME="${CC_COMMAND_NAME:-cc}"
CONFIG_DIR="${CLAUDE_GUARD_CONFIG_DIR:-$HOME/.config/claude-vps-guard}"
STATE_DIR="${CLAUDE_GUARD_STATE_DIR:-$HOME/.cache/claude-vps-guard}"

say() { printf '%s\n' "$*"; }

# Only touch a unit that actually belongs to this installation. A unit of the
# same name pointing somewhere else was put there by someone else, and removing
# it would leave that setup running with no unit file behind it.
belongs_to_prefix() {
    [ -f "$1" ] && grep -q "$PREFIX" "$1"
}

case "$(uname -s)" in
    Linux)
        unit="$HOME/.config/systemd/user/claude-memwatch.service"
        if ! command -v systemctl >/dev/null 2>&1; then
            say "systemctl not found - nothing to unregister"
        elif belongs_to_prefix "$unit"; then
            systemctl --user disable --now claude-memwatch.service 2>/dev/null || true
            rm -f "$unit"
            systemctl --user daemon-reload 2>/dev/null || true
            say "watchdog unregistered"
        else
            say "left $unit alone - it does not point into $PREFIX"
        fi
        ;;
    Darwin)
        label=io.github.claude-vps-guard.memwatch
        plist="$HOME/Library/LaunchAgents/$label.plist"
        if belongs_to_prefix "$plist"; then
            launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
            rm -f "$plist"
            say "watchdog unregistered"
        else
            say "left $plist alone - it does not point into $PREFIX"
        fi
        ;;
esac

# Only remove links that point into this installation.
for link in "$BINDIR/$CC_COMMAND_NAME" "$BINDIR/claude-guard"; do
    [ -L "$link" ] || continue
    case "$(readlink "$link")" in
        "$PREFIX"/*) rm -f "$link" ;;
    esac
done
rm -rf "$PREFIX"
say "files removed from $PREFIX"

if [ "${PURGE:-0}" = "1" ]; then
    rm -rf "$CONFIG_DIR" "$STATE_DIR"
    say "config and state purged"
else
    say "config kept in $CONFIG_DIR, state kept in $STATE_DIR (PURGE=1 removes them)"
fi

say "note: processes paused by the watchdog stay frozen - resume them before uninstalling"
