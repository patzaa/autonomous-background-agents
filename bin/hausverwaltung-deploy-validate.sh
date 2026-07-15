#!/usr/bin/env zsh
# Hausverwaltung deploy-validate cron — daily 01:00 local.
# HYBRID: Mac creates worktree of origin/main, rsyncs to VPS, VPS builds
# (prod-equivalent x86_64), Mac runs /qa-only + /design-review (read-only).
# If issues found: Issue. Otherwise: silent green-day no-op.

set -uo pipefail

export PATH="/Users/dan/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
export BASH_DEFAULT_TIMEOUT_MS=900000
export BASH_MAX_TIMEOUT_MS=3600000

# Fail-fast on git/curl when the network is flaky — without these, git defaults
# wait ~10 min before timing out (burned time on 2026-05-27 at 01:13).
export GIT_HTTP_LOW_SPEED_LIMIT=1000
export GIT_HTTP_LOW_SPEED_TIME=30

source /Users/dan/.local/lib/hausverwaltung-vps-validate.sh

REPO="$HOME/hausverwaltung"
DATE=$(date +%Y-%m-%d)
VALIDATE_PORT=3001

vps_print_header "Deploy-validate (current main)"

# Bail early if GitHub is unreachable (Mac asleep / no wifi / DNS down).
# Without this, git fetch hangs ~10 min before failing. With this, ~5s.
if ! curl -sf --max-time 5 https://api.github.com/zen > /dev/null; then
    echo "Skipped: github.com unreachable (likely no network at this hour)."
    echo "If this keeps happening, run: sudo pmset repeat wakeorpoweron MTWRFSU 00:50:00"
    exit 0
fi

if [ ! -d "$REPO/.git" ]; then echo "ERROR: $REPO is not a git repo"; exit 1; fi
cd "$REPO"
vps_load_env "$REPO"

VALIDATE_URL="http://${VPS_HOST}:${VALIDATE_PORT}"

# ── pre-flight ─────────────────────────────────────────────────────────────

if ! vps_ping; then
    echo "ERROR: VPS unreachable"
    exit 1
fi

git fetch origin main 2>&1 | tail -2
MAIN_SHA=$(git rev-parse --short origin/main)
echo "✓ Validating origin/main @ ${MAIN_SHA}"

# Pre-pull OpenClaw image anonymously to avoid 403 on build
PINNED=$(git show origin/main:Dockerfile.openclaw 2>/dev/null \
    | grep -oE 'ghcr\.io/openclaw/openclaw:[^[:space:]]+' | head -1)
if [ -n "$PINNED" ]; then
    echo "Pre-pulling ${PINNED} (anonymous) ..."
    vps_pre_pull_anonymous "$PINNED" >/dev/null 2>&1 || echo "WARN: pre-pull failed; build may also fail"
fi

# ── Mac worktree + rsync to VPS ───────────────────────────────────────────

WORKSPACE_NAME="hausverwaltung-validate-deploy-${DATE}"
VPS_WORKSPACE="/home/${VPS_USER}/${WORKSPACE_NAME}"
MAC_WT="$HOME/${WORKSPACE_NAME}"

QA_LOG=$(mktemp)
DR_LOG=$(mktemp)
OUTCOME="unknown"
teardown_all() {
    echo ""
    echo "[$(date -Iseconds)] Tearing down ..."
    vps_teardown "$VPS_WORKSPACE"
    git worktree remove --force "$MAC_WT" 2>/dev/null || rm -rf "$MAC_WT" 2>/dev/null
    rm -f "$QA_LOG" "$DR_LOG"
    echo "[$(date -Iseconds)] Outcome: ${OUTCOME}"
}
trap teardown_all EXIT

git worktree remove --force "$MAC_WT" 2>/dev/null || true
rm -rf "$MAC_WT"
git worktree add --detach "$MAC_WT" origin/main >/dev/null

echo "Syncing main @ ${MAIN_SHA} to VPS workspace ${VPS_WORKSPACE} ..."
vps_setup_workspace "$VPS_WORKSPACE" "$MAC_WT" || {
    OUTCOME="rsync_failed"
    exit 1
}
vps_write_validate_compose "$VPS_WORKSPACE" "$VALIDATE_PORT"

# ── build ──────────────────────────────────────────────────────────────────

echo ""
echo "[$(date -Iseconds)] Building current main on VPS ..."
if ! vps_build_stack "$VPS_WORKSPACE"; then
    OUTCOME="build_failed"
    BUILD_TAIL=$(vps_get_build_log)
    gh issue create \
        --title "Deploy-validate FAIL: build failed on main @ ${MAIN_SHA}" \
        --label deploy-validate \
        --body "**Stage failed:** image build on VPS

