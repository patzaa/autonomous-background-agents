# autonomous-background-agents

A fleet of **autonomous background agents** that operates a production platform ([Hausverwaltung](https://github.com/patzaa/Hausverwaltung) — a German property-management system) from a single Mac. Each agent is a zsh script driven by **macOS launchd** (`launchagents/*.plist`), most of them delegate judgment calls to a headless **Claude Code** session (`claude -p`), and every run appends to its own log under `~/Library/Logs/hausverwaltung-*.log`.

Monitored live with [agenttop](https://github.com/patzaa/Agenttop) — an htop-style terminal dashboard for launchd agents + Claude token spend.

## The fleet

| Agent | Schedule | What it does |
|---|---|---|
| `openclaw-upgrade-validate` | daily 00:00 | Watches upstream OpenClaw releases. On drift: reads the **release notes** and has Claude judge them against our integration contract (protocol pin, CLI flags, pairing, rebrand, auth) — `NEEDS_CHANGES` raises a clickable macOS notification; then bumps the pin in a worktree, builds + boots the stack **locally** (podman) and on the **VPS** (prod-equivalent), probes a real WS protocol connect, runs read-only `/qa-only` + `/design-review`, and opens a validated PR (gates green) or a BLOCKED issue (gates red). Ends with a self-improvement reflection on the harness itself. |
| `deploy-validate` | daily 01:00 | Post-deploy validation of the production stack. |
| `agent-script-audit` | daily 01:xx | Audits the agent scripts themselves for drift/rot. |
| `openclaw-ui-watch` | Mon 02:00 | Weekly read of the upstream OpenClaw **chat-UI source**: deterministic breakage sentinels (protocol/RPC/CLI contract at HEAD), security watch (advisories + CVEs vs our pinned image), then a Claude evaluation of the UI diff for **portable chat features** — files one gated GitHub issue per finding class. Never writes code. |
| `cso-audit` | daily 02:xx | Chief-Security-Officer-mode audit of the platform. |
| `observer` | daily 03:00 | Watches the other agents' outcomes; can spawn an investigation session. |
| `coverage-audit` | daily 03:xx | Test-coverage audit of the Hausverwaltung repo. |
| `worktree-cleaner` | daily 03:30 | Keeps the worktree/branch fleet small. Removes worktrees whose branch is **proven merged in code** (commit containment, patch-id equivalence, or squash-proof — GitHub's merge state is never trusted); auto-ships stale unmerged worktrees (idle ≥48h) by driving a Claude session through commit → merge main → `/ship` → `/land-and-deploy` (capped 2/night, removal only after next-night code proof); sweeps merged local+remote branches (remote capped 30/night, never a branch with an open PR, never uncommitted work). |
| `audit-health` | daily 08:00 | Morning health check across the audit fleet. |

## Shared infrastructure

- **`bin/hausverwaltung-notify.sh` + `bin/hausverwaltung-notify-open.sh`** — clickable macOS notifications (terminal-notifier). When an agent fails, needs input, or finishes something worth reviewing, it posts a notification; **clicking it opens a new terminal pane via [herdr](https://github.com/patzaa/herdr) running an interactive Claude Code session in the affected directory, pre-seeded with the full context prompt** — you land directly in a session that already knows what went wrong and can work the problem from there. herdr's CLI can launch panes/tabs programmatically over its unix socket, so the whole jump — notification → new terminal → contextualized Claude session — is one click. (Fallback without herdr: a plain Terminal.app window.)
- **`lib/hausverwaltung-openclaw-sentinels.sh`** — deterministic breakage sentinels: asserts our hardcoded OpenClaw contract (protocol version, RPC names, gateway CLI flags) against any upstream ref.
- **`lib/hausverwaltung-openclaw-security.sh`** — upstream advisory/CVE/security-commit watch against the pinned image, de-duped per finding.
- **`lib/hausverwaltung-vps-validate.sh`** / **`lib/hausverwaltung-validate-local.sh`** — build/boot/health/teardown primitives for the VPS and local podman validate stacks.
- **`lib/openclaw-approve.cjs`** — programmatic OpenClaw device-pairing approval for freshly booted validate gateways.

## Design principles

1. **Read-only by default, gated writes.** Agents file issues/PRs; production writes happen only through validated, human-reviewable paths. Destructive steps carry hard caps and code-level proofs (see worktree-cleaner).
2. **Don't trust status — prove it.** Merge state is proven in git content, upstream contract drift is asserted with sentinels at the exact ref, a WS probe does a real protocol negotiation because boot-smoke doesn't catch protocol bumps.
3. **Infra failure ≠ product failure.** A Claude usage limit or network blip aborts a run cleanly (retry next schedule) instead of filing a misleading BLOCKED issue; state (like the last-evaluated SHA) only advances on success.
4. **Every run is auditable.** One log per agent under `~/Library/Logs/`, one outcome line per run, de-duped GitHub issues per finding signature.
5. **When a human is needed, bring the human to the context** — clickable notification → herdr pane → seeded Claude session, not a bare error line in a log nobody reads.

## Layout & install

```
bin/           → ~/.local/bin/          (agent entry points + notify helpers)
lib/           → ~/.local/lib/          (shared sourced libraries)
launchagents/  → ~/Library/LaunchAgents/ (launchd schedules)
```

```sh
cp bin/* ~/.local/bin/ && chmod +x ~/.local/bin/hausverwaltung-*
cp lib/* ~/.local/lib/
cp launchagents/*.plist ~/Library/LaunchAgents/
for p in ~/Library/LaunchAgents/com.hausverwaltung.*.plist; do launchctl bootstrap gui/$(id -u) "$p"; done
```

Requirements: macOS, zsh, `git`, `gh` (authed), `claude` (Claude Code CLI), `podman`, `terminal-notifier` (`brew install terminal-notifier`), [herdr](https://github.com/patzaa/herdr) for click-to-session, tailnet access to the VPS for the validate agents.

The **live copies** in `~/.local/bin` / `~/.local/lib` / `~/Library/LaunchAgents` are canonical; this repo is the versioned mirror. After editing a live script, run `./sync.sh` and commit.

## License

MIT — see [LICENSE](LICENSE).
