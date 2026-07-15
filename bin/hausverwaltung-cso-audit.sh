#!/usr/bin/env zsh
# Hausverwaltung /cso security audit — local automated 2x/week run.
# Loaded by ~/Library/LaunchAgents/com.hausverwaltung.cso-audit.plist
# Fires Tue + Thu at 02:00 local time.
#
# What it does:
#   1. Sets PATH so claude/gh/pnpm/node are findable from launchd's minimal env
#   2. Refuses to run if ~/hausverwaltung has uncommitted changes (protects in-progress work)
#   3. Creates a fresh worktree at ~/hausverwaltung-security-audit-DATE
#   4. Runs `claude -p "/cso ..."` in non-interactive mode
#   5. Cleans up the worktree afterwards (the agent has already pushed any branch)

set -uo pipefail

# launchd starts with a minimal PATH — restore the user's real one
export PATH="/Users/dan/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"

# Generous timeouts — security audits + `pnpm vitest run` can run long.
# Defaults are 2min / 10min max; raise to 15min default / 60min max so
# long-running tools (vitest, gh pr create against a slow remote, etc.)
# don't get killed mid-run.
export BASH_DEFAULT_TIMEOUT_MS=900000   # 15 min
export BASH_MAX_TIMEOUT_MS=3600000      # 60 min

# Fail-fast on git/curl when the network is flaky — without these, git defaults
# wait ~10 min before timing out (fleet-wide failure pattern on 2026-05-27 at 01:13).
export GIT_HTTP_LOW_SPEED_LIMIT=1000
export GIT_HTTP_LOW_SPEED_TIME=30

REPO="$HOME/hausverwaltung"
DATE=$(date +%Y-%m-%d)
BRANCH="security/audit-$DATE"
WORKTREE_SLUG=$(echo "$BRANCH" | sed 's|/|-|g')
WORKTREE_PATH="$HOME/hausverwaltung-$WORKTREE_SLUG"

echo ""
echo "=========================================="
echo "  /cso audit run: $(date -Iseconds)"
echo "=========================================="

# Bail early if GitHub is unreachable (Mac asleep / no wifi / DNS down).
# Without this, git fetch hangs ~10 min before failing. With this, ~5s.
if ! curl -sf --max-time 5 https://api.github.com/zen > /dev/null; then
    echo "Skipped: github.com unreachable (likely no network at this hour)."
    echo "If this keeps happening, run: sudo pmset repeat wakeorpoweron MTWRFSU 00:50:00"
    exit 0
fi

if [ ! -d "$REPO/.git" ]; then
    echo "ERROR: $REPO is not a git repo" >&2
    exit 1
fi

cd "$REPO"

# Skip if main checkout is dirty — could be the user's in-progress work
if [ -n "$(git status --porcelain)" ]; then
    echo "Skipped: $REPO has uncommitted changes (won't touch your working tree)."
    git status --short
    exit 0
fi

# Refresh origin/main before branching off it
echo "Fetching origin/main ..."
git fetch origin main

# Clean up leftovers from a previous failed run (same-day re-attempt)
if [ -d "$WORKTREE_PATH" ]; then
    echo "Removing leftover worktree at $WORKTREE_PATH"
    git worktree remove --force "$WORKTREE_PATH" 2>/dev/null || true
    rm -rf "$WORKTREE_PATH"
fi
if git show-ref --verify --quiet "refs/heads/$BRANCH"; then
    echo "Deleting leftover local branch $BRANCH"
    git branch -D "$BRANCH" || true
fi

echo "Creating worktree on $BRANCH ..."
pnpm worktree:new "$BRANCH" || { echo "ERROR: worktree creation failed"; exit 1; }

cd "$WORKTREE_PATH"

PROMPT="/cso

Run in DAILY mode (8/10 confidence gate). You are in a fresh git worktree on branch $BRANCH at $WORKTREE_PATH — there is no need to create another branch.

After the audit:

If 8/10+ findings exist:
- Fix each with a minimal, root-cause-first change. When fixing one instance, grep for the same pattern elsewhere — fix all of them, not just the flagged line.
- Verify: \`pnpm vitest run\` and \`pnpm lint\` must pass before opening the PR.
- Commit per finding (or grouped by shared root cause). Clear messages.
- Push the branch.
- Open a PR via \`gh pr create\` titled 'security: automated audit fixes ($DATE)'. Body: one section per finding (severity, file:line, fix, why the fix is correct), a Verification section listing what you ran, and a footer 'Opened by local automated security cron (com.hausverwaltung.cso-audit) — needs human review before merge.'

If NO 8/10+ findings:
- Write a brief clean-run report to docs/security/audit-$DATE.md (what you checked, scope, any 7-or-below issues worth tracking).
- Commit on this branch, push, exit. No PR.

CRITICAL findings (active credential leak, RCE, auth bypass, RLS bypass): tag PR title with [URGENT] and include 'DO NOT MERGE WITHOUT IMMEDIATE REVIEW' in the body.

Safety rails (non-negotiable):
- Never use --no-verify on commits.
- Never force push.
- Never commit directly to main.
- Never delete files unless removal IS the fix and the file is genuinely dead code.
- Never commit secrets, even redacted, to the audit report.

End with one paragraph: branch name, PR URL (if any), finding count by severity, anything notable."

# --dangerously-skip-permissions is needed because the cron is unattended.
# The agent is fenced by the prompt's safety rails above.
claude --dangerously-skip-permissions -p "$PROMPT"
EXIT_CODE=$?

echo "Cleaning up worktree ..."
cd "$REPO"
pnpm worktree:rm "$BRANCH" --force 2>&1 || {
    echo "Warning: pnpm worktree:rm failed — falling back to git worktree remove"
    git worktree remove --force "$WORKTREE_PATH" 2>/dev/null || true
}

echo "Run complete: exit=$EXIT_CODE  finished=$(date -Iseconds)"
exit $EXIT_CODE
