#!/usr/bin/env zsh
# OpenClaw chat-UI feature watch — weekly local run (Mon 02:00).
# Loaded by ~/Library/LaunchAgents/com.hausverwaltung.openclaw-ui-watch.plist
#
# WHAT IT DOES (read-only):
#   1. git pull the local openclaw reference checkout (~/openclaw)
#   2. diff the chat-UI source since the last evaluated SHA
#   3. ask `claude -p` which changes are NEW chat features worth PORTING to our
#      platform (it knows we already have tool output, grouped session picker,
#      chat-widgets, approval cards — so it skips refactors + things we have)
#   4. open a GATED GitHub issue (label `openclaw-ui-watch`) ONLY when there is
#      something portable; otherwise log + no-op
#   5. persist the new SHA so each run only evaluates what's new
#
# Complements (does NOT overlap):
#   - .github/workflows/openclaw-version-check.yml  → watches RELEASES
#   - com.hausverwaltung.openclaw-upgrade-validate  → validates IMAGE bumps
#   This one watches the UI SOURCE for feature ideas. It NEVER writes code,
#   never commits, never bumps anything — it only reads + may file one issue.

set -uo pipefail

export PATH="/Users/dan/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
export BASH_DEFAULT_TIMEOUT_MS=900000
export BASH_MAX_TIMEOUT_MS=3600000

# Fail-fast on git/curl when the network is flaky (matches the sibling crons).
export GIT_HTTP_LOW_SPEED_LIMIT=1000
export GIT_HTTP_LOW_SPEED_TIME=30

OPENCLAW_REF="$HOME/openclaw"          # real path; ~/hausverwaltung/openclaw-ref symlinks here
HV_REPO="$HOME/hausverwaltung"
GH_REPO="patzaa/Hausverwaltung"
GH_LABEL="openclaw-ui-watch"
STATE_DIR="$HOME/.local/state/openclaw-ui-watch"
SHA_FILE="$STATE_DIR/last-sha"
DATE=$(date +%Y-%m-%d)

# Chat-UI surface we care about (relative to the openclaw repo root).
CHAT_PATHS=(
    "ui/src/ui/chat"
    "ui/src/ui/app-render.ts"
    "ui/src/ui/app-render.helpers.ts"
    "ui/src/ui/session-display.ts"
    "ui/src/ui/thinking-labels.ts"
    "ui/src/ui/icons.ts"
    "ui/src/styles/chat"
)

echo ""
echo "=========================================="
echo "  OpenClaw UI watch: $(date -Iseconds)"
echo "=========================================="

# Bail early if GitHub is unreachable (Mac asleep / no wifi / DNS down).
if ! curl -sf --max-time 5 https://api.github.com/zen > /dev/null; then
    echo "Skipped: github.com unreachable (likely no network at this hour)."
    echo "If this keeps happening, run: sudo pmset repeat wakeorpoweron MTWRFSU 01:50:00"
    exit 0
fi

if [ ! -d "$OPENCLAW_REF/.git" ]; then
    echo "ERROR: $OPENCLAW_REF is not a git repo (expected the openclaw reference checkout)" >&2
    exit 1
fi

mkdir -p "$STATE_DIR"

echo "Pulling latest openclaw into $OPENCLAW_REF ..."
git -C "$OPENCLAW_REF" pull --ff-only 2>&1 | tail -3 || {
    echo "ERROR: git pull failed (not fast-forwardable?). Leaving SHA untouched."
    exit 1
}
NEW_HEAD=$(git -C "$OPENCLAW_REF" rev-parse HEAD)

# ── deterministic breakage sentinels (current-state, every run) ────────────
# Asserts our hardcoded OpenClaw contract (protocol version, RPC method names,
# gateway CLI flags) still holds at upstream HEAD. Drift here = the NEXT image
# bump will break us silently. Independent of the UI-diff below; de-duped by
# signature so we don't re-file the same warning every week.
source /Users/dan/.local/lib/hausverwaltung-openclaw-sentinels.sh
SIG_FILE="$STATE_DIR/last-sentinel-sig"
run_openclaw_sentinels "$OPENCLAW_REF" "$HV_REPO" "WT" "upstream HEAD"
echo "Sentinels: ${OCS_SUMMARY}"
echo "$OCS_REPORT"
LAST_SIG=$(cat "$SIG_FILE" 2>/dev/null || echo "")
if [ "$OCS_DRIFT" -eq 1 ]; then
    if [ "$OCS_SIGNATURE" = "$LAST_SIG" ]; then
        echo "Sentinel drift unchanged since last alert — not re-filing."
    else
        echo "NEW sentinel drift — filing urgent breakage issue."
        gh label create openclaw-upgrade --repo "$GH_REPO" \
            --description "OpenClaw upgrade blockers / breakage warnings" \
            --color D93F0B >/dev/null 2>&1 || true
        SBODY=$(mktemp)
        {
            echo "Deterministic breakage sentinels found drift between our hardcoded OpenClaw contract and **upstream HEAD** (\`${NEW_HEAD:0:12}\`). This will break us on the next OpenClaw image bump unless addressed BEFORE upgrading."
            echo ""
            echo "$OCS_REPORT"
            echo ""
            echo "🤖 Weekly cron \`com.hausverwaltung.openclaw-ui-watch\` (sentinel phase) — read-only. Verify + fix manually; re-runs won't re-file until the drift signature changes."
        } > "$SBODY"
        gh issue create --repo "$GH_REPO" \
            --title "OpenClaw breakage warning (sentinel drift @ HEAD)" \
            --label openclaw-upgrade \
            --body-file "$SBODY" 2>&1 | tail -1
        rm -f "$SBODY"
        echo "$OCS_SIGNATURE" > "$SIG_FILE"
    fi
