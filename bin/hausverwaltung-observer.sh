#!/usr/bin/env zsh
# Hausverwaltung Observer — the launchd fleet's own watchdog.
# Loaded by ~/Library/LaunchAgents/com.hausverwaltung.observer.plist
# Fires Wednesday 03:00 local (2h after the Wed 01:00 audit crons, so their
# freshest run is on record when the Observer reads it).
#
# WHY THIS EXISTS. On 2026-07-15, answering "does the audit cron even work?"
# surfaced that it had SKIPPED every run since 12.07. — one untracked file
# (`?? .claude/launch.json`) tripped its dirty-tree guard, and because a skip
# exits 0, every monitor read it as healthy. It sat dead for THREE runs unseen.
# The same scan found `openclaw-ui-watch` erroring (claude exit 1) for two days,
# also unnoticed. The lesson: the fleet had no one watching the watchers. This is
# that watcher.
#
# WHAT IT DOES (deterministic by design — a monitor that itself breaks is worse
# than none, so NO claude call, no repo worktree, no network dependency for the
# core checks):
#   1. HEALTH — auto-discovers every `com.hausverwaltung.*` agent and classifies
#      each: HEALTHY / TRANSIENT-SKIP / BLOCKED / FAILING / STALE / DEAD. The
#      hard part is that a silent skip exits 0, so LastExitStatus is not enough —
#      it reads the log tail and classifies the skip REASON (network=transient,
#      dirty-tree/missing-dep=blocking).
#   2. LOG HYGIENE (frees disk) — any log over CAP is trimmed to its last KEEP
#      lines; the head is gzip-archived (concatenated-gzip, read with `gunzip -c`
#      / `gzcat` — NOT macOS `zcat`, which wants a `.Z`), and
#      archives older than RETENTION_DAYS are deleted. Reports bytes freed.
#   3. SOLVE vs ESCALATE — it SOLVES the safe class itself (log bloat; a job whose
#      plist exists but isn't loaded → `launchctl bootstrap`). It does NOT touch
#      another agent's script, plist, or the repo working tree — those are
#      ESCALATED loud (pinned GitHub issue + macOS notification) so a real
#      blocker can never again rot unnoticed for days. That boundary is the whole
#      safety model: the Observer observes and tidies; it does not rewrite the
#      fleet.
#
# Output: refreshes ONE pinned issue "🔭 Observer — launchd fleet health"
# (find-or-create-edit, one living doc) + a macOS notification on any
# BLOCKED/FAILING/DEAD + this log. Set OBSERVER_DRY_RUN=1 to compute + print
# WITHOUT trimming, loading, notifying, or touching GitHub.

set -uo pipefail

export PATH="/Users/dan/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

LOG="$HOME/Library/Logs/hausverwaltung-observer.log"
LA_DIR="$HOME/Library/LaunchAgents"
LOG_DIR="$HOME/Library/Logs"
PINNED_TITLE="🔭 Observer — launchd fleet health"
REPO="$HOME/hausverwaltung"

# Log-hygiene knobs.
CAP_BYTES=$((512 * 1024))   # trim a log once it passes 512 KB …
KEEP_LINES=2000             # … down to its last 2000 lines (recent history stays)
RETENTION_DAYS=90           # delete gzip archives older than this
DRY_RUN="${OBSERVER_DRY_RUN:-0}"

NOW_EPOCH=$(date +%s)
BODY_FILE="$(mktemp -t observer-body)"
trap 'rm -f "$BODY_FILE"' EXIT

echo ""
echo "=========================================="
echo "  Observer run: $(date -Iseconds)${DRY_RUN:+  (dry-run=$DRY_RUN)}"
echo "=========================================="

