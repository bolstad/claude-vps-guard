#!/usr/bin/env bash
# Tests for bin/ccx-statusline: inside a ccx tmux session the bar already shows
# machine and account, so the status line must not repeat them.
# Run: bash tests/test_ccx_statusline.sh
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fails=0
json='{"model":{"display_name":"Opus"},"workspace":{"current_dir":"/tmp/proj"}}'

# Fake tmux: answers show-options from env vars set per case.
mkdir -p "$tmp/bin"
cat > "$tmp/bin/tmux" <<'T'
#!/usr/bin/env bash
case "$*" in
  *status-left*) printf '%s\n' "${FAKE_STATUS_LEFT:-}" ;;
  *@ccx_account*) printf '%s\n' "${FAKE_ACCOUNT:-}" ;;
esac
T
chmod +x "$tmp/bin/tmux"

run() { printf '%s' "$json" | env PATH="$tmp/bin:$PATH" CCX_HOST_LABEL=studio "$@" bash "$here/bin/ccx-statusline" | sed 's/\x1b\[[0-9;]*m//g'; }
check() { # name, output, must-contain, must-not-contain
    case "$2" in *"$3"*) ;; *) echo "FAIL $1: saknar '$3' i '$2'"; fails=$((fails+1)); return;; esac
    if [ -n "$4" ]; then case "$2" in *"$4"*) echo "FAIL $1: innehåller '$4' i '$2'"; fails=$((fails+1)); return;; esac; fi
    echo "ok   $1"
}

out="$(run TMUX= CLAUDE_CONFIG_DIR=/x/.claude-accounts/atdt)"
check "utanför tmux visas maskin och konto" "$out" "studio" ""
check "utanför tmux visas kontot" "$out" "atdt" ""

out="$(run TMUX=/tmp/s,1,0 FAKE_STATUS_LEFT='#[bold] studio #[default]#{@ccx_account}' FAKE_ACCOUNT=atdt CLAUDE_CONFIG_DIR=/x/.claude-accounts/atdt)"
check "i ccx-tmux visas inte maskinen" "$out" "Opus" "studio"
check "i ccx-tmux visas inte kontot" "$out" "Opus" "atdt"
check "i ccx-tmux visas katalogen" "$out" "/tmp/proj" ""

out="$(run TMUX=/tmp/s,1,0 FAKE_STATUS_LEFT='[#S]' FAKE_ACCOUNT='' CLAUDE_CONFIG_DIR=/x/.claude-accounts/atdt)"
check "i annan tmux visas maskin" "$out" "studio" ""
check "i annan tmux visas konto" "$out" "atdt" ""

[ "$fails" -eq 0 ] && echo "alla ok" || { echo "$fails fel"; exit 1; }