elif [ -n "$LAST_SIG" ]; then
    echo "Sentinels recovered — clearing prior alert signature."
    : > "$SIG_FILE"
fi

# ── security watch (advisories + security commits + image CVEs) ────────────
# Runs every week regardless of UI/commit drift — a new advisory or CVE against
# our PINNED image is independent of new commits. First run baselines silently.
source /Users/dan/.local/lib/hausverwaltung-openclaw-security.sh
PINNED_VER=$(grep -oE 'ghcr\.io/openclaw/openclaw:[^[:space:]]+' "$HV_REPO/Dockerfile.openclaw" 2>/dev/null | head -1 | cut -d: -f2)
if [ -n "$PINNED_VER" ]; then
    LAST_SHA_SEC=$(cat "$SHA_FILE" 2>/dev/null || echo "")
    ocsec_run "openclaw/openclaw" "$PINNED_VER" "$OPENCLAW_REF" "$LAST_SHA_SEC" "$NEW_HEAD" \
        "ghcr.io/openclaw/openclaw:${PINNED_VER}" "$STATE_DIR/security"
    echo "Security: ${OCSEC_SUMMARY}"
    if [ "$OCSEC_NEW" -eq 1 ]; then
        echo "$OCSEC_REPORT"
        gh label create openclaw-security --repo "$GH_REPO" \
            --description "Upstream OpenClaw security advisories / CVEs / fixes to apply" \
            --color B60205 >/dev/null 2>&1 || true
        SECBODY=$(mktemp)
        {
            echo "New upstream OpenClaw security findings against our pinned version \`${PINNED_VER}\`. 🔴 = affects our pin OR high/critical — patch-worthy; 🟠 = heads-up."
            echo "$OCSEC_REPORT"
            echo ""
            echo "🤖 Weekly cron \`com.hausverwaltung.openclaw-ui-watch\` (security phase) — read-only. De-duped: re-runs won't re-file the same advisory/CVE."
        } > "$SECBODY"
        # hard findings (affects-our-pin / critical / CVE) also get the upgrade label
        SEC_LABELS=(--label openclaw-security)
        [ "${OCSEC_HARD:-0}" = 1 ] && SEC_LABELS+=(--label openclaw-upgrade)
        gh issue create --repo "$GH_REPO" \
            --title "OpenClaw security watch: new findings (${DATE})" \
            "${SEC_LABELS[@]}" --body-file "$SECBODY" 2>&1 | tail -1
        rm -f "$SECBODY"
    fi
else
    echo "Security: could not read pinned version from Dockerfile.openclaw — skipped."
fi

# First-ever run: record a baseline and exit (don't evaluate the whole history).
if [ ! -f "$SHA_FILE" ]; then
    echo "$NEW_HEAD" > "$SHA_FILE"
    echo "Baseline recorded at ${NEW_HEAD}. No evaluation on the first run."
    exit 0
fi
LAST_SHA=$(cat "$SHA_FILE")

if [ "$LAST_SHA" = "$NEW_HEAD" ]; then
    echo "No new upstream commits since ${LAST_SHA}. No-op."
    exit 0
fi

# What changed in the chat surface since we last looked?
CHANGED_FILES=$(git -C "$OPENCLAW_REF" diff --name-only "${LAST_SHA}..${NEW_HEAD}" -- "${CHAT_PATHS[@]}")
if [ -z "$CHANGED_FILES" ]; then
    echo "New commits, but none touch the chat-UI surface. Advancing SHA, no-op."
    echo "$NEW_HEAD" > "$SHA_FILE"
    exit 0
fi

DIFFSTAT=$(git -C "$OPENCLAW_REF" diff --stat "${LAST_SHA}..${NEW_HEAD}" -- "${CHAT_PATHS[@]}")
echo "Chat-UI changes since ${LAST_SHA:0:12}:"
echo "$DIFFSTAT"

REPORT=$(mktemp)
trap 'rm -f "$REPORT"' EXIT