# ── expected cadence per agent, for the STALE check (max days between runs
#    before we worry). Auto-discovery covers membership; this is only the
#    "should have run by now" threshold. Unknown agents default to 8 days.
cadence_days() {
  case "$1" in
    *agent-script-audit) echo 3 ;;   # Mon/Wed/Fri/Sun
    *coverage-audit)     echo 4 ;;   # Sun/Wed
    *audit-health)       echo 8 ;;   # Mon
    *observer)           echo 8 ;;   # Wed (self)
    *cso-audit)          echo 8 ;;
    *deploy-validate)    echo 2 ;;   # frequent
    *openclaw-ui-watch)  echo 2 ;;
    *openclaw-upgrade-validate) echo 2 ;;  # daily
    *) echo 8 ;;
  esac
}

# A skip whose REASON is transient (no network at 01–03:00, an upgrade issue
# already open) is benign and self-clears. A skip on a dirty tree / missing dep /
# not-a-repo is a persistent BLOCK that recurs every run until a human acts.
skip_is_blocking() {
  print -r -- "$1" | grep -qiE "uncommitted|dirty|not a git|no such|command not found|missing|permission denied|cannot"
}

# One concrete next step per symptom — this is the "was der fix wäre" the
# notification carries, so the human knows the move before even clicking.
fix_hint() {
  local s="$1"
  case "$s" in
    *"claude exited"*|*"infra failure"*|*rror*[Cc]laude*) echo "Anthropic-Guthaben/Key + Gateway prüfen; Agent manuell laufen lassen für die verschluckte Fehlermeldung" ;;
    *uncommitted*|*dirty*)          echo "Haupt-Checkout aufräumen: die untrackten/geänderten Dateien committen oder ignorieren" ;;
    *"not loaded"*)                 echo "launchctl bootstrap gui/\$(id -u) <plist> — der Observer versucht das selbst" ;;
    *"no run in"*)                  echo "plist-Zeitplan prüfen; lief der Mac zur geplanten Zeit? (verpasste Jobs laufen erst beim Aufwachen)" ;;
    *unreachable*|*network*)        echo "transient (kein Netz zur Cron-Zeit) — klärt sich beim nächsten Lauf von selbst" ;;
    *"command not found"*|*missing*) echo "fehlendes Binary im PATH des Wrappers — installieren oder PATH-Zeile ergänzen" ;;
    *)                              echo "Log-Tail lesen und den letzten fehlgeschlagenen Schritt diagnostizieren" ;;
  esac
}

