#!/usr/bin/env zsh
# Click-handler for hausverwaltung-notify.sh — invoked by terminal-notifier
# when the user clicks a notification. Opens a herdr pane running an
# interactive `claude` session in the given cwd, seeded with the prompt that
# was persisted at notify time, so the user lands directly in a session that
# already knows the context. Falls back to Terminal.app without herdr.
#
# Usage: hausverwaltung-notify-open.sh <cwd> [prompt-file]
set -u
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

CWD="${1:-$HOME/hausverwaltung}"
PROMPT_FILE="${2:-}"
PROMPT=""
[ -n "$PROMPT_FILE" ] && [ -f "$PROMPT_FILE" ] && PROMPT="$(cat "$PROMPT_FILE")"

if command -v herdr >/dev/null 2>&1; then
    if [ -n "$PROMPT" ]; then
        herdr agent start claude --cwd "$CWD" -- claude "$PROMPT" && exit 0
    else
        herdr agent start claude --cwd "$CWD" -- claude && exit 0
    fi
fi

# Fallback: plain Terminal.app window (prompt must be typed manually).
/usr/bin/osascript <<EOF
tell application "Terminal"
    activate
    do script "cd ${CWD} && claude"
end tell
EOF
