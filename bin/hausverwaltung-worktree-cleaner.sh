#!/usr/bin/env zsh
# Worktree- & Branch-Cleaner — nightly (03:30) launchd run.
# Loaded by ~/Library/LaunchAgents/com.hausverwaltung.worktree-cleaner.plist
#
# WHAT IT DOES:
#   1. Scan all git worktrees of ~/hausverwaltung (except the main checkout):
#      - ACTIVE   (last commit <48h ago OR files edited <48h ago) → leave alone.
#      - MERGED   (proven IN CODE, see below — GitHub is not trusted) →
#                 remove the worktree, delete the local branch, delete the
#                 remote branch (only after re-proving the FRESH remote tip
#                 merged, and only when no OPEN PR would be closed by it).
#      - STALE + UNMERGED (idle ≥48h, changes not in main) → drive a headless
#                 claude session INSIDE that worktree: commit outstanding work,
#                 merge origin/main, run /ship, then /land-and-deploy to merge.
#                 The worktree is NOT removed the same night — the next run
#                 re-verifies the merge in code and removes it then.
#   2. Sweep branches that have no worktree: local + remote branches proven
#      merged are deleted (all remote deletions share ONE per-run cap; a branch
#      with an open PR is never deleted, locally or remotely).
#
# MERGE PROOF (code, not GitHub) — FAIL-CLOSED:
#   a) all commits contained in origin/main (rev-list empty), or
#   b) patch-id equivalent (git cherry) — only accepted when the branch has NO
#      merge commits beyond the merge-base (git cherry is blind to merge-commit
#      content, e.g. conflict resolutions), or
#   c) squash-merge proof: for every file the branch changed since its
#      merge-base (NUL-separated, quotepath-safe), main's content is
#      byte-identical to the branch's content.
#   Every git command's exit status is checked; an error anywhere → NOT merged.
#   The run aborts up front if `git fetch` fails or origin/main is unresolvable.
#   Anything ambiguous is KEPT and logged — this cleaner never guesses.
#
# SAFETY:
#   - never touches the main checkout, never runs `git checkout` anywhere
#   - never deletes `main`; never deletes a branch (local OR remote) with an
#     open PR; gh failure counts as "has an open PR" (conservative)
#   - remote deletion re-fetches the branch tip and re-proves THAT merged
#     (remote-only commits from another machine are never destroyed)
#   - never discards uncommitted work (ship path commits it; merged-but-dirty
#     worktrees are skipped for a human)
#   - NEVER touches ~/.claude/** (Claude session logs/memory are protected)
#   - caps: max 2 auto-ships; ONE shared cap of 30 remote branch deletions
#     per night (phase 1 + phase 2 combined); 50 local deletions
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

# FAIL-CLOSED PREFLIGHT: a broken fetch or unresolvable origin/main must abort
# the run — with a stale/missing origin/main every merge proof would misfire.
# --prune (all refs, not just main) so phase 2 never reasons over refs that
# were deleted server-side.
if ! git fetch origin --prune 2>&1 | tail -2; then
    echo "ERROR: git fetch origin --prune failed — aborting (fail-closed, nothing deleted)."
    exit 1
fi
if ! git rev-parse --verify --quiet origin/main >/dev/null; then
    echo "ERROR: origin/main unresolvable — aborting (fail-closed, nothing deleted)."
    exit 1
fi

# ONE gh call for the whole run: the open-PR head refs. gh failure → sentinel
# → has_open_pr answers "yes" for everything (conservative: nothing deleted).
OPEN_PR_HEADS=$(gh pr list --repo "$GH_REPO" --state open --limit 300 --json headRefName --jq '.[].headRefName' 2>/dev/null) \
    || OPEN_PR_HEADS="__GH_FAILED__"
has_open_pr() {
    local b=$1
    [ "$OPEN_PR_HEADS" = "__GH_FAILED__" ] && return 0
    print -r -- "$OPEN_PR_HEADS" | grep -qxF -- "$b"
}