# ── classify one agent from its launchctl state + log tail ────────────────────
declare -a HEALTHY BLOCKED FAILING STALE DEADJ TRANSIENT RECOVERING
classify() {
  local label="$1"
  # Self: the Observer is running RIGHT NOW by definition — it must not classify
  # itself from its own log, which it pollutes by mirroring each digest into it
  # (those embedded per-agent status lines would be mis-read as the Observer's own
  # outcome — a garbled, recursive self-report). It knows it's alive; short-circuit.
  if [ "$label" = "com.hausverwaltung.observer" ]; then HEALTHY+=("$label|self — running now"); return; fi
  # Log path from the PLIST, not guessed from the label — com.houseclaw.* /
  # com.dan.* agents don't follow the hausverwaltung-<short>.log naming.
  local log
  log=$(plutil -extract StandardOutPath raw "$LA_DIR/$label.plist" 2>/dev/null)
  [ -n "$log" ] || log="$LOG_DIR/hausverwaltung-${label#com.hausverwaltung.}.log"
  local loaded exit_status tail_txt last age cad pid
  loaded=$(launchctl list 2>/dev/null | grep -c "$label")
  if [ "$loaded" = "0" ]; then DEADJ+=("$label|not loaded (plist present, launchctl doesn't know it)"); return; fi
  # A keep-alive service running RIGHT NOW is healthy regardless of log age
  # (bridge/tunnel write nothing for days when quiet).
  pid=$(launchctl list "$label" 2>/dev/null | sed -n 's/.*"PID" = \([0-9]*\);.*/\1/p')
  if [ -n "$pid" ]; then HEALTHY+=("$label|running now (pid $pid)"); return; fi
  exit_status=$(launchctl list "$label" 2>/dev/null | sed -n 's/.*"LastExitStatus" = \([0-9-]*\);.*/\1/p')

  if [ ! -f "$log" ]; then
    # loaded but never produced a log — either brand new or misconfigured
    [ "${exit_status:-0}" != "0" ] && FAILING+=("$label|loaded, last exit ${exit_status}, no log yet") \
                                    || HEALTHY+=("$label|loaded, no log yet (new?)")
    return
  fi
  age=$(( (NOW_EPOCH - $(stat -f %m "$log")) / 86400 ))
  cad=$(cadence_days "$label")
  tail_txt=$(tail -40 "$log")
  # the single most-recent outcome line
  last=$(print -r -- "$tail_txt" | grep -iE "Skipped:|Run complete|Digest complete|complete:|ERROR|FAIL|advanced|exit=" | tail -1)

  if print -r -- "$last" | grep -qiE "ERROR|FAIL|exit=[1-9]"; then
    FAILING+=("$label|${last#*: }")
  elif print -r -- "$last" | grep -qi "Skipped:"; then
    if skip_is_blocking "$last"; then
      # count how many consecutive recent runs skipped for a blocking reason
      local n; n=$(print -r -- "$tail_txt" | grep -c "Skipped:")
      # A dirty-tree skip is the class that motivated this whole agent. The log
      # tail is STALE — it shows the last run's skip, but the block may already be
      # fixed (the tree cleaned) and just unproven until the agent next fires. So
      # don't cry BLOCKED off a stale log: extract the repo path the skip names and
      # check if it is CLEAN right now. Clean → RECOVERING (resolved, awaiting the
      # next run to confirm); still dirty → genuinely BLOCKED.
      local rpath; rpath=$(print -r -- "$last" | grep -oE '/[^ ]+' | head -1)
      if print -r -- "$last" | grep -qi "uncommitted" && [ -n "$rpath" ] && [ -d "$rpath/.git" ] \
         && [ -z "$(git -C "$rpath" status --porcelain 2>/dev/null)" ]; then
        RECOVERING+=("$label|last run skipped (dirty tree), but ${rpath##*/} is clean now — clears on next run")
      else
        BLOCKED+=("$label|${last#*Skipped: } (≥${n} recent skip-blocks)")
      fi
    else
      TRANSIENT+=("$label|${last#*Skipped: }")
    fi
  elif [ "$age" -gt $((cad * 2)) ]; then
    STALE+=("$label|no run in ${age}d (cadence ~${cad}d)")
  else
    HEALTHY+=("$label|${last:-ran ${age}d ago}")
  fi
}

# ── discover the fleet ────────────────────────────────────────────────────────
# All three self-built prefixes — never vendor jobs (Microsoft/Slack/Adobe/…).
AGENTS=()
for plist in "$LA_DIR"/com.hausverwaltung.*.plist "$LA_DIR"/com.houseclaw.*.plist "$LA_DIR"/com.dan.*.plist; do
  [ -e "$plist" ] || continue
  AGENTS+=("$(basename "$plist" .plist)")
done
echo "Discovered ${#AGENTS[@]} agents."
for a in "${AGENTS[@]}"; do classify "$a"; done

# ── auto-fix 1: SOLVE dead-but-present jobs (safe recovery) ────────────────────
declare -a FIXED
GUI="gui/$(id -u)"
for entry in "${DEADJ[@]}"; do
  label="${entry%%|*}"; plist="$LA_DIR/$label.plist"
  if [ "$DRY_RUN" = "1" ]; then FIXED+=("would bootstrap $label"); continue; fi
  if launchctl bootstrap "$GUI" "$plist" 2>/dev/null; then
    FIXED+=("re-loaded $label (was present but not bootstrapped)")
  fi
done

