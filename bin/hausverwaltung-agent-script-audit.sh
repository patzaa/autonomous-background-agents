#!/usr/bin/env zsh
# Hausverwaltung agent-script audit — local automated cron.
# Loaded by ~/Library/LaunchAgents/com.hausverwaltung.agent-script-audit.plist
# Fires Mon/Wed/Fri/Sun at 01:00 local time (~every 2 days).
#
# What it does (via `claude -p`) — CAPABILITY / `hv`-first:
#   - Runs the governance guards (check:capabilities / check:manifest /
#     check:agent-docs / check:evals) and fixes mechanical drift, incl.
#     regenerating the agent CAPABILITIES.md + manifests via gen:agent-api.
#   - Pulls recent agent traces via `pnpm debug:openclaw` and looks for NEW
#     capabilities (hv CLIs) worth building — esp. read-capabilities replacing
#     recurring raw db-query.sh reads — then builds + tests the clear, safe ones.
#   - Audits raw service-role WRITE scripts (db-write.sh / log-action.sh /
#     db-event.sh / db-update.sh): deletes provably-dead ones, and PROPOSES a
#     write-capability for any still-live raw writer (never auto-builds writes).
#   - Keeps the test/eval loop current: eval question files valid, a demo
#     question added for every new capability, contract tests green.
#   - Surfaces agent struggle patterns (4xx loops, retries, give-ups, missing
#     capabilities) as a PR-body checklist.
#   - Consolidates tool-chains: an SOP step that needs ≥2 sequential calls
#     becomes ONE descriptive, typed, retry-aware capability (CHECK 1d).
#   - Opens (or skips) a PR. Pure regen/doc-drift AND fully-tested READ-ONLY
#     capability builds/consolidations auto-merge + deploy (owner-authorized
#     2026-07-15; the full test+guard+smoke gate is the safety). Destructive /
#     mutation / migration work is PROPOSED for human review, never built.

set -uo pipefail

export PATH="/Users/dan/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"

export BASH_DEFAULT_TIMEOUT_MS=900000
export BASH_MAX_TIMEOUT_MS=3600000

# Fail-fast on git/curl when the network is flaky — without these, git defaults
# wait ~10 min before timing out (burned 25 min on 2026-05-27 at 01:13).
export GIT_HTTP_LOW_SPEED_LIMIT=1000
export GIT_HTTP_LOW_SPEED_TIME=30

REPO="$HOME/hausverwaltung"
DATE=$(date +%Y-%m-%d-%H%M)
BRANCH="chore/agent-capability-audit-$DATE"
WORKTREE_SLUG=$(echo "$BRANCH" | sed 's|/|-|g')
WORKTREE_PATH="$HOME/hausverwaltung-$WORKTREE_SLUG"

echo ""
echo "=========================================="
echo "  Agent-capability audit run: $(date -Iseconds)"
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

if [ -n "$(git status --porcelain)" ]; then
    echo "Skipped: $REPO has uncommitted changes (won't touch your working tree)."
    git status --short
    exit 0
fi

echo "Fetching origin/main ..."
git fetch origin main

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

PROMPT="You are running the Hausverwaltung agent-capability audit. Final goal: keep the OpenClaw agents' CAPABILITY / \`hv\` surface in sync with the code, keep the governance + eval/test loop green, and proactively find NEW capabilities (hv CLIs) worth building — then build and test the clear, safe ones.

You are in a fresh git worktree on branch $BRANCH at $WORKTREE_PATH (already off the latest origin/main). Read CLAUDE.md first — especially the section 'Agent-automatable capabilities (the Capability pattern)' and docs/designs/capability-pattern.md. Stop after ~45 minutes — commit and PR what you have; don't try to do everything if time runs out.

# CONTEXT — the Capability pattern is the system