The current \`origin/main\` (${MAIN_SHA}) does not build cleanly in a fresh prod-equivalent environment.

\`\`\`
${BUILD_TAIL}
\`\`\`

🤖 Auto-opened by deploy-validate cron."
    exit 1
fi

# ── up + healthcheck ──────────────────────────────────────────────────────

echo ""
echo "[$(date -Iseconds)] Bringing up validate stack ..."
vps_up_stack "$VPS_WORKSPACE"

echo "[$(date -Iseconds)] Waiting for ${VALIDATE_URL}/api/health ..."
if ! vps_wait_healthy "${VALIDATE_URL}/api/health"; then
    OUTCOME="health_failed"
    HEALTH_LOGS=$(vps_collect_logs "$VPS_WORKSPACE")
    gh issue create \
        --title "Deploy-validate FAIL: stack unhealthy on main @ ${MAIN_SHA}" \
        --label deploy-validate \
        --body "**Stage failed:** \`/api/health\` did not respond within 90s

\`\`\`
${HEALTH_LOGS}
\`\`\`

🤖 Auto-opened by deploy-validate cron."
    exit 1
fi

# ── /qa-only ──────────────────────────────────────────────────────────────

QA_PROMPT="You are running daily deploy-validation /qa-only against the current \`origin/main\` (${MAIN_SHA}). Stack is running on the VPS at ${VALIDATE_URL}.

- Backend: real .env on VPS → live Supabase, live OAuth, live integrations
- Mode: REPORT ONLY. Do NOT modify code.

# READ-ONLY ON LIVE BACKEND
Navigate, read list+detail views, type into form fields (do NOT submit). NEVER submit forms that write data.

# OUTPUT (under 150 words)
- Verdict: PASS / FAIL
- # bugs found by severity
- Top 3 most concerning findings

Exit 0 if PASS. Exit non-zero if FAIL."

echo ""
echo "[$(date -Iseconds)] Invoking /qa-only ..."
claude --dangerously-skip-permissions -p "$QA_PROMPT" 2>&1 | tee "$QA_LOG"
# Parse verdict from output (claude CLI doesn't propagate agent verdicts as exit codes)
if grep -qiE 'verdict:[^a-z]*\*?\*?pass' "$QA_LOG"; then
    QA_EXIT=0
else
    QA_EXIT=1
fi

# ── /design-review (report mode) ──────────────────────────────────────────

DR_PROMPT="You are running deploy-validation /design-review against ${VALIDATE_URL} (current main @ ${MAIN_SHA}).

# REPORT-ONLY: DO NOT MODIFY/COMMIT/PUSH anything. Only identify visual issues.
# READ-ONLY backend: same as /qa.

VISUAL focus: spacing, hierarchy, alignment, broken layouts. Viewports: 375 / 768 / 1280 / 1920.

OUTPUT (under 150 words): Verdict (PASS/FAIL), # visual issues by severity, Top 3 issues. Exit 0 if PASS, non-zero if FAIL."

echo ""
echo "[$(date -Iseconds)] Invoking /design-review (report mode) ..."
claude --dangerously-skip-permissions -p "$DR_PROMPT" 2>&1 | tee "$DR_LOG"
if grep -qiE 'verdict:[^a-z]*\*?\*?pass' "$DR_LOG"; then
    DR_EXIT=0
else
    DR_EXIT=1
fi

# ── decide ────────────────────────────────────────────────────────────────

QA_TAIL=$(tail -60 "$QA_LOG")
DR_TAIL=$(tail -60 "$DR_LOG")

if [ "$QA_EXIT" -eq 0 ] && [ "$DR_EXIT" -eq 0 ]; then
    OUTCOME="all_green_no_action"
    echo ""
    echo "[$(date -Iseconds)] All gates green — current main looks deploy-ready."
else
    OUTCOME="issue_opened (qa=${QA_EXIT}, dr=${DR_EXIT})"
    [ "$QA_EXIT" -ne 0 ] && QA_VERDICT="❌ FAIL" || QA_VERDICT="✅ PASS"
    [ "$DR_EXIT" -ne 0 ] && DR_VERDICT="❌ FAIL" || DR_VERDICT="✅ PASS"
    gh issue create \
        --title "Deploy-validate FAIL: regressions on main @ ${MAIN_SHA}" \
        --label deploy-validate \
        --body "Current \`origin/main\` was built fresh on the VPS and validated.

| Stage | Result |
|---|---|
| VPS build | ✅ |
| \`/api/health\` | ✅ |
| /qa-only | ${QA_VERDICT} |
| /design-review (report) | ${DR_VERDICT} |

## /qa-only output
\`\`\`
${QA_TAIL}
\`\`\`

## /design-review output
\`\`\`
${DR_TAIL}
\`\`\`

🤖 Hybrid cron \`com.hausverwaltung.deploy-validate\`. Read-only (no auto-fixes)."
fi

exit 0