# ── auto-fix 2: SOLVE log bloat (free disk) ───────────────────────────────────
declare -a TRIMMED
FREED_TOTAL=0
for log in "$LOG_DIR"/hausverwaltung-*.log; do
  [ -f "$log" ] || continue
  sz=$(stat -f %z "$log")
  [ "$sz" -le "$CAP_BYTES" ] && continue
  lines=$(wc -l < "$log" | tr -d ' ')
  [ "$lines" -le "$KEEP_LINES" ] && continue
  split_at=$((lines - KEEP_LINES))
  if [ "$DRY_RUN" = "1" ]; then
    TRIMMED+=("would trim $(basename "$log") (${sz} B, keep last ${KEEP_LINES}/${lines} lines)")
    continue
  fi
  head -n "$split_at" "$log" | gzip -c >> "$log.archive.gz"   # concatenated gzip: read with `gunzip -c`
  tail -n "$KEEP_LINES" "$log" > "$log.tmp" && mv "$log.tmp" "$log"
  newsz=$(stat -f %z "$log")
  FREED_TOTAL=$((FREED_TOTAL + sz - newsz))
  TRIMMED+=("trimmed $(basename "$log"): ${sz} → ${newsz} B")
done
# delete archives older than retention
declare -a PURGED
while IFS= read -r arch; do
  [ -z "$arch" ] && continue
  asz=$(stat -f %z "$arch" 2>/dev/null || echo 0)
  if [ "$DRY_RUN" = "1" ]; then PURGED+=("would purge $(basename "$arch") (${asz} B, >${RETENTION_DAYS}d)"); continue; fi
  rm -f "$arch" && { FREED_TOTAL=$((FREED_TOTAL + asz)); PURGED+=("purged $(basename "$arch") (${asz} B)"); }
done < <(find "$LOG_DIR" -name 'hausverwaltung-*.log.archive.gz' -mtime +${RETENTION_DAYS} 2>/dev/null)

