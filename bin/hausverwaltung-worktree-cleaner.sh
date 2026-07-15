#!/usr/bin/env zsh
# Worktree- & Branch-Cleaner — nightly (03:30) launchd run.
# Loaded by ~/Library/LaunchAgents/com.hausverwaltung.worktree-cleaner.plist
#
# WHAT IT DOES:
#   1. Scan all git worktrees of ~/hausverwaltung (except the main checkout):
#      - ACTIVE   (last commit <48h ago OR files edited <48h ago) → leave alone.
#      - MERGED   (proven IN CODE, see below — GitHub is not trusted) →
#                 remove the worktree, delete the local branch, delete the
#                 remote branch (only when no OPEN PR would be closed by it).
#      - STALE + UNMERGED (idle ≥48h, changes not in main) → drive a headless
#                 claude session INSIDE that worktree: commit outstanding work,
#                 merge origin/main, run /ship, then /land-and-deploy to merge.
#                 The worktree is NOT removed the same night — the next run
#                 re-verifies the merge in code and removes it then.
#   2. Sweep branches that have no worktree: local + remote branches proven
#      merged are deleted (remote deletions capped per run; a branch with an
#      open PR is never deleted).
#
# MERGE PROOF (code, not GitHub):
#   a) all commits contained in origin/main (rev-list origin/main..ref empty), or
#   b) patch-id equivalent (git cherry — catches rebases/cherry-picks), or
#   c) squash-merge proof: for every file the branch changed since its
#      merge-base, main's content is byte-identical to the branch's content.
#   Anything ambiguous is KEPT and logged — this cleaner never guesses.
#
# SAFETY:
#   - never touches the main checkout, never runs `git checkout` anywhere
#   - never deletes `main`, never deletes a branch with an open PR
#   - never discards uncommitted work (ship path commits it; merged-but-dirty
#     worktrees are skipped for a human)
#   - NEVER touches ~/.claude/** (Claude session logs/memory are protected)
#   - caps: max 2 auto-ships + 30 remote branch deletions per night
#   - failures/needs-input → clickable macOS notification (opens a herdr pane
#     with a seeded claude session in the affected worktree)

set -uo pipefail

export PATH="/Users/dan/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
export BASH_DEFAULT_TIMEOUT_MS=900000
export BASH_MAX_TIMEOUT_MS=3600000
export GIT_HTTP_LOW_SPEED_LIMIT=1000
export GIT_HTTP_LOW_SPEED_TIME=30

REPO="$HOME/hausverwaltung"
GH_REPO="patzaa/Hausverwaltung"
NOTIFY="$HOME/.local/bin/hausverwaltung-notify.sh"
IDLE_HOURS=48
MAX_SHIPS=2
MAX_REMOTE_DELETES=30
MAX_LOCAL_DELETES=50

echo ""
echo "=========================================="
echo "  Worktree cleaner: $(date -Iseconds)"
echo "=========================================="

if ! curl -sf --max-time 5 https://api.github.com/zen > /dev/null; then
    echo "Skipped: github.com unreachable."
    exit 0
fi
[ -d "$REPO/.git" ] || { echo "ERROR: $REPO is not a git repo"; exit 1; }

cd "$REPO"
git fetch origin main --prune 2>&1 | tail -2

