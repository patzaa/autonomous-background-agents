#!/usr/bin/env zsh
# Observer investigate-launcher — what a notification CLICK runs.
#
# The Observer (com.hausverwaltung.observer) fires a terminal-notifier for any
# actionable agent with `-execute "<this script> <label>"`. Clicking it opens a
# FOCUSED herdr workspace with a claude session already seeded to investigate that
# exact agent — so "Show → straight to the concrete problem" is one click, no
# hunting. Runs when the human clicks (often hours after the 03:00 fire), so it
# re-derives the symptom from the log LIVE rather than trusting a stale arg.
#
# Usage: hausverwaltung-observer-investigate.sh <full-launchd-label>

set -uo pipefail
export PATH="/Users/dan/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

LABEL="${1:?usage: observer-investigate.sh <launchd-label>}"
SHORT="${LABEL#com.hausverwaltung.}"; SHORT="${SHORT#com.houseclaw.}"; SHORT="${SHORT#com.dan.}"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
# Paths from the PLIST, not guessed from the label — com.houseclaw.* / com.dan.*
# agents don't follow the hausverwaltung-<short> naming.
WRAPPER=$(plutil -extract ProgramArguments json -o - "$PLIST" 2>/dev/null | python3 -c "import sys,json; print(' '.join(json.load(sys.stdin)))" 2>/dev/null)
[ -n "$WRAPPER" ] || WRAPPER="$HOME/.local/bin/hausverwaltung-${SHORT}.sh"
LOG=$(plutil -extract StandardOutPath raw "$PLIST" 2>/dev/null)
[ -n "$LOG" ] || LOG="$HOME/Library/Logs/hausverwaltung-${SHORT}.log"
REPO="$HOME/hausverwaltung"

# Open AGENTTOP as the hub (not claude directly — Dan's call, 2026-07-15):
# agenttop starts in fleet mode sorted worst-first, so the agent that fired
# this notification is already at the top AND selected; one Enter there opens
# Claude Code seeded on exactly that agent (agenttop builds the prompt itself,
# from the live plist + log — fresher than anything we could pass along here).
WS=$(herdr workspace create --cwd "$REPO" --label "🔭 ${SHORT}" --focus 2>&1)
WSID=$(print -r -- "$WS" | python3 -c "import sys,json; print(json.load(sys.stdin)['result']['workspace']['workspace_id'])" 2>/dev/null)

if [ -z "$WSID" ]; then
  # herdr not running / socket down — fall back to opening the log so the click is never a dead end.
  open -a Console "$LOG" 2>/dev/null || open "$LOG" 2>/dev/null
  exit 0
fi

# Unique name per click — a fixed name collides with any other running agent
# of the same name (agent_name_taken → empty workspace, the 2026-07-15 bug).
NAME="agenttop-$(date +%H%M%S)"
OUT=$(herdr agent start "$NAME" --workspace "$WSID" --focus -- "$HOME/.local/bin/agenttop" 2>&1)
if print -r -- "$OUT" | grep -q '"error"'; then
  herdr workspace close "$WSID" >/dev/null 2>&1   # never leave an empty shell
  open -a Console "$LOG" 2>/dev/null || open "$LOG" 2>/dev/null
fi
