#!/usr/bin/env zsh
# Deterministic audit-PR finalizer.
#
# Called by the audit crons (agent-audit, coverage) AFTER `claude -p` returns and
# BEFORE the worktree is torn down. It GUARANTEES the two keystone steps that must
# not depend on the LLM remembering them:
#   1. a mergeable VERSION claim  → CI "Release guards" passes (VERSION strictly >
#      main, claim sites agree). Tries `pnpm release:reconcile` first (handles an
#      agent-made bump + parallel-version collisions); if that can't (no CHANGELOG
#      section), forces a minimal patch bump across VERSION/package.json/CHANGELOG.
#   2. auto-merge ARMED on the PR → a green PR self-merges within the hour instead
#      of rotting open (the failure that stranded #552/#562 for 10 days).
# It is idempotent: if the agent already did everything correctly, this is a no-op
# (reconcile noop, auto-merge already armed). If the agent committed work but never
# opened a PR, it opens one with --fill so the work isn't stranded.
#
# Usage: hausverwaltung-finalize-audit-pr.sh <worktree-path> <branch> [pr-label]

set -uo pipefail
export PATH="/Users/dan/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"

WT="${1:-}"
BR="${2:-}"
LABEL="${3:-}"
REPO="$HOME/hausverwaltung"
GUARDS="$REPO/scripts/ci/release-guards.mjs"

[ -n "$WT" ] && [ -n "$BR" ] || { echo "[finalize] usage: finalize-audit-pr.sh <worktree> <branch> [label]"; exit 2; }
[ -d "$WT/.git" ] || [ -f "$WT/.git" ] || { echo "[finalize] worktree $WT gone — nothing to finalize"; exit 0; }

cd "$WT" || { echo "[finalize] cannot cd $WT"; exit 0; }
git fetch origin main --quiet 2>/dev/null || true

AHEAD=$(git rev-list --count origin/main..HEAD 2>/dev/null || echo 0)
if [ "${AHEAD:-0}" -eq 0 ]; then
    echo "[finalize] branch has no commits ahead of origin/main — no PR to finalize"
    exit 0
fi

guards_pass() { node "$GUARDS" >/dev/null 2>&1; }

force_bump() {
    local mainV nextV today
    mainV=$(git show origin/main:VERSION 2>/dev/null | tr -d '[:space:]')
    [ -z "$mainV" ] && { echo "[finalize] cannot read origin/main:VERSION — skipping force bump"; return 1; }
    # next patch = main's version with a 4th segment +1 (pad to 4 segments first)
    nextV=$(echo "$mainV" | awk -F. '{ for(i=NF+1;i<=4;i++) $i=0; $4=$4+1; print $1"."$2"."$3"."$4 }')
    today=$(date +%Y-%m-%d)
    printf '%s\n' "$nextV" > VERSION
    perl -0pi -e 's/("version":\s*")[^"]+(")/${1}'"$nextV"'${2}/' package.json
    if ! grep -qE "^## \[$nextV\]" CHANGELOG.md; then
        perl -0pi -e 's/(\n## \[)/\n## ['"$nextV"'] - '"$today"'\n\n### Changed\n\n- chore(agents): automated audit version bump (deterministic finalizer).\n$1/' CHANGELOG.md
    fi
    echo "[finalize] forced version bump → $nextV"
}

# ── 1. guarantee a mergeable version claim ────────────────────────────────
if guards_pass; then
    echo "[finalize] release guards already green — no version work needed"
else
    echo "[finalize] release guards red — reconciling version claim"
    ( cd "$WT" && pnpm -s release:reconcile ) >/dev/null 2>&1 || true
    if ! guards_pass; then
        force_bump || true
    fi
    if [ -n "$(git status --porcelain)" ]; then
        git add -A
        git commit -q -m "chore(release): bump version to clear Release guards

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>" || true
    fi
    if guards_pass; then
        echo "[finalize] release guards now green"
    else
        echo "[finalize] WARNING: release guards still red after bump — PR will need a human"
    fi
fi

# ── 2. push ───────────────────────────────────────────────────────────────
git push -u origin "$BR" >/dev/null 2>&1 || git push >/dev/null 2>&1 || echo "[finalize] WARNING: push failed"

# ── 3. ensure a PR exists ─────────────────────────────────────────────────
PR=$(gh pr list --head "$BR" --state open --json number --jq '.[0].number // empty' 2>/dev/null)
if [ -z "$PR" ]; then
    echo "[finalize] no PR found for $BR — opening one with --fill so the work isn't stranded"
    if [ -n "$LABEL" ]; then
        PR=$(gh pr create --fill --label "$LABEL" 2>/dev/null | grep -oE '[0-9]+$' | tail -1)
    else
        PR=$(gh pr create --fill 2>/dev/null | grep -oE '[0-9]+$' | tail -1)
    fi
    echo "[finalize] opened PR #${PR:-?}"
fi

# ── 4. arm auto-merge ─────────────────────────────────────────────────────
if [ -n "$PR" ]; then
    if gh pr merge "$PR" --auto --squash >/dev/null 2>&1; then
        echo "[finalize] auto-merge armed on #$PR (it will merge itself once checks are green)"
    else
        # already armed, already merged, or branch-protection missing — report, don't fail
        STATE=$(gh pr view "$PR" --json state,autoMergeRequest --jq '.state + (if .autoMergeRequest then " (auto-merge already armed)" else " (auto-merge NOT armed — check branch protection)" end)' 2>/dev/null)
        echo "[finalize] auto-merge not newly armed on #$PR — $STATE"
    fi
else
    echo "[finalize] WARNING: could not resolve a PR number — nothing armed"
fi
echo "[finalize] done for $BR"