# ── merge proof (code, not GitHub) ──────────────────────────────────────────
effectively_merged() {
    local ref=$1
    git rev-parse --verify --quiet "$ref" >/dev/null || return 1
    # a) all commits already contained in origin/main
    [ -z "$(git rev-list --max-count=1 "origin/main..$ref" 2>/dev/null)" ] && return 0
    # b) patch-id equivalence (rebase / cherry-pick)
    if ! git cherry origin/main "$ref" 2>/dev/null | grep -q '^+'; then return 0; fi
    # c) squash-merge proof: main matches the branch on every file it touched
    local mb
    mb=$(git merge-base origin/main "$ref" 2>/dev/null) || return 1
    local -a files
    files=(${(f)"$(git diff --name-only "$mb" "$ref" 2>/dev/null)"})
    [ ${#files[@]} -eq 0 ] && return 0
    git diff --quiet "$ref" origin/main -- "${files[@]}" 2>/dev/null && return 0
    return 1
}

has_open_pr() {
    local branch=$1 n
    n=$(gh pr list --repo "$GH_REPO" --head "$branch" --state open --json number --jq 'length' 2>/dev/null)
    # on gh failure be conservative: pretend there IS an open PR
    [ -z "$n" ] && return 0
    [ "$n" != "0" ]
}

SHIPPED=0; REMOVED=0; NEEDS_HUMAN=0; SHIPS_STARTED=0

# ── phase 1: worktrees ──────────────────────────────────────────────────────
# name-only lines from `git worktree list --porcelain`: worktree <path>
typeset -a WT_PATHS
WT_PATHS=(${(f)"$(git worktree list --porcelain | awk '/^worktree /{print $2}')"})
NOW=$(date +%s)

for WT in "${WT_PATHS[@]}"; do
    [ "$WT" = "$REPO" ] && continue
    [ -d "$WT" ] || continue
    BRANCH=$(git -C "$WT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
    [ -z "$BRANCH" ] || [ "$BRANCH" = "HEAD" ] || [ "$BRANCH" = "main" ] && { echo "SKIP $WT (branch: '${BRANCH:-?}')"; continue; }

    LAST_COMMIT=$(git -C "$WT" log -1 --format=%ct 2>/dev/null || echo 0)
    COMMIT_AGE_H=$(( (NOW - LAST_COMMIT) / 3600 ))
    RECENT_EDIT=$(find "$WT" -type f \
        -not -path '*/node_modules/*' -not -path '*/.git/*' -not -path '*/.next/*' \
        -mtime -2 -print -quit 2>/dev/null)
    DIRTY=$(git -C "$WT" status --porcelain 2>/dev/null | head -1)

    if [ "$COMMIT_AGE_H" -lt "$IDLE_HOURS" ] || [ -n "$RECENT_EDIT" ]; then
        echo "ACTIVE  $BRANCH ($WT) — last commit ${COMMIT_AGE_H}h ago$([ -n "$RECENT_EDIT" ] && echo ', recent edits') — leaving alone."
        continue
    fi

    if effectively_merged "$BRANCH"; then
        if [ -n "$DIRTY" ]; then
            echo "MERGED-BUT-DIRTY  $BRANCH ($WT) — uncommitted changes on a merged branch, needs a human. Skipping."
            NEEDS_HUMAN=$((NEEDS_HUMAN+1))
            "$NOTIFY" "Worktree-Cleaner" "Merged, aber dirty" \
                "$BRANCH ist in main, hat aber uncommitted Änderungen — klicken zum Anschauen." \
                "$WT" \
                "Der Worktree-Cleaner hat festgestellt: Branch $BRANCH ist nachweislich in main gemerged, aber dieser Worktree ($WT) hat uncommitted Änderungen. Sichte sie: verwerfen (dann Worktree entfernen via 'pnpm worktree:rm $BRANCH' im Haupt-Checkout) oder als neuen Branch sichern." || true
            continue
        fi
        echo "MERGED  $BRANCH — code-proof passed. Removing worktree + branches."
        if (cd "$REPO" && pnpm worktree:rm "$BRANCH" >/dev/null 2>&1) || git worktree remove "$WT" 2>/dev/null; then
            git branch -D "$BRANCH" >/dev/null 2>&1 || true
            if git rev-parse --verify --quiet "origin/$BRANCH" >/dev/null && ! has_open_pr "$BRANCH"; then
                git push origin --delete "$BRANCH" >/dev/null 2>&1 \
                    && echo "        remote branch deleted" \
                    || echo "        WARN: remote delete failed"
            fi
            REMOVED=$((REMOVED+1))
        else
            echo "        WARN: worktree removal failed — skipping."
        fi
        continue
    fi

    # stale + unmerged → auto-ship (capped)
    if [ "$SHIPS_STARTED" -ge "$MAX_SHIPS" ]; then
        echo "STALE   $BRANCH — unmerged, but ship cap ($MAX_SHIPS) reached tonight. Next run."
        continue
    fi
    SHIPS_STARTED=$((SHIPS_STARTED+1))
    echo "STALE   $BRANCH ($WT) — idle ${COMMIT_AGE_H}h, unmerged. Driving ship+land via claude ..."
    SHIP_LOG=$(mktemp)
    SHIP_PROMPT="You are the nightly worktree-cleaner shipping a stale worktree. This worktree ($WT, branch $BRANCH) has been idle >48h and its changes are NOT merged into main.

TASK (work INSIDE this worktree only):
1. If there is uncommitted work, review it briefly and commit it with a sensible message. NEVER discard work.
2. git fetch origin && git merge origin/main. Resolve trivial conflicts; run 'pnpm release:reconcile' if the version claim is stale. If conflicts are non-trivial, STOP and report NEEDS_HUMAN with the conflict list.
3. Run /ship (tests, review, version bump, PR).
4. If ship's gates pass and the PR checks are green, run /land-and-deploy to merge and deploy.
5. Do NOT remove the worktree — the cleaner verifies the merge in code and removes it on its next run.

OUTPUT: the very LAST line of your output must be exactly one of:
  RESULT: MERGED <pr-url>
  RESULT: PR_OPEN <pr-url>
  RESULT: NEEDS_HUMAN <short reason>"
    (cd "$WT" && timeout 5400 claude --dangerously-skip-permissions -p "$SHIP_PROMPT" > "$SHIP_LOG" 2>&1)
    SHIP_EXIT=$?
    RESULT_LINE=$(grep -E '^RESULT:' "$SHIP_LOG" | tail -1)
    echo "        claude exit ${SHIP_EXIT}; ${RESULT_LINE:-no RESULT line}"
    tail -5 "$SHIP_LOG" | sed 's/^/        | /'
    case "$RESULT_LINE" in
        "RESULT: MERGED"*)  SHIPPED=$((SHIPPED+1)) ;;
        "RESULT: PR_OPEN"*) SHIPPED=$((SHIPPED+1)) ;;
        *)
            NEEDS_HUMAN=$((NEEDS_HUMAN+1))
            "$NOTIFY" "Worktree-Cleaner" "Auto-Ship braucht dich" \
                "$BRANCH: ship/land nicht durchgelaufen — klicken, um in die Session zu springen." \
                "$WT" \
                "Der nächtliche Worktree-Cleaner wollte den stale Branch $BRANCH (Worktree $WT) shippen (commit → merge origin/main → /ship → /land-and-deploy), ist aber nicht durchgekommen. Letzte Ausgabe: ${RESULT_LINE:-claude exit ${SHIP_EXIT}}. Lies ~/Library/Logs/hausverwaltung-worktree-cleaner.log, finde die Ursache und bring den Branch nach main (oder entscheide, dass er wegkann)." || true
            ;;
    esac
    rm -f "$SHIP_LOG"