# ── merge proof (code, not GitHub; every step fail-closed) ──────────────────
effectively_merged() {
    local ref=$1
    git rev-parse --verify --quiet "$ref" >/dev/null || return 1
    # a) all commits already contained in origin/main. rev-list error ≠ empty.
    local revs
    revs=$(git rev-list --max-count=1 "origin/main..$ref" 2>/dev/null) || return 1
    [ -z "$revs" ] && return 0
    # b) patch-id equivalence — ONLY when the branch carries no merge commits
    #    (git cherry cannot see merge-commit content, e.g. conflict resolutions)
    local merges
    merges=$(git rev-list --merges --max-count=1 "origin/main..$ref" 2>/dev/null) || return 1
    if [ -z "$merges" ]; then
        local cherry
        cherry=$(git cherry origin/main "$ref" 2>/dev/null) || return 1
        if [ -n "$cherry" ] && ! print -r -- "$cherry" | grep -q '^+'; then
            return 0
        fi
    fi
    # c) squash-merge proof: main matches the branch on every file it touched.
    #    NUL-separated + quotepath off so non-ASCII names can't void the pathspec.
    local mb
    mb=$(git merge-base origin/main "$ref" 2>/dev/null) || return 1
    [ -n "$mb" ] || return 1
    local diff_out
    diff_out=$(git -c core.quotepath=false diff --name-only -z "$mb" "$ref" 2>/dev/null) || return 1
    local -a files
    files=("${(@0)diff_out}")
    files=(${files:#})
    [ ${#files[@]} -eq 0 ] && return 0
    git -c core.quotepath=false diff --quiet "$ref" origin/main -- "${files[@]}" 2>/dev/null && return 0
    return 1
}

# Remote deletion gate: shared cap + re-fetch the branch tip + re-prove THAT
# ref merged, so remote-only commits are never destroyed on a stale local view.
REMOTE_DELETED=0
delete_remote_branch() {
    local b=$1
    git rev-parse --verify --quiet "refs/remotes/origin/$b" >/dev/null || return 1
    if has_open_pr "$b"; then echo "        remote KEPT ($b: open PR)"; return 1; fi
    if [ "$REMOTE_DELETED" -ge "$MAX_REMOTE_DELETES" ]; then
        echo "        remote KEPT ($b: nightly remote-delete cap ${MAX_REMOTE_DELETES} reached)"
        return 1
    fi
    if ! git fetch origin "+refs/heads/$b:refs/remotes/origin/$b" >/dev/null 2>&1; then
        echo "        remote KEPT ($b: could not re-fetch tip)"
        return 1
    fi
    if ! effectively_merged "refs/remotes/origin/$b"; then
        echo "        remote KEPT ($b: FRESH remote tip not proven merged — remote-only commits?)"
        return 1
    fi
    if git push origin --delete "$b" >/dev/null 2>&1; then
        REMOTE_DELETED=$((REMOTE_DELETED+1))
        echo "        remote branch $b deleted (${REMOTE_DELETED}/${MAX_REMOTE_DELETES})"
        return 0
    fi
    echo "        WARN: remote delete of $b failed"
    return 1
}

SHIPPED=0; REMOVED=0; NEEDS_HUMAN=0; SHIPS_STARTED=0

# ── phase 1: worktrees ──────────────────────────────────────────────────────
# sed keeps the full path (awk '$2' would truncate at the first space).
typeset -a WT_PATHS
WT_PATHS=(${(f)"$(git worktree list --porcelain | sed -n 's/^worktree //p')"})
NOW=$(date +%s)

for WT in "${WT_PATHS[@]}"; do
    [ "$WT" = "$REPO" ] && continue
    [ -d "$WT" ] || continue
    BRANCH=$(git -C "$WT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
    if [ -z "$BRANCH" ] || [ "$BRANCH" = "HEAD" ] || [ "$BRANCH" = "main" ]; then
        echo "SKIP    $WT (branch: '${BRANCH:-?}')"
        continue
    fi

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
        if has_open_pr "$BRANCH"; then
            echo "MERGED  $BRANCH — but an OPEN PR exists. Keeping worktree + branches (close the PR first)."
            continue
        fi
        echo "MERGED  $BRANCH — code-proof passed. Removing worktree + branches."
        if (cd "$REPO" && pnpm worktree:rm "$BRANCH" >/dev/null 2>&1) || git worktree remove "$WT" 2>/dev/null; then
            git branch -D "$BRANCH" >/dev/null 2>&1 || true
            delete_remote_branch "$BRANCH" || true
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
CHECKED_OUT=(${(f)"$(git worktree list --porcelain | sed -n 's|^branch refs/heads/||p')"})

is_checked_out() { local b=$1; for c in "${CHECKED_OUT[@]}"; do [ "$b" = "$c" ] && return 0; done; return 1; }

LOCAL_DELETED=0
for B in ${(f)"$(git for-each-ref refs/heads --format='%(refname:short)')"}; do
    [ "$B" = "main" ] && continue
    is_checked_out "$B" && continue
    has_open_pr "$B" && continue
    [ "$LOCAL_DELETED" -ge "$MAX_LOCAL_DELETES" ] && break
    if effectively_merged "$B"; then
        git branch -D "$B" >/dev/null 2>&1 && LOCAL_DELETED=$((LOCAL_DELETED+1)) && echo "LOCAL-DEL  $B (merged, no open PR)"
    fi
done

for RB in ${(f)"$(git for-each-ref refs/remotes/origin --format='%(refname:short)')"}; do
    B="${RB#origin/}"
    { [ "$B" = "main" ] || [ "$B" = "HEAD" ]; } && continue
    is_checked_out "$B" && continue
    [ "$REMOTE_DELETED" -ge "$MAX_REMOTE_DELETES" ] && { echo "Remote-delete cap ($MAX_REMOTE_DELETES) reached — rest next night."; break; }
    if effectively_merged "$RB" && ! has_open_pr "$B"; then
        delete_remote_branch "$B" >/dev/null && echo "REMOTE-DEL $B (merged, no open PR, fresh tip re-proven)"
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