# ── build the digest ──────────────────────────────────────────────────────────
n_bad=$(( ${#BLOCKED[@]} + ${#FAILING[@]} + ${#DEADJ[@]} + ${#STALE[@]} ))
{
  echo "## 🔭 Observer — launchd fleet health — $(date '+%Y-%m-%d %H:%M %Z')"
  echo ""
  echo "Auto-generated by \`com.hausverwaltung.observer\` (Wed 03:00). One living doc — rewritten each run, never duplicated. The Observer OBSERVES and TIDIES (logs, unloaded jobs); it never edits another agent's script/plist or the repo — those are escalated here for a human."
  echo ""
  if [ "$n_bad" = "0" ]; then
    echo "### ✅ All ${#AGENTS[@]} agents healthy"
  else
    echo "### ⚠️ ${n_bad} agent(s) need attention"
  fi
  echo ""
  emit() { local title="$1"; shift; [ "$#" -eq 0 ] && return; echo "**$title**"; echo ""; for e in "$@"; do echo "- \`${e%%|*}\` — ${e#*|}"; done; echo ""; }
  [ "${#FAILING[@]}"   -gt 0 ] && emit "🔴 FAILING (non-zero exit / error — needs a human)" "${FAILING[@]}"
  [ "${#BLOCKED[@]}"   -gt 0 ] && emit "🟠 BLOCKED (skipping every run for a persistent reason)" "${BLOCKED[@]}"
  [ "${#DEADJ[@]}"     -gt 0 ] && emit "⚫ DEAD (plist present, not loaded)" "${DEADJ[@]}"
  [ "${#STALE[@]}"     -gt 0 ] && emit "🟡 STALE (no run within ~2× cadence)" "${STALE[@]}"
  [ "${#RECOVERING[@]}" -gt 0 ] && emit "🟢 recovering (last run blocked, cause fixed — awaiting next run)" "${RECOVERING[@]}"
  [ "${#TRANSIENT[@]}" -gt 0 ] && emit "🔵 transient skip (network/expected — self-clears)" "${TRANSIENT[@]}"
  [ "${#HEALTHY[@]}"   -gt 0 ] && emit "✅ healthy" "${HEALTHY[@]}"
  echo "### 🧹 Auto-fixes this run (what the Observer SOLVED)"
  echo ""
  [ "${#FIXED[@]}"   -gt 0 ] && { for f in "${FIXED[@]}"; do echo "- $f"; done; } || echo "- no dead jobs to re-load"
  [ "${#TRIMMED[@]}" -gt 0 ] && { for t in "${TRIMMED[@]}"; do echo "- $t"; done; } || echo "- no logs over ${CAP_BYTES} B to trim"
  [ "${#PURGED[@]}"  -gt 0 ] && for p in "${PURGED[@]}"; do echo "- $p"; done
  echo "- **$(( FREED_TOTAL / 1024 )) KB freed** total."
  echo ""
  echo "---"
  echo "_Fleet: ${#AGENTS[@]} agents. Escalated items above are for you — the Observer will not self-heal a dirty-tree block or a script bug; it makes sure you SEE them._"
} > "$BODY_FILE"

cat "$BODY_FILE"

# ── escalate: pinned issue + notification (skip in dry-run) ────────────────────
if [ "$DRY_RUN" != "1" ]; then
  if [ -d "$REPO/.git" ] && curl -sf --max-time 5 https://api.github.com/zen > /dev/null 2>&1; then
    ( cd "$REPO"
      EXISTING=$(gh issue list --state open --search "$PINNED_TITLE in:title" --json number,title \
                  --jq "[.[] | select(.title==\"$PINNED_TITLE\")][0].number // empty" 2>/dev/null)
      if [ -n "$EXISTING" ]; then
        gh issue edit "$EXISTING" --body-file "$BODY_FILE" >/dev/null 2>&1 && echo "Refreshed pinned issue #$EXISTING"
      else
        gh label create observer --color 5319e7 --description "launchd fleet health (one living issue)" >/dev/null 2>&1 || true
        NEW=$(gh issue create --title "$PINNED_TITLE" --body-file "$BODY_FILE" --label observer 2>/dev/null | grep -oE '[0-9]+$' | tail -1)
        echo "Created pinned issue #${NEW:-?}"
      fi )
  else
    echo "GitHub unreachable or no repo — digest is in the log only this run."
  fi
  # macOS notification ONLY when something actionable — the anti-'unnoticed' guard.
  # It names the SINGLE most-severe agent + its concrete fix, and CLICKING it opens
  # a focused herdr workspace with claude seeded on that exact agent (via the
  # investigate-launcher's -execute). One click from "something's wrong" to
  # "working on it". terminal-notifier (not osascript) because only it supports
  # -execute; -group collapses run-over-run so the tray shows one live card.
  if [ "$n_bad" -gt 0 ]; then
    # pick the top problem by severity: FAILING > DEAD > BLOCKED > STALE
    if   [ "${#FAILING[@]}" -gt 0 ]; then top="${FAILING[1]}"; state="FAILING"
    elif [ "${#DEADJ[@]}"   -gt 0 ]; then top="${DEADJ[1]}";   state="DEAD"
    elif [ "${#BLOCKED[@]}" -gt 0 ]; then top="${BLOCKED[1]}"; state="BLOCKED"
    else                                  top="${STALE[1]}";   state="STALE"
    fi
    top_label="${top%%|*}"; top_symptom="${top#*|}"
    hint=$(fix_hint "$top_symptom")
    extra=""; [ "$n_bad" -gt 1 ] && extra=" (+$((n_bad-1)) weitere)"
    if command -v terminal-notifier >/dev/null 2>&1; then
      terminal-notifier \
        -title "🔭 ${state}: ${top_label#com.hausverwaltung.}${extra}" \
        -subtitle "${top_symptom:0:120}" \
        -message "Fix: ${hint} — Klick öffnet eine herdr-Pane auf genau diesen Agenten" \
        -execute "$HOME/.local/bin/hausverwaltung-observer-investigate.sh ${top_label}" \
        -sound Basso -group hausverwaltung-observer >/dev/null 2>&1 || true
    else
      osascript -e "display notification \"${state}: ${top_label#com.hausverwaltung.} — ${hint}\" with title \"🔭 Observer\" sound name \"Basso\"" 2>/dev/null || true
    fi
  fi
fi

# mirror digest into the log
{ echo "===== $(date -Iseconds) ====="; cat "$BODY_FILE"; echo; } >> "$LOG"
echo "Observer complete: $(date -Iseconds)  (bad=$n_bad, freed=$((FREED_TOTAL/1024))KB)"
