#!/usr/bin/env zsh
# OpenClaw upstream-pin upgrade-validate cron — daily 00:00 local.
# HYBRID model: Mac is the source of truth (worktree + bump commit), VPS does
# the prod-equivalent build, Mac runs /qa-only + /design-review (read-only).

set -uo pipefail

export PATH="/Users/dan/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
export BASH_DEFAULT_TIMEOUT_MS=900000
export BASH_MAX_TIMEOUT_MS=3600000

# Fail-fast on git/curl when the network is flaky — without these, git defaults
# wait ~10 min before timing out (burned 10 min on 2026-05-27 at 01:13).
export GIT_HTTP_LOW_SPEED_LIMIT=1000
export GIT_HTTP_LOW_SPEED_TIME=30

source /Users/dan/.local/lib/hausverwaltung-vps-validate.sh
source /Users/dan/.local/lib/hausverwaltung-openclaw-sentinels.sh

REPO="$HOME/hausverwaltung"
DATE=$(date +%Y-%m-%d)
VALIDATE_PORT=3001
VALIDATE_GW_PORT=18790   # tailnet host port for the validate openclaw gateway (≠ prod :18789), for the WS connect probe

vps_print_header "OpenClaw upgrade-validate"

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

# ── upstream check (cheap-idle path) ───────────────────────────────────────

git fetch origin main 2>&1 | grep -v "^$" | head -3
PINNED=$(git show origin/main:Dockerfile.openclaw 2>/dev/null \
    | grep -oE 'ghcr\.io/openclaw/openclaw:[^[:space:]]+' | head -1 | cut -d: -f2)
[ -z "$PINNED" ] && { echo "ERROR: could not read pin from origin/main"; exit 1; }
PINNED_BASE="${PINNED%-*}"

LATEST_RAW=$(gh release view --repo openclaw/openclaw --json tagName -q .tagName 2>/dev/null)
[ -z "$LATEST_RAW" ] && { echo "ERROR: gh release view failed"; exit 1; }
LATEST_NORM="${LATEST_RAW#v}"

if [ "$PINNED_BASE" = "$LATEST_NORM" ]; then
    echo "Up to date (pin: ${PINNED}, upstream: ${LATEST_RAW}). No-op."
    exit 0
fi
echo "Drift: ${PINNED} → ${LATEST_NORM} (upstream ${LATEST_RAW})"

# ── claude-availability preflight ──────────────────────────────────────────
# The pipeline burns ~30 min of local+VPS builds BEFORE the first claude-
# dependent gate. If claude (incl. the opus fallback) is limited RIGHT NOW,
# exit early instead — the next scheduled run retries. (Run 4, 2026-07-17:
# full build cycle wasted, QA aborted on 'hit your session limit'.)
CLAUDE_PING=$(mktemp)
if ! "$HOME/.local/bin/hausverwaltung-claude-run.sh" "$CLAUDE_PING" -p "Reply with exactly: OK" \
    || ! grep -q "OK" "$CLAUDE_PING"; then
    echo "Skipped: claude unavailable right now ($(tail -1 "$CLAUDE_PING" | cut -c1-80)) — retrying at the next scheduled run."
    rm -f "$CLAUDE_PING"
    exit 0
fi
rm -f "$CLAUDE_PING"
echo "✓ claude available (preflight ping ok)"

# ── pre-flight ─────────────────────────────────────────────────────────────

if ! vps_ping; then
    echo "ERROR: VPS unreachable (tailnet down? deploy user broken?)"
    exit 1
fi
echo "✓ VPS reachable"

BRANCH="openclaw-upgrade/${LATEST_NORM}"
EXISTING_PR=$(gh pr list --repo patzaa/Hausverwaltung --head "$BRANCH" --state open \
    --json url --jq '.[0].url // ""' 2>/dev/null)
if [ -n "$EXISTING_PR" ]; then
    echo "Skipped: PR already open at ${EXISTING_PR}"
    exit 0
fi

# Idempotency guard (mirrors the EXISTING_PR check): if an openclaw-upgrade issue
# for THIS version is already open, don't re-validate and don't open a duplicate.
# This is the source fix for the duplicate-issue pile-up (35 open before 2026-06-29):
# every failed run used to `gh issue create` the same-titled issue afresh.
# Match ONLY issues this agent's own failure paths create ("OpenClaw upgrade
# BLOCKED: …"). The daily version-check workflow files a TRACKING issue with
# the same label + version in the title ("OpenClaw upgrade available: …") —
# matching that one deadlocks the pipeline: tracking issue stays open until
# the upgrade lands, so validation would never run and the upgrade could
# never land (caught 2026-07-16: #760 suppressed the whole 2026.7.1 run
# including the release-notes review).
EXISTING_ISSUE=$(gh issue list --repo patzaa/Hausverwaltung --label openclaw-upgrade --state open \
    --search "\"OpenClaw upgrade BLOCKED\" ${LATEST_NORM} in:title" --json number,title \
    --jq "[.[] | select((.title | contains(\"${LATEST_NORM}\")) and (.title | startswith(\"OpenClaw upgrade BLOCKED\")))][0].number // empty" 2>/dev/null)