Every agent action is a Capability: ONE auth-free core in \`src/lib/<domain>/<domain>-mutations.ts\` (or a typed read core in \`status-reads.ts\` / \`*-cores.ts\`), a thin \`requireAdmin()\` UI wrapper in \`actions.ts\`, and an agent surface registered via \`defineCapability(...)\` in \`src/lib/<domain>/capabilities.ts\`. Per-agent GRANTS live in \`src/lib/capabilities/registry-list.ts\` (\`AGENT_CAPABILITIES\`). The generator \`pnpm gen:agent-api\` projects each grant into \`openclaw/workspace-<agent>/CAPABILITIES.md\` + \`capabilities.manifest.json\` (NEVER hand-edit those). Agents invoke capabilities through the \`hv\` CLI (\`hv list\` / \`hv describe <tool>\` / \`hv call <tool> --json '{…}'\`); the canonical script is \`openclaw/workspace-etv/scripts/hv\`, distributed verbatim into every granted workspace. Reference domains: kontakte (READ — searchContacts / searchTenants / getContactContext / listLiegenschaftKontakte), abrechnung + wirtschaftsplan (lifecycle mutations + typed status-reads), belege (createBeleg), etv.

Raw \`db-query.sh\` allowlists are the LEGACY read path being retired in favour of typed read-capabilities. Do NOT grow allowlists as a fix — a recurring raw read is a SIGNAL that a capability is missing.

# CHECK 1 — Governance-guard drift (mechanical; keep the loop GREEN)

Run, from the worktree root, and fix what each one flags:
1. \`pnpm gen:agent-api\` then \`git status --short\`. If any \`openclaw/workspace-*/{CAPABILITIES.md,capabilities.manifest.json}\` or the distributed \`scripts/hv\` changed, the registries drifted from the committed docs — KEEP the regenerated output (this is the capability-era analog of the old allowlist sync). This is mechanical.
2. \`pnpm check:capabilities\` (Guard A) — every exported \`*Core\` in \`src/lib/**/*-mutations.ts\` must be registered in a domain \`capabilities.ts\` OR exempted in \`src/lib/capabilities/ui-only-cores.ts\` with a reason. A NEW unregistered core fails this. Resolve by judgment: if it is a clearly safe, agent-appropriate read/mutation, register it (CHECK 3); if it is destructive / approval-gated / UI-only, add a referenced exemption with a one-line reason. Note every decision in the PR body.
3. \`pnpm check:manifest\` (Guard B) and \`pnpm check:agent-docs\` (Guard C) — fix mechanical drift only: a hand-written routing doc (AGENTS.md / TOOLS.md / skills/**.md) referencing a retired script, or a granted capability not named in any of that agent's routing docs. Apply current-state-only edits (replace stale text; NEVER append 'deprecated' notes — agents start fresh each session). Exemptions live in scripts/agent-docs-exemptions.json.
4. \`pnpm check:evals\` (Guard D) — eval question-file integrity (see CHECK 4).

# CHECK 1b — PROMPT HYGIENE: current state ONLY, zero tool history (HARD RULE — owner's explicit instruction)

An agent prompt states the CURRENT way to do a thing. It carries NO history of how the thing used to be done, and it NEVER names a tool the agent must not use. This is not a style preference — it is a correctness rule, for three reasons: (a) it costs tokens on every single session; (b) naming a forbidden tool PLANTS it — the model now knows a path exists that it is being asked not to take, and under pressure it takes it; (c) it rots the moment the old thing is deleted, leaving the prompt pointing at something that does not exist.

BAN these shapes wherever an agent can read them. Hunt them with a grep over EVERY prompt surface, then fix each at its SOURCE:
- supersession notes: 'Ersetzt \`X.sh\`', 'replaces the raw \`X.sh\`', 'EIN typisierter Call statt \`X.sh\`', '(was \`X.sh\`)'
- prohibition-by-naming: 'NIEMALS mit \`X.sh\` / alten Skripten nachprüfen', 'nutze nicht X, sondern Y', 'do not use the old …'
- bridge/deprecation prose: 'die alten Skripte sind nur noch Brücken', 'DEPRECATED', 'legacy — use \`hv\` instead', 'für eine Release noch verfügbar'
- any reference to a script/route/tool that no longer exists on disk

The prompt surfaces are: \`openclaw/workspace-*/AGENTS.md\`, \`TOOLS.md\`, \`SCOPE.md\`, \`skills/**/SKILL.md\`, the wake templates in \`openclaw/openclaw.json\`, AND — this is the one people miss — the GENERATED \`openclaw/workspace-*/CAPABILITIES.md\`, which is written verbatim from the Zod \`description\` fields in \`src/lib/<domain>/capabilities.ts\`. A supersession note in a capability DESCRIPTION is a prompt bug, not a code comment: fix the description and re-run \`pnpm gen:agent-api\`. NEVER hand-edit the generated file.

Rewrite in place to the positive, current form ('X findest du mit \`hv call searchHandwerker\`') — do not append a correction, do not leave a 'formerly' note, do not add a changelog line inside a prompt. \`pnpm check:agent-docs\` lints for this automatically; if it is green but you can still SEE baggage by reading the prompts, the guard has a gap — fix the prose AND widen the guard's pattern list in \`scripts/check-agent-docs.mjs\` (that is a legitimate, in-scope change for this audit). Deliberate, justified references are exempted in \`scripts/agent-docs-exemptions.json\` — an exemption needs a reason, and 'we haven't cleaned it up yet' is not one.

# CHECK 1c — SOP COVERAGE: every prescribed action needs exactly ONE typed capability

The SOPs (\`openclaw/workspace-cora/skills/ticket-sop/SKILL.md\` + the per-archetype SOPs beside it, and the other agents' \`skills/**/SKILL.md\`) are the specification of what the agents are supposed to DO. A SOP step that prescribes an action for which no capability exists is a DEAD PRESCRIPTION — the agent reads an instruction it physically cannot follow, and then improvises (raw db-query, asking the Verwalter, or silently skipping). The sop-tool-coverage program (v0.12.206.0–v0.12.219.0) found the phase advance dead in 11 of 11 SOPs this way. Keeping that closed is now part of THIS audit, every run.

1. Enumerate the SOPs and, for each, extract every step that prescribes an ACTION (a verb the agent must perform: anlegen, senden, festhalten, zuordnen, freigeben lassen, Termin vorschlagen, Phase weiterschalten, …) — not the reasoning steps.
2. For each action, resolve it to exactly ONE granted capability in that agent's \`capabilities.manifest.json\`. Three outcomes:
   - **Covered** — a capability exists AND the SOP names it. Do NOT stop at 'the name is present' — VERIFY the tool actually works: \`pnpm hv --agent <agent> describe <tool>\` (schema + example), and for a read-only tool a real \`pnpm hv --agent <agent> call <tool> --json '{…}'\` against a known entity. A covered-but-BROKEN tool is worse than a gap: the SOP trusts a tool that 500s, times out, or returns the wrong shape, and the agent has no fallback and no signal. This is exactly the failure class the 2026-07-15 audit surfaced — Cora's and Werner's first SOP step returned exit 7 and an empty page for weeks because the tool's transport silently died, while the SOP read as 'covered'. If a covered tool is broken, fixing it is the highest-priority item of the run.
   - **Covered but unrouted** — the capability exists but the SOP describes the action in prose without naming the \`hv call\`. The agent has the tool and does not know it. This is a ROUTING fix (current-state-only edit to the SOP) — do it, it is mechanical.
   - **Uncovered** — no capability backs the prescribed action. This is a capability GAP. Follow CHECK 3's build-vs-propose rule: build it this run if it is clearly safe and read-only-or-benign; PROPOSE it (name, agent, domain, core signature, the SOP line that motivates it) if it is destructive/approval-gated/needs a migration.
3. A gap that is uncoverable because the DATA does not exist (no schema for the thing the SOP hinges on — the \`getGewaehrleistung\` case) or because it needs a PRODUCT decision (whose calendar? may the agent assign?) is NOT a build and NOT a silent skip: it goes in the backlog issue (CHECK 5b) WITH the blocking question stated in one sentence. Do not build past an unanswered product question.
4. NEW SOPs since the last run are the highest-value input here: \`git log --since='<last run>' --name-only -- 'openclaw/**/skills/**'\`. A SOP that landed without its tools is precisely the failure this check exists to catch.

# CHECK 1d — TOOL-CHAIN CONSOLIDATION: one turn should cost ONE call, not five (owner's explicit priority)

The failure this catches is NOT a missing tool — it is a tool surface that FORCES the model to chain calls. When a SOP step (or an observed trace, CHECK 2/5) makes the agent call ≥2 tools IN SEQUENCE, threading an id from call N into call N+1, to answer ONE question, that chain is a tax paid on every single run: latency, tokens, AND a fresh chance at each hop to malform an argument or mis-thread an id. The end state the owner wants: every recurring SOP question resolves to ONE descriptive, well-tested capability with typed errors and retry semantics — never a recipe the model assembles by hand.

The worked references are ALREADY IN THE CODEBASE — study them before proposing anything, they define the target shape:
- \`getEinheitMieter\` collapsed the classic 3-call chain (liegenschaft-search → db-query einheiten → db-query mietvertraege) into ONE call that takes a human locator and returns the current tenant WITH an explicit status.
- \`getTicketContext\` is 'the ONE fat read a turn opens with' — it absorbs the graph ready-set + conversations[], so a turn costs one read instead of three.
- \`getContactContext\` with \`includeMieter: true\` hangs each owned unit's current tenants off \`besitzeinheiten[]\` in ONE batched query — the owner-side Mieterwechsel research is a single call.

Detect chains from two signals:
1. SOP/SKILL steps prescribing a SEQUENCE where one call's output is the next call's input (grep for 'dann', 'danach', 'mit der id/UUID aus', numbered multi-call recipes, a \`→ db-query\` following an \`hv call\`).
2. Traces (CHECK 2/5) where one session repeatedly issues the same 2–3-call shape.

The fix is ONE capability that does the whole chain server-side and returns the composed result. Non-negotiable properties:
- **Batched, not looped** — the server does the joins / fan-out in one query set (the \`getContactContext\` includeMieter pattern), never N round-trips it just moved inside the handler.
- **Descriptive** — the Zod \`description\` states exactly what it composes and when to reach for it, so the model PICKS it over the raw chain without being told 'don't use the chain' (naming the chain is banned baggage, CHECK 1b — describe the good path, never forbid the old one).
- **Typed envelope + retry semantics** — the same \`{ok, data|error{code,message,retryable}, traceId}\` shape \`hv\` uses; a partial failure names WHICH leg failed and whether it is retryable. A consolidated tool must NEVER half-succeed silently (the createBeleg money-reconcile discipline, applied to reads).
- **Human keys in, resolved server-side** — take \`Wohnung 3, Haager Str.\`, return candidates on ambiguity; never a UUID the model had to fetch in a prior call (that would re-introduce the chain).

PROVE the win: the eval question's \`max_tool_calls\` for that task must DROP (e.g. 3→1). State the before/after count in the PR body.

BUILD vs PROPOSE follows CHECK 3's rule exactly: a read-only consolidation you can fully test this run → BUILD it (it auto-merges+deploys, see DECISION). A consolidation that folds in a WRITE, or needs a new migration → PROPOSE it. NEVER fold a destructive leg into an auto-merged read tool — a consolidated tool is read-only or it is a proposal, there is no middle.

# CHECK 2 — Recurring raw reads → capability candidates (judgment)

1. Pull recent agent activity: \`pnpm debug:openclaw sessions\` (recency-ordered), then \`pnpm debug:openclaw history <session-key>\` for the ~20 most recent. If \`history\` times out, retry it up to 3×; if it still fails, FALL BACK to the durable ticket-transcript mirror (Postgres, shipped v0.12.89.0) via \`pnpm vps db query \"…\"\` and note the gateway outage in the PR — never let a gateway timeout silently skip CHECK 2 / CHECK 5 (that blinded a prior run, #552).
2. Tally tables hit via raw \`db-query.sh\` across sessions. For any table read ≥ 5× that has NO covering capability: this is a candidate READ-capability (typed core + lean output projection, the kontakte domain is the worked reference — NOT a new bash helper, NOT an allowlist entry).
3. Also flag stale/over-broad ALLOWED_TABLES entries and any agent still preferring raw db-query.sh where a capability already exists (that is a routing-doc / SKILL.md fix → CHECK 1.3 or a struggle finding).

# CHECK 2b — Raw WRITE-path discipline (writes stay on the capability pattern)

Symmetric to CHECK 2 but for WRITES, and stricter: a raw service-role WRITE is never an acceptable fallback — every agent write must go through a typed, token-gated route/capability (the \`createBeleg\` / \`recordImportEvent\` pattern). The OpenClaw container only still needs \`SUPABASE_SERVICE_ROLE_KEY\` because raw writers exist; the end state is zero.

1. Enumerate raw writers across every \`openclaw/workspace-*/scripts/\`: any script that issues \`-X POST\` / \`-X PATCH\` to \`/rest/v1/\` with \`SUPABASE_SERVICE_ROLE_KEY\` (directly, or via \`_db-common.sh\` / \`build_rest_headers\`). Known shapes: \`db-write.sh\`, \`log-action.sh\`, \`db-event.sh\`, \`db-update.sh\`, \`db-write-bulk.sh\`. A script that instead does \`exec .../hv call <tool>\` is already migrated — NOT a finding.
2. Classify each raw writer by grepping the agent's SKILLs + AGENTS.md/TOOLS.md for ACTUAL call sites (a \`<script>.sh \` invocation, not just a 'Verfügbare Scripts' listing):
   - **Dead + uncalled** (only listed, never invoked — or it writes ONLY to tables with NO Drizzle model in \`src/lib/db/schema-v2.ts\`, e.g. \`approval_queue\` / \`maintenance_requests\` / \`service_ticket_history\`): removal IS the fix — delete the script and scrub its doc references (current-state-only). Mechanical; note it in the PR body.
   - **Live** (a SKILL/AGENTS step actually calls it): this is a MISSING write-capability. Do NOT build it (writes are human-review-gated — see SAFETY RAILS). PROPOSE it in the PR body: tool name, target agent + domain, core signature (\`<verb>Core(input): Promise<ActionResult<…>>\` in \`src/lib/<domain>/<domain>-mutations.ts\`), and the call sites that motivate it — mirror how \`recordImportEvent\` / \`setImportSessionStatus\` replaced import's \`db-event.sh\` / \`db-update.sh\` (thin \`hv\`-delegator at the script, typed Zod core behind the bearer route).
3. Also flag any AGENTS.md/SKILL prose still claiming a raw db-write surface that no longer exists, or naming a dead table (e.g. \`approval_queue\`) where the live path is a capability — current-state-only doc fix.

# CHECK 3 — NEW capabilities to BUILD + TEST (the core of this audit)

Find capabilities that should exist but don't, from two signals:
- **Code signal:** diff the exported cores against what is registered. \`grep -rlE 'export async function [a-zA-Z]+Core' src/lib/**/*-mutations.ts\` vs each \`src/lib/<domain>/capabilities.ts\` vs \`ui-only-cores.ts\`. A core that is neither registered nor exempted is an unmade decision. High-value typed reads (status-reads, lookups) that agents currently reach via raw SQL are also candidates.
- **Trace signal (CHECK 2):** recurring raw reads, and places an agent gave up / fell back to raw db / asked the Verwalter for something it could have self-served — each is a missing capability.

For a candidate that is CLEARLY in-scope, low-risk, and read-only-or-safe (mirrors the kontakte read pattern): BUILD it end-to-end this run —
  a. add/locate the auth-free core (typed Zod input + lean typed output projection — never raw rows);
  b. register it via \`defineCapability\` in the domain \`capabilities.ts\`; grant the domain to the right agent in \`registry-list.ts\` if not already granted;
  c. \`pnpm gen:agent-api\` and commit the regenerated docs/manifest;
  d. TEST it: the table-driven \`src/lib/capabilities/contract.test.ts\` auto-covers any newly granted domain — run \`pnpm vitest run src/lib/capabilities/contract.test.ts scripts/hv-cli.test.ts\`; and add ≥1 demo question for it to the domain's eval yaml (CHECK 4);
  e. smoke it: \`pnpm hv --agent <agent> describe <tool>\` shows the schema + example, and (read-only tools only) \`pnpm hv --agent <agent> call <tool> --json '{…}'\` returns an \`ok\` envelope.

Do NOT autonomously build: destructive/approval-gated mutations (booking, sending, finalize, storno), anything needing a new DB migration, or anything whose blast radius you cannot fully test in this run. PROPOSE those in the PR body (rationale + which sessions/cores motivate it + sketch of the core signature) for human review.

# CHECK 4 — Eval / test loop freshness (keep it CURRENT)

The agent-eval loop lives in \`tests/agent-evals/*.yaml\` (demo questions) + \`<domain>.verdicts.yaml\` (verdicts) + \`corpus.jsonl\`; \`pnpm check:evals\` lints integrity (ids, unknown agents/tools, dead fingerprint paths). Tasks:
- For EVERY new capability you build in CHECK 3, add ≥1 demo question to that domain's \`tests/agent-evals/<domain>.yaml\` (copy the shape of an existing entry: id, frage, expects.tools, max_tool_calls, answer_contains). Re-run \`pnpm check:evals\` until clean.
- Fix mechanical eval-file drift surfaced by check:evals (a question naming a tool that no longer exists, a fingerprint path that moved).
- Do NOT run \`pnpm eval:agent run\` here and do NOT write verdicts — running against prod + judging traces is the /agent-evals analyst's job (needs human-grade judgment). Instead, list in the PR body which domains have staled verdicts (because you changed a capability, SKILL doc, query-layer file, or grant — that changes the fingerprint closure) so a human can re-run + re-judge via the /agent-evals skill.

# CHECK 5 — Agent struggle patterns (READ-ONLY findings)

From the session traces, surface as a PR-body checklist (NO code changes from this section; cite session keys, redact PII):
- 4xx / exitCode 7 from \`hv\`, db-query.sh, or PostgREST (with the triggering request)
- tool calls retried ≥ 2× in one session (first call likely malformed → a \`describe\` example or schema fix)
- a tool that errored then the agent gave up / changed direction (missing capability → CHECK 3)
- 'token budget exhausted' markers; invocations of tools that don't exist (typo/hallucination → routing-doc fix)

# CHECK 5b — Carry proposals + struggle findings in ONE deduped issue (NOT re-typed every run)

CHECK 2b/3 proposals and CHECK 5 struggle findings must NOT be re-pasted into every PR body — that is exactly why the same items (recordImportAudit, proposeBuchung, the searchHandwerker empty-result lever, …) recur for weeks with no resolution. Keep ONE durable home:
- \`gh issue list --label agent-audit --state open --search 'Agent-audit backlog in:title'\`. If none exists, \`gh issue create --label agent-audit --title 'Agent-audit backlog: proposals + carried findings' --body '...'\`.
- REWRITE that issue's body (current-state-only) with today's open proposals + struggle findings, deduped; CHECK off / remove items that are now done. One issue, always current — like the agent workspace docs.
- In the PR body, LINK that issue (\"Backlog: #NNN\") instead of repeating the prose; keep the PR body to what THIS run actually changed.

# EXISTING-PR HANDLING (idempotency + ANTI-ROT — an audit PR must merge fast or die fast)

\`gh pr list --label agent-audit --state open --json number,title,headRefName,createdAt\`. For EACH open agent-audit PR:
1. SUPERSEDE CHECK (close it if main already did the work): list its files (\`gh pr view <n> --json files\`). For each path, \`git cat-file -e origin/main:<path>\` — if EVERY file the PR touches is either GONE from main (a deletion the PR proposed that main already made) OR byte-identical to main's version, the PR is fully superseded → \`gh pr close <n> --comment 'Superseded — every file is already in its target state on main.'\` Do NOT reaffirm it. (This is exactly what stranded #552 for 10 days: main's #578 had already deleted the file the PR deleted.)
2. STALE CHECK: if it is > 3 days old, still unmerged, and NOT superseded above, it has rotted against a moving main (version race + content drift) → \`gh pr close <n> --comment 'Closed — stale vs main (>3d). Superseded by today's audit run.'\` and re-derive from scratch this run.
3. Otherwise (fresh AND not superseded) it already covers this surface → do NOT open a duplicate; reaffirm in ONE short comment only if you found something genuinely NEW this run, else exit cleanly with no comment.
A 3-day-old open audit PR is a BUG in this loop, not a backlog item — never let one outlive a single audit cycle. (Auto-merge is armed on every PR via CHECK 6, so a green PR merges itself within the hour; a PR still open after 3 days is red or conflicted, i.e. rotten.)

# CHECK 6 — CHANGELOG prose (the deterministic finalizer owns the version + auto-merge plumbing)

A post-run finalizer (\`hausverwaltung-finalize-audit-pr.sh\`, run by the wrapper the moment you exit) GUARANTEES the numeric version bump (VERSION + package.json), \`pnpm release:reconcile\` (collision-free vs main), and ARMING auto-merge — so a green PR self-merges and CI 'Release guards' can never strand it (the bug that held #552/#562 for 10 days). You therefore do NOT compute the next-free version and do NOT run \`gh pr merge --auto\` yourself. Your ONE job here: add a CHANGELOG.md top section with REAL prose describing THIS run's change (the finalizer only writes a generic placeholder line if you left none). Bumping VERSION/package.json yourself is harmless (the finalizer reconciles it) — just never skip the CHANGELOG prose, and open the PR with a good body as usual.

# DECISION: PR OR NOT

Stage with \`git status --short\` first. Create labels if missing: \`gh label create agent-audit --color 0e8a16 --description \"Auto-generated by local agent-capability audit cron\" 2>/dev/null || true\`; \`gh label create mechanical-only --color c2e0c6 --description \"Pure regen/doc-drift, safe to auto-merge\" 2>/dev/null || true\`. PR title: \`chore(agents): capability audit \$(date +%Y-%m-%d)\`.

- **Mechanical-only** (auto-merge): the ONLY content changes are regenerated \`gen:agent-api\` output and/or current-state routing-doc drift fixes — NO new/changed capability code, NO new tests, all guards green. (The CHECK 6 version bump is REQUIRED plumbing on every PR — it does NOT disqualify a PR from mechanical-only.) Commit \`chore(agents): sync capability docs + guards (YYYY-MM-DD)\`, labels \`agent-audit\` + \`mechanical-only\`. (The post-run finalizer arms auto-merge and guarantees the version bump — you do NOT run \`gh pr merge\` yourself; the PR merges itself once 'Release guards' + 'validate' are green.) PR body: Summary / Guard drift fixed / Verification / Footer.
- **Tested read-only capability** (auto-merge + DEPLOY — the owner's explicit authorization, 2026-07-15): a newly built OR consolidated (CHECK 1d) capability that is read-only-or-benign AND ends the run with the FULL gate green — \`check:capabilities\` + \`check:manifest\` + \`check:agent-docs\` + \`check:evals\` all pass, \`src/lib/capabilities/contract.test.ts\` + \`scripts/hv-cli.test.ts\` pass, ≥1 eval question added, and a live \`pnpm hv --agent <agent> describe <tool>\` + read-only \`call\` smoke returns an \`ok\` envelope — MERGES ITSELF and deploys to prod. This is the whole point of the loosening: a fully-tested read tool that the model needs should not sit for days waiting on a human; merging IS deploying (merge→CI→VPS, per the deploy model). Label \`agent-audit\` ONLY (NOT \`mechanical-only\` — that label means 'no capability code', which is false here; the auto-merge does NOT come from the label, it comes from the finalizer arming \`--auto\` + \`main\` requiring no human review, so the PR self-merges the moment 'check' + 'validate' + 'Release guards' are green). The gate is the safety, not a human — so the gate is NON-NEGOTIABLE: if you cannot close ALL of it within budget, this is NOT this tier — REVERT the half-built tool and drop to Human-review/propose. Never let an untested or half-tested tool reach this tier. PR body: Summary / New-or-consolidated capability (tool, agent, core, the SOP line or chain it replaces, before→after \`max_tool_calls\`) / Full gate results (each guard + test named) / Smoke output / Footer.
- **Human-review** (propose only, NO capability code merged): a run that would need a DESTRUCTIVE / approval-gated / mutation capability (booking, sending, finalize, storno, any write), anything needing a NEW migration, or anything whose blast radius you cannot fully test this run. You do NOT build these — you PROPOSE them (CHECK 2b/3) in the deduped backlog issue (CHECK 5b) and link it. Also carries CHECK 5 struggle findings. Label \`agent-audit\` ONLY. PR body (if the run produced any mergeable mechanical/read-only work alongside the proposals): Summary / Guards run / SOP coverage (CHECK 1c — actions checked, covered-and-verified vs broken-and-fixed vs gaps built vs proposed vs blocked, with the blocking question for each blocked one) / Tool-chain consolidation (CHECK 1d — chains found, collapsed vs proposed, before→after call counts) / Prompt hygiene (CHECK 1b) / Proposed capabilities (rationale + motivating sessions/cores) / Eval staleness / Struggle findings checklist (session keys, PII redacted) / Verification.

  A prompt-hygiene-only run (CHECK 1b edits + the regenerated docs, no capability code) IS mechanical-only and auto-merges — keeping prompts clean must never wait on a human.
- **Nothing actionable:** no PR; print a one-line summary; exit 0 (the wrapper cleans the worktree).

# SAFETY RAILS (non-negotiable)
- Never --no-verify, never force push, never commit to main.
- ALWAYS run \`pnpm gen:agent-api\` after any registry/grant change and commit its output; NEVER hand-edit CAPABILITIES.md / capabilities.manifest.json.
- Every capability you build MUST end the run with: check:capabilities + check:manifest + check:agent-docs + check:evals green, a passing contract.test.ts + hv-cli.test.ts, ≥1 eval question, AND a live \`hv describe\` + read-only \`call\` smoke. This full gate is now doing double duty: it is the ONLY thing standing between a self-built read tool and an unattended prod deploy (DECISION → 'Tested read-only capability'). If you can't close ALL of it within budget, REVERT the half-built capability and PROPOSE it instead — a half-tested tool must NEVER reach the auto-merge tier. Never land an untested capability.
- The auto-merge+deploy authority is READ-ONLY-ONLY, and that boundary is the whole safety model. Never register a destructive / approval-gated mutation (booking, sending mail, finalize, storno, ANY db write) as an agent capability, and never fold a write leg into a consolidated (CHECK 1d) read tool. Booking stays operator-gated; a mutation is ALWAYS a proposal for human review, never a build — so it can never reach the merge tier because it never becomes code. Reads and clearly-safe read compositions only.
- Never run \`pnpm db:push\`, any migration command, or \`pnpm eval:agent run\` (prod-touching). You MAY DELETE a provably-dead, uncalled raw writer and scrub its docs (CHECK 2b — removal is the fix), but NEVER autonomously BUILD/register a write or mutation capability, and never rewrite a LIVE raw writer's behaviour — a live raw writer is a PROPOSAL for human review, not a build.
- Never delete files unless removal IS the fix and the file is dead. Never commit secrets or PII — redact tenant names/emails to first letter + suffix when citing traces.
- When you DELETE a retired script, finish the job in the SAME run: its mentions in the capability \`description\` fields, the routing docs + SOPs, any workspace script that invoked it, and any test that existed only to compare against it (keep whatever that test asserted about the CAPABILITY — see \`src/lib/contacts/contact-search-capability.test.ts\` for the shape). A deletion that leaves the name behind in a prompt is worse than no deletion: the prompt now points at nothing.
- Prompt hygiene (CHECK 1b) is not optional and not deferrable to a backlog item. If you find tool-history baggage in a prompt, fix it in the run you found it — it is always a small, safe, current-state-only edit.
- Run \`pnpm vitest run\` (or the targeted suites you touched) before opening the PR; mention results in Verification. \`pnpm lint\` only matters if you touched JS/TS — say so either way.

# FINAL OUTPUT (under 200 words)
- branch name + PR URL (or 'no PR opened') + whether auto-merge was applied
- guards run and their pass/fail
- SOP coverage (CHECK 1c): # actions checked, # covered-but-unrouted fixed, # gaps built, # gaps proposed, # blocked on a product/schema question
- prompt hygiene (CHECK 1b): # baggage references removed, and WHERE (source description vs routing doc vs SOP) — say 'none found' explicitly if clean, never omit the line
- new capabilities BUILT (tool names) and PROPOSED (count)
- raw write-path (CHECK 2b): # dead writers deleted, # live writers proposed as write-capabilities
- eval questions added; domains flagged for re-judge
- # struggle findings (high-level categories)
- anything skipped/reverted due to time"

CLAUDE_OUT=$(mktemp)
"$HOME/.local/bin/hausverwaltung-claude-run.sh" "$CLAUDE_OUT" --dangerously-skip-permissions -p "$PROMPT"
EXIT_CODE=$?
cat "$CLAUDE_OUT"; rm -f "$CLAUDE_OUT"

# Deterministic keystone — guarantee the version bump + auto-merge regardless of
# what the agent did inside `claude -p`. These two steps must not depend on the LLM
# remembering them (that dependency stranded #552/#562 for 10 days).
if [ -d "$WORKTREE_PATH" ]; then
    echo "Finalizing audit PR (deterministic version bump + auto-merge) ..."
    "$HOME/.local/bin/hausverwaltung-finalize-audit-pr.sh" "$WORKTREE_PATH" "$BRANCH" "agent-audit" \
        || echo "Warning: finalize step returned non-zero (see above)"
fi

echo "Cleaning up worktree ..."
cd "$REPO"
pnpm worktree:rm "$BRANCH" --force 2>&1 || {
    echo "Warning: pnpm worktree:rm failed — falling back to git worktree remove"
    git worktree remove --force "$WORKTREE_PATH" 2>/dev/null || true
}

echo "Run complete: exit=$EXIT_CODE  finished=$(date -Iseconds)"
exit $EXIT_CODE