done

# ── phase 2: branch sweep (no worktree attached) ────────────────────────────
typeset -a CHECKED_OUT
CHECKED_OUT=(${(f)"$(git worktree list --porcelain | awk '/^branch /{sub("refs/heads/","",$2); print $2}')"})

is_checked_out() { local b=$1; for c in "${CHECKED_OUT[@]}"; do [ "$b" = "$c" ] && return 0; done; return 1; }

LOCAL_DELETED=0
for B in ${(f)"$(git for-each-ref refs/heads --format='%(refname:short)')"}; do
    [ "$B" = "main" ] && continue
    is_checked_out "$B" && continue
    [ "$LOCAL_DELETED" -ge "$MAX_LOCAL_DELETES" ] && break
    if effectively_merged "$B"; then
        git branch -D "$B" >/dev/null 2>&1 && LOCAL_DELETED=$((LOCAL_DELETED+1)) && echo "LOCAL-DEL  $B (merged)"
    fi
done

REMOTE_DELETED=0
for RB in ${(f)"$(git for-each-ref refs/remotes/origin --format='%(refname:short)')"}; do
    B="${RB#origin/}"
    [ "$B" = "main" ] || [ "$B" = "HEAD" ] && continue
    is_checked_out "$B" && continue
    [ "$REMOTE_DELETED" -ge "$MAX_REMOTE_DELETES" ] && { echo "Remote-delete cap ($MAX_REMOTE_DELETES) reached — rest next night."; break; }
    if effectively_merged "$RB" && ! has_open_pr "$B"; then
        git push origin --delete "$B" >/dev/null 2>&1 \
            && REMOTE_DELETED=$((REMOTE_DELETED+1)) && echo "REMOTE-DEL $B (merged, no open PR)"
    fi
done

echo ""
echo "Summary: worktrees removed=${REMOVED}, auto-ships=${SHIPS_STARTED} (ok=${SHIPPED}), needs-human=${NEEDS_HUMAN}, local branches deleted=${LOCAL_DELETED}, remote branches deleted=${REMOTE_DELETED}"
if [ "$NEEDS_HUMAN" -eq 0 ] && [ $((SHIPS_STARTED + REMOVED + REMOTE_DELETED)) -gt 0 ]; then
    "$NOTIFY" "Worktree-Cleaner" "Nachtlauf fertig" \
        "Entfernt: ${REMOVED} Worktrees, ${REMOTE_DELETED} Remote-Branches. Auto-Ships: ${SHIPS_STARTED}." \
        "$REPO" \
        "Der nächtliche Worktree-Cleaner-Lauf ist durch (Log: ~/Library/Logs/hausverwaltung-worktree-cleaner.log). Zeig mir eine kurze Zusammenfassung: welche Worktrees/Branches entfernt wurden und wie die Auto-Ships ausgegangen sind." || true
fi
echo "Run complete: $(date -Iseconds)"
exit 0
