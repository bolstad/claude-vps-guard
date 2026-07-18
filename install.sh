#!/usr/bin/env bash
# install.sh - install claude-vps-guard for the current user.
#
# Copies the tools to PREFIX, links the two user-facing commands into BINDIR,
# writes a config file if none exists, and registers the watchdog with the
# platform service manager (systemd --user on Linux, launchd on macOS).
#
# Environment:
#   PREFIX           install location (default ~/.local/share/claude-vps-guard)
#   BINDIR           where the commands are linked (default ~/.local/bin)
#   CC_COMMAND_NAME  name of the session command (default cc)
#   NO_SERVICE=1     install files only, skip the service registration
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="${PREFIX:-$HOME/.local/share/claude-vps-guard}"
BINDIR="${BINDIR:-$HOME/.local/bin}"
CC_COMMAND_NAME="${CC_COMMAND_NAME:-cc}"
CONFIG_DIR="${CLAUDE_GUARD_CONFIG_DIR:-$HOME/.config/claude-vps-guard}"
STATE_DIR="${CLAUDE_GUARD_STATE_DIR:-$HOME/.cache/claude-vps-guard}"
LOG_DIR="${CLAUDE_GUARD_LOG_DIR:-$STATE_DIR/logs}"

case "$(uname -s)" in
    Linux)  OS=linux ;;
    Darwin) OS=macos ;;
    *)      echo "unsupported platform: $(uname -s)" >&2; exit 1 ;;
esac

say() { printf '%s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }

# --- files -------------------------------------------------------------------

mkdir -p "$PREFIX" "$BINDIR" "$CONFIG_DIR" "$STATE_DIR/paused" "$LOG_DIR"
rm -rf "$PREFIX/bin" "$PREFIX/lib"
cp -R "$SRC/bin" "$SRC/lib" "$PREFIX/"
chmod +x "$PREFIX"/bin/* "$PREFIX/lib/notify-mail.py"
say "installed to $PREFIX"

# 'cc' is also the traditional name of the C compiler. Shadowing it in a
# directory that precedes /usr/bin on PATH would redirect builds to tmux, so
# say so plainly and let CC_COMMAND_NAME pick another name.
existing_cc="$(command -v "$CC_COMMAND_NAME" 2>/dev/null || true)"
if [ -n "$existing_cc" ] && [ "$existing_cc" != "$BINDIR/$CC_COMMAND_NAME" ]; then
    warn "'$CC_COMMAND_NAME' already resolves to $existing_cc"
    warn "the link in $BINDIR shadows it if $BINDIR comes first on PATH"
    warn "re-run with CC_COMMAND_NAME=<other-name> to avoid the clash"
fi

ln -sf "$PREFIX/bin/cc" "$BINDIR/$CC_COMMAND_NAME"
ln -sf "$PREFIX/bin/claude-guard" "$BINDIR/claude-guard"
say "linked $CC_COMMAND_NAME and claude-guard into $BINDIR"

case ":$PATH:" in
    *":$BINDIR:"*) ;;
    *) warn "$BINDIR is not on PATH - add it to your shell profile" ;;
esac

if [ ! -f "$CONFIG_DIR/guard.conf" ]; then
    cp "$SRC/config/guard.conf.example" "$CONFIG_DIR/guard.conf"
    say "wrote default config to $CONFIG_DIR/guard.conf"
else
    say "kept existing config at $CONFIG_DIR/guard.conf"
fi

if [ ! -f "$CONFIG_DIR/mail.env" ]; then
    cp "$SRC/config/mail.env.example" "$CONFIG_DIR/mail.env.example"
    say "SMTP alerts are optional: fill in $CONFIG_DIR/mail.env.example and rename it to mail.env"
fi
chmod 600 "$CONFIG_DIR"/mail.env* 2>/dev/null || true

# --- service -----------------------------------------------------------------

if [ "${NO_SERVICE:-0}" = "1" ]; then
    say "skipping service registration (NO_SERVICE=1)"
    say "start the watchdog yourself with: $PREFIX/bin/claude-memwatch &"
    say "done - start a session with '$CC_COMMAND_NAME'"
    exit 0
fi

if [ "$OS" = linux ]; then
    if ! command -v systemctl >/dev/null 2>&1; then
        warn "systemctl not found - start the watchdog yourself: $PREFIX/bin/claude-memwatch &"
        exit 0
    fi
    unit_dir="$HOME/.config/systemd/user"
    mkdir -p "$unit_dir"
    sed "s|@BIN@|$PREFIX/bin|g" "$SRC/service/claude-memwatch.service.in" >"$unit_dir/claude-memwatch.service"
    systemctl --user daemon-reload
    systemctl --user enable --now claude-memwatch.service
    say "watchdog enabled: systemctl --user status claude-memwatch"
    # Without lingering, a user service stops when the last session logs out -
    # which is exactly when an unattended VPS still needs the watchdog.
    if command -v loginctl >/dev/null 2>&1; then
        if ! loginctl show-user "$(id -un)" -p Linger 2>/dev/null | grep -q 'Linger=yes'; then
            warn "user lingering is off, so the watchdog stops at logout"
            warn "enable it with: sudo loginctl enable-linger $(id -un)"
        fi
    fi
else
    agent_dir="$HOME/Library/LaunchAgents"
    label=io.github.claude-vps-guard.memwatch
    mkdir -p "$agent_dir"
    sed -e "s|@BIN@|$PREFIX/bin|g" -e "s|@LOGDIR@|$LOG_DIR|g" \
        "$SRC/service/$label.plist.in" >"$agent_dir/$label.plist"
    launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$agent_dir/$label.plist"
    say "watchdog loaded: claude-guard service"
    say "note: macOS has no per-process memory cap, so the watchdog is the only guard there"
fi

say "done - start a session with '$CC_COMMAND_NAME'"
