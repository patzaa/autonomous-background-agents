#!/usr/bin/env zsh
# Clickable macOS notification for the hausverwaltung cron agents.
# Click → hausverwaltung-notify-open.sh opens a herdr pane with an interactive
# `claude` session in <cwd>, seeded with <prompt> (persisted to a state file so
# the click can happen hours later, e.g. next morning). Falls back to a plain
# osascript notification when terminal-notifier is unavailable.
#
# Usage: hausverwaltung-notify.sh <title> <subtitle> <message> [cwd] [prompt]
set -u
TITLE="${1:?title required}"
SUBTITLE="${2:-}"
MESSAGE="${3:?message required}"
CWD="${4:-$HOME/hausverwaltung}"
PROMPT="${5:-}"

STATE="$HOME/.local/state/hausverwaltung-notify"
mkdir -p "$STATE"
# prompts are one-shot context; drop stale ones after a week
find "$STATE" -name 'prompt-*.txt' -mtime +7 -delete 2>/dev/null || true

TN="$(command -v terminal-notifier || true)"
[ -z "$TN" ] && [ -x /opt/homebrew/bin/terminal-notifier ] && TN=/opt/homebrew/bin/terminal-notifier

if [ -n "$TN" ] && [ -x "$TN" ]; then
    PF=""
    if [ -n "$PROMPT" ]; then
        PF="$STATE/prompt-$(date +%s)-$$.txt"
        printf '%s' "$PROMPT" > "$PF"
    fi
    "$TN" -title "$TITLE" -subtitle "$SUBTITLE" -message "$MESSAGE" -sound Basso \
        -execute "$HOME/.local/bin/hausverwaltung-notify-open.sh '$CWD' '$PF'" >/dev/null 2>&1
else
    /usr/bin/osascript -e "display notification \"$MESSAGE\" with title \"$TITLE\" subtitle \"$SUBTITLE\" sound name \"Basso\"" 2>/dev/null || true
fi