if [ -n "$EXISTING_ISSUE" ]; then
    echo "Skipped: a BLOCKED issue from a prior validation of ${LATEST_NORM} is still open (#${EXISTING_ISSUE}) — fix/close it, then re-run."
    exit 0
fi

# Resolve the actual tag (with or without -N suffix). Anonymous pull
# overrides any stored ghcr.io auth on VPS that may not include openclaw.
echo "Resolving image tag for ${LATEST_NORM} ..."
NEW_PIN=$(vps_find_image_tag "ghcr.io/openclaw/openclaw" "$LATEST_NORM")
if [ -z "$NEW_PIN" ]; then
    echo "ERROR: no pullable tag found for ${LATEST_NORM}"
    gh issue create \
        --title "OpenClaw upgrade BLOCKED: cannot resolve tag for ${LATEST_NORM}" \
        --label openclaw-upgrade \
        --body "Tried tags: \`${LATEST_NORM}\`, \`${LATEST_NORM}-1\`, \`${LATEST_NORM}-2\`, \`${LATEST_NORM}-3\` — none of them are pullable from \`ghcr.io/openclaw/openclaw\` on the VPS, even with anonymous auth. Inspect manually:

\`\`\`bash
ssh deploy@${VPS_HOST}
echo '{\"auths\":{}}' > /tmp/x.json
podman pull --authfile=/tmp/x.json ghcr.io/openclaw/openclaw:${LATEST_NORM}
\`\`\`"
    exit 1
fi
echo "✓ Tag resolved: ${NEW_PIN}"

# ── upstream-contract preflight ────────────────────────────────────────────
# Before building, check the deterministic breakage sentinels against the
# SOURCE of the version we're about to adopt (the openclaw reference checkout
# at the matching release tag). Surfaces protocol/RPC/CLI-flag drift up front —
# the exact "stack unhealthy" class that bit us repeatedly — so the PR/issue
# says WHY a bump might break instead of leaving the reviewer guessing.
OPENCLAW_REF="$HOME/openclaw"
PREFLIGHT_REPORT="_(preflight skipped — openclaw reference checkout unavailable)_"
PREFLIGHT_SUMMARY="(skipped)"
if [ -d "$OPENCLAW_REF/.git" ]; then
    git -C "$OPENCLAW_REF" fetch --tags --quiet origin 2>/dev/null || true
    PRE_REF=$(ocs_resolve_ref "$OPENCLAW_REF" "$LATEST_NORM" || echo "")
    if [ -n "$PRE_REF" ]; then
        run_openclaw_sentinels "$OPENCLAW_REF" "$REPO" "$PRE_REF" "${PRE_REF}"
        PREFLIGHT_REPORT="$OCS_REPORT"
        PREFLIGHT_SUMMARY="$OCS_SUMMARY"
        echo "Preflight: ${OCS_SUMMARY}"
        echo "$OCS_REPORT"
        if [ "$OCS_DRIFT" -eq 1 ]; then
            echo "⚠️  Contract drift at ${PRE_REF} — the PR/issue will flag it for the reviewer."
        fi
    else
        echo "Preflight: no git tag resolves for ${LATEST_NORM} — skipping sentinel preflight (non-fatal)."
        PREFLIGHT_REPORT="_(preflight skipped — no git tag resolved for \`${LATEST_NORM}\`)_"
    fi
fi

# ── upstream release-notes review (LLM gate) ────────────────────────────────
# The deterministic sentinels only assert contract points we KNOW about. The
# release notes catch the rest: auth-flow changes, gateway API/protocol changes,
# CLI-flag removals, Control-UI overhauls that would break our rebrand seds.
# claude reads them against our integration contract and answers SAFE or
# NEEDS_CHANGES. NEEDS_CHANGES → macOS notification (this cron runs 00:00, so
# it's waiting in Notification Center in the morning); the verdict is carried
# into the PR/issue body either way. Non-blocking: a claude infra failure or
# missing notes never stops the validate run.
RELNOTES_DIR="$HOME/.local/state/openclaw-validate"
mkdir -p "$RELNOTES_DIR"
RELNOTES_FILE="$RELNOTES_DIR/release-notes-${LATEST_NORM}.md"
RELNOTES_VERDICT="UNKNOWN"
RELNOTES_ASSESSMENT="_(release-notes review skipped — could not fetch notes for ${LATEST_RAW})_"
if gh release view "$LATEST_RAW" --repo openclaw/openclaw --json body -q .body > "$RELNOTES_FILE" 2>/dev/null \
   && [ -s "$RELNOTES_FILE" ]; then
    echo ""
    echo "[$(date -Iseconds)] Upstream release notes for ${LATEST_RAW} (first 80 lines; full: ${RELNOTES_FILE}):"
    head -80 "$RELNOTES_FILE"
    echo "…"

    RN_PROMPT="You are the OpenClaw upgrade release-notes reviewer for our Hausverwaltung platform. Upstream released ${LATEST_RAW}; we are pinned to ${PINNED}. Decide whether OUR code needs changes BEFORE this upgrade can be adopted.

# OUR INTEGRATION CONTRACT (what can break us)
1. Gateway WS protocol pinned at version 4 — src/lib/openclaw/gateway-client.ts, scripts/openclaw-debug.mjs, scripts/openclaw-dev.mjs (all in ${REPO}).
2. Container CMD override: openclaw gateway --allow-unconfigured --bind lan --port 18789.
3. Device pairing flow: operator.pairing scope + device.pair.approve RPC (pnpm openclaw approve).
4. Dockerfile.openclaw rebrand seds over /app/dist/control-ui — index.html + assets JS/CSS, the literal 'OpenClaw' brand string, the red hex palette (#ff4d4d/#ef4444/#dc2626/…).
5. Token auth: OPENCLAW_AUTH_TOKEN gateway token, OPENCLAW_HOOK_TOKEN webhooks.
6. Config/workspace layout: /openclaw/openclaw.json mount + per-agent workspaces.

# TASK
Read the release notes at ${RELNOTES_FILE} (you have shell + read access; cross-read ${REPO} if needed, but MODIFY NOTHING). Judge every contract point: does this release change auth, the gateway protocol/API, CLI flags, pairing, config layout, or the Control-UI build layout our rebrand patches?

# OUTPUT — STRICT
First line exactly one of:
  VERDICT: SAFE
  VERDICT: NEEDS_CHANGES
Then markdown: if NEEDS_CHANGES, one bullet per affected contract point (release-note item → what we must change, which file, effort S/M/L). If SAFE, 2-3 bullets on why. Under 250 words. No file modifications, no commits, no issues."
    RN_OUT=$(mktemp)
    "$HOME/.local/bin/hausverwaltung-claude-run.sh" "$RN_OUT" --dangerously-skip-permissions -p "$RN_PROMPT"
    RN_EXIT=$?
    if [ "$RN_EXIT" -eq 0 ] && head -1 "$RN_OUT" | grep -qE '^VERDICT:'; then
        # prefix match, not equality — the judge may decorate the verdict line
        # ("VERDICT: NEEDS_CHANGES — gateway v5"); CRs stripped.
        RELNOTES_VERDICT=$(head -1 "$RN_OUT" | tr -d '\r' | sed 's/^VERDICT:[[:space:]]*//')
        RELNOTES_ASSESSMENT=$(cat "$RN_OUT")
        echo ""
        echo "Release-notes review: VERDICT ${RELNOTES_VERDICT}"
        if print -r -- "$RELNOTES_VERDICT" | grep -q '^NEEDS_CHANGES'; then
            # Clickable: click opens a herdr pane with a seeded claude session
            # in ~/hausverwaltung to work the required changes.
            "$HOME/.local/bin/hausverwaltung-notify.sh" \
                "OpenClaw Upgrade" \
                "Release-Notes-Review: NEEDS_CHANGES" \
                "OpenClaw ${LATEST_NORM}: Upstream-Änderungen erfordern Anpassungen bei uns — klicken, um eine Claude-Session zu öffnen." \
                "$HOME/hausverwaltung" \
                "Der nächtliche OpenClaw upgrade-validate Release-Notes-Review hat NEEDS_CHANGES für ${LATEST_RAW} ergeben (wir sind auf ${PINNED} gepinnt). Lies den Abschnitt 'Release-notes review' in ~/Library/Logs/hausverwaltung-openclaw-upgrade-validate.log, die vollen Notes unter ${RELNOTES_FILE} und das neueste openclaw-upgrade Issue/PR. Plane dann die nötigen Anpassungen an unserem Integrations-Contract (Gateway-Protokoll-Pin, CMD-Flags, Pairing, Rebrand-Seds, Token-Auth, Config-Layout) und schlage sie mir vor." \
                || echo "WARN: notification failed"
        fi
    else
        RELNOTES_ASSESSMENT="_(release-notes review unavailable — claude exited ${RN_EXIT}; validate run proceeds without it)_"
        echo "WARN: release-notes review unavailable (claude exit ${RN_EXIT}) — proceeding. Tail:"
        tail -3 "$RN_OUT"
    fi
    rm -f "$RN_OUT"
else
    echo "WARN: could not fetch release notes for ${LATEST_RAW} — proceeding without review."
fi

# Pre-pull anonymously so the build's implicit pull uses the cache (avoids
# the same 403 on `podman compose build`).
echo "Pre-pulling image to VPS cache (anonymous) ..."
if ! vps_pre_pull_anonymous "ghcr.io/openclaw/openclaw:${NEW_PIN}" >/dev/null 2>&1; then
    echo "WARN: pre-pull failed; build will likely also fail"
fi

# ── Mac worktree + bump (Mac is source of truth) ──────────────────────────

WORKSPACE_NAME="hausverwaltung-validate-${BRANCH//\//-}"
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

echo "Creating Mac worktree at $MAC_WT ..."
git worktree remove --force "$MAC_WT" 2>/dev/null || true
git branch -D "$BRANCH" 2>/dev/null || true
rm -rf "$MAC_WT"
git worktree add -b "$BRANCH" "$MAC_WT" origin/main >/dev/null

cd "$MAC_WT"
sed -i.bak -E "s|ghcr\\.io/openclaw/openclaw:[^[:space:]]+|ghcr.io/openclaw/openclaw:${NEW_PIN}|" Dockerfile.openclaw
rm -f Dockerfile.openclaw.bak
git add Dockerfile.openclaw
git -c user.email="cron@hausverwaltung.local" -c user.name="OpenClaw upgrade cron" \
    commit -m "chore(openclaw): bump pin ${PINNED} → ${NEW_PIN}" >/dev/null

# Symlink env-files so the worktree's build context can read them where
# the rsync excludes won't carry them (we don't ship secrets to VPS).
ln -sf "$REPO/.env.local" .env.local 2>/dev/null || true

# ── LOCAL-FIRST GATE ───────────────────────────────────────────────────────
# Build + boot the bumped stack on the Mac (podman, arm64) and run /api/health
# + the WS connect probe BEFORE the expensive VPS round-trip. Fail fast locally;
# only a green local validate promotes to the VPS. Build context = the bumped
# worktree; the WS probe runs from $REPO (it has node_modules + the debug device,
# which the bare worktree lacks). We start the podman VM only if it's down and
# stop it only if WE started it (don't kill a dev container the operator left up).
source /Users/dan/.local/lib/hausverwaltung-validate-local.sh
echo ""
echo "[$(date -Iseconds)] Local validate gate (podman, arm64) ..."
LOCAL_VM_STARTED=0
if ! podman machine inspect --format '{{.State}}' 2>/dev/null | grep -q running; then
    podman machine start >/dev/null 2>&1 && LOCAL_VM_STARTED=1
fi
VL_PROBE_REPO="$REPO" validate_local "$MAC_WT" 3001 18790
LOCAL_RC=$?
[ "$LOCAL_VM_STARTED" -eq 1 ] && podman machine stop >/dev/null 2>&1
if [ "$LOCAL_RC" -ne 0 ]; then
    OUTCOME="local_validate_failed (stage=${VL_STAGE})"
    echo "❌ Local validate failed at ${VL_STAGE} — NOT promoting to the VPS."
    gh issue create \
        --title "OpenClaw upgrade BLOCKED: local validate failed for ${LATEST_NORM}" \
        --label openclaw-upgrade \
        --body "**From:** \`${PINNED}\`  **To:** \`${NEW_PIN}\`
**Stage failed:** LOCAL validate (Mac podman, arm64) — the VPS round-trip was skipped.
**Failed at:** \`${VL_STAGE}\`

### Upstream-contract preflight (${PREFLIGHT_SUMMARY})
${PREFLIGHT_REPORT}

### Local validate detail
\`\`\`
${VL_REPORT}
\`\`\`

🤖 Local-first gate of \`com.hausverwaltung.openclaw-upgrade-validate\` — local build/boot must pass before the VPS build."
    exit 1
fi
echo "✓ Local validate passed (${VL_STAGE}) — promoting to the VPS."

echo "Syncing worktree to VPS workspace at ${VPS_WORKSPACE} ..."
vps_setup_workspace "$VPS_WORKSPACE" "$MAC_WT" || {
    OUTCOME="rsync_failed"
    exit 1
}
vps_write_validate_compose "$VPS_WORKSPACE" "$VALIDATE_PORT" "$VALIDATE_GW_PORT"

# ── build (production-equivalent on VPS) ──────────────────────────────────

echo ""
echo "[$(date -Iseconds)] Building on VPS ..."
if ! vps_build_stack "$VPS_WORKSPACE"; then
    OUTCOME="build_failed"
    BUILD_TAIL=$(vps_get_build_log)
    gh issue create \
        --title "OpenClaw upgrade BLOCKED: build failed for ${LATEST_NORM}" \
        --label openclaw-upgrade \
        --body "**From:** \`${PINNED}\`
**To:** \`${NEW_PIN}\`
**Stage failed:** image build on VPS

\`\`\`
${BUILD_TAIL}
\`\`\`"
    exit 1
fi

# ── up + healthcheck (Mac → tailnet) ──────────────────────────────────────

echo ""
echo "[$(date -Iseconds)] Bringing up validate stack on VPS ..."
vps_up_stack "$VPS_WORKSPACE"

echo "[$(date -Iseconds)] Waiting for ${VALIDATE_URL}/api/health ..."
if ! vps_wait_healthy "${VALIDATE_URL}/api/health"; then
    OUTCOME="health_failed"
    HEALTH_LOGS=$(vps_collect_logs "$VPS_WORKSPACE")
    gh issue create \
        --title "OpenClaw upgrade BLOCKED: stack unhealthy on ${LATEST_NORM}" \
        --label openclaw-upgrade \
        --body "**From:** \`${PINNED}\`  **To:** \`${NEW_PIN}\`
**Stage failed:** \`/api/health\` did not respond within 90s

### Upstream-contract preflight (${PREFLIGHT_SUMMARY})
${PREFLIGHT_REPORT}

_(If a sentinel above shows 🔴 drift, that is the likely root cause — fix our hardcoded contract before retrying the bump.)_

### Container logs
\`\`\`
${HEALTH_LOGS}
\`\`\`"
    exit 1
fi

# ── WS connect round-trip (protocol negotiation) ──────────────────────────
# /api/health only does an HTTP /healthz probe — it does NOT exercise a real
# protocol-negotiated gateway connect, so a PROTOCOL_VERSION bump in the new
# image slips past it (the documented "boot-smoke is necessary but not
# sufficient" trap). Here we connect with OUR canonical client (scripts/
# openclaw-debug.mjs, pinned minProtocol/maxProtocol=4) from the main checkout
# against the freshly-built validate gateway, published at ${VPS_HOST}:${VALIDATE_GW_PORT}.
# A fresh validate gateway won't know our debug device, so a pairing/auth reply
# is EXPECTED and fine — we only fail on an explicit PROTOCOL_MISMATCH.
echo ""
echo "[$(date -Iseconds)] Probing real WS connect against validate gateway (ws://${VPS_HOST}:${VALIDATE_GW_PORT}) ..."
PROBE_OUT=$( cd "$REPO" && OPENCLAW_DEBUG_GATEWAY_URL="ws://${VPS_HOST}:${VALIDATE_GW_PORT}" \
    timeout 60 pnpm -s debug:openclaw sessions 2>&1 )
echo "$PROBE_OUT" | tail -8
if echo "$PROBE_OUT" | grep -qiE 'protocol[_ ]?mismatch|unsupported protocol|minProtocol|maxProtocol'; then
    OUTCOME="ws_protocol_mismatch"
    PROBE_TAIL=$(echo "$PROBE_OUT" | tail -25)
    gh issue create \
        --title "OpenClaw upgrade BLOCKED: WS PROTOCOL_MISMATCH on ${LATEST_NORM}" \
        --label openclaw-upgrade \
        --body "**From:** \`${PINNED}\`  **To:** \`${NEW_PIN}\`
**Stage failed:** real WS connect round-trip — the new gateway rejected our protocol-4 connect frame.

The new image bumped \`PROTOCOL_VERSION\`. Update \`minProtocol/maxProtocol\` in \`src/lib/openclaw/gateway-client.ts\`, \`scripts/openclaw-debug.mjs\`, \`scripts/openclaw-dev.mjs\` to match, then re-run. (This is the exact failure \`/api/health\` + image-boot smoke do NOT catch.)

### Upstream-contract preflight (${PREFLIGHT_SUMMARY})
${PREFLIGHT_REPORT}

### Probe output
\`\`\`
${PROBE_TAIL}
\`\`\`"
    exit 1
elif echo "$PROBE_OUT" | grep -qiE 'ECONNREFUSED|ETIMEDOUT|getaddrinfo|connection refused|timed out|timeout'; then
    echo "⚠️  WS probe inconclusive (could not reach ${VPS_HOST}:${VALIDATE_GW_PORT} — port publish/tailnet issue). Not blocking; /qa still exercises chat."
else
    echo "✓ WS connect negotiated protocol OK (pairing/auth reply is expected for a fresh validate gateway)."
fi

# ── auto-pair Next.js ↔ gateway so /qa can actually test chat ──────────────
# The validate stack boots UNPAIRED; without this, /api/chat/history 502s and
# /qa reads it as an image regression (the spurious #383). Approve the pending
# gateway-client device, then give Next.js one reconnect cycle to come up paired.
echo ""
echo "[$(date -Iseconds)] Auto-pairing validate Next.js with the gateway ..."
# The pairing routine needs an authenticated cookie to TRIGGER Next.js's lazy
# gateway connect (curl /api/chat/sessions) — the QA demo user, same one the
# gates log in as. auth:cookie does a fresh Supabase login and prints the
# sb-… Cookie header; it targets the same Supabase project the validate stack
# uses, so the cookie is valid against VALIDATE_URL:3001.
PAIR_COOKIE=$(cd "$REPO" && pnpm -s auth:cookie 2>/dev/null)
PAIR_OK=0
if [ -z "$PAIR_COOKIE" ]; then
    echo "WARN: could not mint QA auth cookie (auth:cookie failed) — pairing can't trigger Next.js; /qa chat may be NOT_PAIRED."
elif vps_pair_validate_nextjs "$VALIDATE_GW_PORT" "$VALIDATE_URL" "$PAIR_COOKIE"; then
    PAIR_OK=1
    echo "✓ pairing verified end-to-end — Next.js chat surface is live."
else
    echo "WARN: auto-pair did not verify — /qa chat results may reflect pairing, not the image."
fi

# ── /qa-only ──────────────────────────────────────────────────────────────

QA_PROMPT="You are running OpenClaw-upgrade /qa-only verification. The container stack is built and running on the VPS with the **new** OpenClaw pin (\`${NEW_PIN}\`, was \`${PINNED}\`).

- Validate stack URL: ${VALIDATE_URL}
- Backend: real .env on VPS → live Supabase, live OAuth, live integrations
- Auth: use the dedicated QA demo user (claude-qa@houseclaw.local, admin — auditably separate from Dan's login). It lives in the SAME Supabase project the validate stack talks to, so it works against ${VALIDATE_URL}: for curl probes use \`curl -H \"Cookie: \$(pnpm -s auth:cookie)\" ${VALIDATE_URL}/...\`; in a browser, log in at ${VALIDATE_URL}/login with LOCAL_QA_AUTH_EMAIL/LOCAL_QA_AUTH_PASSWORD from .env.local. See CLAUDE.md 'Local auth for agent probes'. Test the logged-in dashboard surfaces, not just public pages.
- Mode: REPORT ONLY. Do NOT modify any code in the local repo.

# YOUR TASK
Invoke /qa-only against ${VALIDATE_URL}. Read-only verification: confirm the new OpenClaw image works with our app. NEVER modify code, never commit, never push, never open a PR.

# READ-ONLY ON LIVE BACKEND
ALLOWED: Navigate routes, read list+detail views, type into form fields (do NOT submit).
FORBIDDEN: Submit forms that send messages, write to DB, trigger OAuth flows. The Supabase the validate stack talks to is REAL PROD DB.

# WHAT COUNTS AS A FAIL
- HTTP 500 / error boundary on any page
- Console errors clearly tied to OpenClaw protocol changes
- /api/openclaw/* or chat/webchat routes returning 500
- WebSocket disconnects in chat/agent surface

# OUTPUT (under 150 words)
- Verdict: PASS / FAIL
- # bugs found by severity
- Top 3 most concerning findings

Exit 0 if PASS (no critical/high bugs). Exit non-zero if FAIL."

echo ""
echo "[$(date -Iseconds)] Invoking /qa-only ..."
"$HOME/.local/bin/hausverwaltung-claude-run.sh" "$QA_LOG" --dangerously-skip-permissions -p "$QA_PROMPT"
cat "$QA_LOG"

# Distinguish a claude INFRA failure (out of credits, rate-limit, auth, network)
# from a real QA verdict. An infra failure is NOT a product regression, so abort
# the run cleanly rather than opening a misleading "validate gates failed" issue
# (the false-positive #385 came from "Credit balance is too low" being read as FAIL).
CLAUDE_INFRA_RE='session limit|hit your [a-z]* limit|credit balance is too low|insufficient.*credit|invalid x?-?api[ -]?key|authentication_error|overloaded_error|rate.?limit|usage limit|api error|connection error|fetch failed|ECONNREFUSED|ETIMEDOUT'
if grep -qiE "$CLAUDE_INFRA_RE" "$QA_LOG"; then
    REASON=$(grep -oiE "$CLAUDE_INFRA_RE" "$QA_LOG" | head -1)
    OUTCOME="aborted: QA harness (claude) unavailable — ${REASON}"
    echo ""
    echo "❌ /qa could not run — claude unavailable (${REASON}). Aborting WITHOUT a product verdict — this is NOT a regression; no BLOCKED issue opened."
    exit 1
fi

# Claude CLI always exits 0 unless infra failure; parse verdict from output.
# Look for "Verdict: PASS" (case-insensitive). Anything else (or absence) = FAIL.
if grep -qiE 'verdict:[^a-z]*\*?\*?pass' "$QA_LOG"; then
    QA_EXIT=0
else
    QA_EXIT=1
fi

# ── /design-review (report-mode override) ─────────────────────────────────

DR_PROMPT="You are running OpenClaw-upgrade /design-review against ${VALIDATE_URL} (validate stack built with new OpenClaw \`${NEW_PIN}\`).

# CRITICAL: REPORT-ONLY MODE
The /design-review skill defaults to auto-fix. OVERRIDE THIS:
- DO NOT MODIFY any source code
- DO NOT COMMIT any changes
- DO NOT PUSH anything
- DO NOT OPEN any PR
- ONLY: navigate, take screenshots, identify visual issues, write a report

If you accidentally edit a file, immediately revert with git restore.

# READ-ONLY ON LIVE BACKEND
Same rules as /qa: live Supabase, live OAuth, no form submits that write data.
Auth: log in as the QA demo user (LOCAL_QA_AUTH_EMAIL/LOCAL_QA_AUTH_PASSWORD from .env.local, or \`pnpm -s auth:cookie\` for header-based probes) so the DASHBOARD surfaces get reviewed, not just the login page.

# VISUAL FOCUS
Spacing, hierarchy, alignment, AI-slop patterns, broken layouts, OpenClaw-rendered UI surface (chat panel, approvals, agent dashboard). Test viewports: 375 / 768 / 1280 / 1920.

# OUTPUT (under 150 words)
- Verdict: PASS / FAIL
- # visual issues by severity
- Top 3 most concerning visual issues

Exit 0 if PASS. Exit non-zero if FAIL."

echo ""
echo "[$(date -Iseconds)] Invoking /design-review (report mode) ..."
"$HOME/.local/bin/hausverwaltung-claude-run.sh" "$DR_LOG" --dangerously-skip-permissions -p "$DR_PROMPT"
cat "$DR_LOG"
if grep -qiE "$CLAUDE_INFRA_RE" "$DR_LOG"; then
    REASON=$(grep -oiE "$CLAUDE_INFRA_RE" "$DR_LOG" | head -1)
    OUTCOME="aborted: design-review harness (claude) unavailable — ${REASON}"
    echo ""
    echo "❌ /design-review could not run — claude unavailable (${REASON}). Aborting WITHOUT a verdict; no BLOCKED issue opened."
    exit 1
fi
if grep -qiE 'verdict:[^a-z]*\*?\*?pass' "$DR_LOG"; then
    DR_EXIT=0
else
    DR_EXIT=1
fi

# ── decide: PR or issue ───────────────────────────────────────────────────

QA_TAIL=$(tail -60 "$QA_LOG")
DR_TAIL=$(tail -60 "$DR_LOG")

# NOT_PAIRED signature guard: if the gates failed but the failure is our own
# unpaired chat surface (not an image defect), abort WITHOUT a BLOCKED issue —
# an open "OpenClaw upgrade BLOCKED" issue also deadlocks the next run via the
# idempotency guard. Only trips when pairing did NOT verify (PAIR_OK=0), so a
# genuine post-pairing NOT_PAIRED regression would still surface. QA itself
# says "not an upgrade regression" in exactly this case (runs 3+5).
GATES_FAILED=0
{ [ "$QA_EXIT" -ne 0 ] || [ "$DR_EXIT" -ne 0 ]; } && GATES_FAILED=1
GATES_BOTH="$(printf '%s\n%s' "$QA_TAIL" "$DR_TAIL")"
# (a) unpaired chat surface — only when pairing itself didn't verify, so a
#     genuine post-pairing regression still surfaces.
ENV_DEFECT=""
if [ "$GATES_FAILED" -eq 1 ] && [ "$PAIR_OK" -ne 1 ] \
   && printf '%s' "$GATES_BOTH" | grep -qiE 'NOT_PAIRED|PAIRING_REQUIRED'; then
    ENV_DEFECT="chat surface NOT_PAIRED (harness pairing)"
fi
# (b) EACCES on the openclaw workspace — a bind-mount perms gap the prod deploy
#     fixes (chown 1000 + chmod), so it can NEVER be an image regression.
#     Unconditional (fires even with pairing verified). Found 2026-07-17.
if [ "$GATES_FAILED" -eq 1 ] \
   && printf '%s' "$GATES_BOTH" | grep -qiE 'EACCES.*openclaw|openclaw-workspace-state|permission denied.*openclaw'; then
    ENV_DEFECT="EACCES on the openclaw workspace (harness bind-mount perms)"
fi
if [ -n "$ENV_DEFECT" ]; then
    OUTCOME="aborted: ${ENV_DEFECT}, not the image"
    echo ""
    echo "❌ Gates failed on a HARNESS defect (${ENV_DEFECT}), not a ${LATEST_NORM} regression. Aborting WITHOUT a BLOCKED issue (would deadlock the next run). Fix + re-run."
    exit 1
fi

if [ "$QA_EXIT" -eq 0 ] && [ "$DR_EXIT" -eq 0 ]; then
    echo ""
    echo "[$(date -Iseconds)] Both gates green — pushing branch + opening PR"
    OUTCOME="opening_pr"
    cd "$MAC_WT"
    git push -u origin "$BRANCH" 2>&1 | tail -3

    PR_URL=$(gh pr create \
        --base main \
        --head "$BRANCH" \
        --title "chore(openclaw): bump to ${LATEST_NORM} (VPS-validated)" \
        --label openclaw-upgrade \
        --body "## Summary
Hybrid validate-cron run. All gates green.

| Stage | Result |
|---|---|
| VPS build (prod-equivalent x86_64) | ✅ |
| \`/api/health\` | ✅ |
| /qa-only (read-only functional) | ✅ |
| /design-review (read-only visual) | ✅ |

| | |
|---|---|
| Old pin | \`${PINNED}\` |
| New pin | \`${NEW_PIN}\` |
| Upstream tag | [\`${LATEST_RAW}\`](https://github.com/openclaw/openclaw/releases/tag/${LATEST_RAW}) |

## Upstream-contract preflight (${PREFLIGHT_SUMMARY})
${PREFLIGHT_REPORT}

## Release-notes review (${RELNOTES_VERDICT})
${RELNOTES_ASSESSMENT}

## /qa-only output
\`\`\`
${QA_TAIL}
\`\`\`

## /design-review (report) output
\`\`\`
${DR_TAIL}
\`\`\`

🤖 Hybrid cron \`com.hausverwaltung.openclaw-upgrade-validate\` — Mac orchestrates, VPS builds, Mac validates against tailnet stack. **Needs human review.**" 2>&1 | tail -1)

    OUTCOME="pr_opened: ${PR_URL}"
    echo "PR: ${PR_URL}"
else
    echo ""
    echo "[$(date -Iseconds)] One or both gates failed — opening issue"
    OUTCOME="issue_opened (qa=${QA_EXIT}, dr=${DR_EXIT})"
    [ "$QA_EXIT" -ne 0 ] && QA_VERDICT="❌ FAIL" || QA_VERDICT="✅ PASS"
    [ "$DR_EXIT" -ne 0 ] && DR_VERDICT="❌ FAIL" || DR_VERDICT="✅ PASS"
    gh issue create \
        --title "OpenClaw upgrade BLOCKED: validate gates failed for ${LATEST_NORM}" \
        --label openclaw-upgrade \
        --body "**From:** \`${PINNED}\`  **To:** \`${NEW_PIN}\`

| Stage | Result |
|---|---|
| VPS build | ✅ |
| \`/api/health\` | ✅ |
| /qa-only | ${QA_VERDICT} |
| /design-review (report) | ${DR_VERDICT} |

## Release-notes review (${RELNOTES_VERDICT})
${RELNOTES_ASSESSMENT}

## /qa-only output
\`\`\`
${QA_TAIL}
\`\`\`

## /design-review output
\`\`\`
${DR_TAIL}
\`\`\`

🤖 Hybrid cron — read-only validation found issues. No PR opened."
fi

# ── self-improvement reflection (after every run) ──────────────────────────
# Reflect on THIS run and improve the HARNESS itself. PROPOSES (does not auto-
# apply — the validate harness gates prod upgrades, so changes get human review):
# false positives/negatives, flaky/slow stages, mis-attributed failures, races,
# noisy output, coverage gaps. Writes a dated entry to a learnings log and opens
# ONE gated `harness-improvement` issue only when it finds something actionable.
SELFIMPROVE_LOG="$HOME/.local/state/openclaw-validate/harness-learnings.md"
mkdir -p "$(dirname "$SELFIMPROVE_LOG")"
gh label create harness-improvement --repo patzaa/Hausverwaltung \
    --description "Self-proposed improvements to the validate harness" --color C5DEF5 >/dev/null 2>&1 || true
SI_PROMPT="You are the post-run self-improvement reflector for the OpenClaw upgrade-validate harness. A run just finished — improve the HARNESS, not the product.

# THIS RUN
- Outcome: ${OUTCOME}
- From pin \`${PINNED}\` → \`${NEW_PIN}\` (upstream ${LATEST_RAW})
- Full run log (tail it): ~/Library/Logs/hausverwaltung-openclaw-upgrade-validate.log

# THE HARNESS (read to reason about fixes; do NOT edit)
~/.local/bin/hausverwaltung-openclaw-upgrade-validate.sh
~/.local/lib/hausverwaltung-vps-validate.sh
~/.local/lib/hausverwaltung-openclaw-sentinels.sh
~/.local/lib/hausverwaltung-validate-local.sh
~/.local/lib/openclaw-approve.cjs

# TASK (read-only — PROPOSE, never edit/commit/touch product code)
Tail the run log. Find concrete improvements to the HARNESS ITSELF revealed by THIS run: false positives/negatives, flaky or slow stages, mis-attributed failures, timing/races, missing teardown, noisy output, coverage gaps. For each: what in this run revealed it + the specific change to which file.
- Append a dated section to ${SELFIMPROVE_LOG} (create if missing).
- If ≥1 HIGH-value, concrete, not-already-tracked harness fix exists, open ONE issue (repo patzaa/Hausverwaltung, label harness-improvement, title 'Harness self-improvement (${DATE})') with the findings. Otherwise append 'clean run — no harness changes proposed' and open nothing.
Output under 120 words: what you logged + issue URL (if any)."
echo ""
echo "[$(date -Iseconds)] Self-improvement reflection ..."
SI_OUT=$(mktemp)
"$HOME/.local/bin/hausverwaltung-claude-run.sh" "$SI_OUT" --dangerously-skip-permissions -p "$SI_PROMPT" \
    || echo "(self-improve reflection skipped — claude error)"
tail -10 "$SI_OUT"; rm -f "$SI_OUT"

# trap fires teardown
exit 0