PROMPT="You are the weekly OpenClaw chat-UI feature watch. The local OpenClaw reference checkout at ${OPENCLAW_REF} just pulled new commits. Your job: judge which of the chat-UI changes since the last review are NEW or improved features worth PORTING into our own chat UI — and skip everything else.

# CONTEXT: what OUR app already has
Our platform lives at ${HV_REPO} (read it — do NOT modify it). Its chat UI is our OWN React code under \`src/components/chat/\` + \`src/components/chat-widgets/\` + \`src/lib/chat/\`, proxying the OpenClaw gateway. We ALREADY have: streamed tool-call/tool-output cards, a grouped agent+session picker, markdown rendering, curated chat-widgets (poll/card/pdf/email-reply), and cora-action approval cards. Do NOT flag things we already have.

# THE DIFF TO EVALUATE
Reference repo: ${OPENCLAW_REF} (you have shell + read access). Review the chat-UI changes in this commit range:
  RANGE: ${LAST_SHA}..${NEW_HEAD}
  PATHS: ${CHAT_PATHS[*]}
Diffstat:
${DIFFSTAT}

Drive your own inspection — run e.g. \`git -C ${OPENCLAW_REF} log --oneline ${LAST_SHA}..${NEW_HEAD} -- <path>\` and \`git -C ${OPENCLAW_REF} diff ${LAST_SHA}..${NEW_HEAD} -- <file>\` and read the changed files in full. Cross-read our repo to confirm we don't already have a given capability.

# WHAT COUNTS AS A PORTABLE FINDING
- A genuinely NEW user-facing chat feature (a new control, panel, widget, interaction, affordance) we lack.
- A clear UX IMPROVEMENT to a feature we have (e.g. better collapse/grouping, error handling, accessibility, empty states).
NOT portable (ignore): internal refactors, test-only changes, lit-html plumbing, perf tweaks with no UX change, renames, dependency bumps, anything we already do.

# OUTPUT FORMAT — STRICT
The VERY FIRST line of your output MUST be exactly one of:
  VERDICT: PORTABLE
  VERDICT: NOTHING
Then (only if PORTABLE) a concise GitHub-issue-ready markdown body:
  - One \`## <feature name>\` section per finding (aim for the 1-5 that genuinely matter; don't pad).
  - Each section: what it is (1-2 sentences), the upstream file:line / commit, why it's worth porting for us, rough effort (S/M/L), and which of OUR files it would touch.
  - End with a one-line 'Recommended next' pointing at the single highest-value item.
Keep it tight and skimmable. Do NOT modify any files, do NOT commit, do NOT open the issue yourself — just print the verdict + body."

echo ""
echo "[$(date -Iseconds)] Evaluating diff with claude ..."
"$HOME/.local/bin/hausverwaltung-claude-run.sh" "$REPORT" --dangerously-skip-permissions -p "$PROMPT"
CLAUDE_EXIT=$?

if [ "$CLAUDE_EXIT" -ne 0 ]; then
    echo "ERROR: claude exited ${CLAUDE_EXIT} (infra failure?). NOT advancing SHA — will retry next week."
    echo "----- output tail -----"
    tail -20 "$REPORT"
    exit 1
fi

# We successfully evaluated this range — advance the SHA regardless of verdict.
echo "$NEW_HEAD" > "$SHA_FILE"

if head -1 "$REPORT" | grep -qiE '^VERDICT:[[:space:]]*PORTABLE'; then
    echo "[$(date -Iseconds)] Portable findings — opening GitHub issue."
    # Ensure the label exists (gh issue create fails on a missing label —
    # cf. the deploy-validate 'could not add label' footgun).
    gh label create "$GH_LABEL" --repo "$GH_REPO" \
        --description "Upstream OpenClaw chat-UI features worth porting" \
        --color BFD4F2 >/dev/null 2>&1 || true

    BODY=$(mktemp)
    {
        tail -n +2 "$REPORT"   # drop the VERDICT line
        echo ""
        echo "---"
        echo "_Range:_ \`${LAST_SHA:0:12}..${NEW_HEAD:0:12}\` · _Changed:_"
        echo '```'
        echo "$DIFFSTAT"
        echo '```'
        echo ""
        echo "🤖 Weekly cron \`com.hausverwaltung.openclaw-ui-watch\` — read-only evaluation of the OpenClaw reference chat UI. **Suggestions only, needs human review.**"
    } > "$BODY"

    ISSUE_URL=$(gh issue create --repo "$GH_REPO" \
        --title "OpenClaw UI watch: portable chat-UI changes (${DATE})" \
        --label "$GH_LABEL" \
        --body-file "$BODY" 2>&1 | tail -1)
    rm -f "$BODY"
    echo "Issue: ${ISSUE_URL}"
    echo "Outcome: issue_opened"
else
    echo "Nothing portable in this range. Advanced SHA to ${NEW_HEAD:0:12}, no issue."
    echo "Outcome: nothing_portable"
fi

echo "Run complete: finished=$(date -Iseconds)"
exit 0
