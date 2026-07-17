#!/usr/bin/env zsh
# Shared helpers for hybrid VPS-build + Mac-test cron jobs.
# Source from a wrapper script after PATH/nvm setup.
#
# Pattern: Mac orchestrates (drift detection, /qa, /design-review, PR/Issue),
# VPS builds (production-equivalent x86_64 podman) + serves the validate stack
# on tailnet IP:3001.

# ── env loading ────────────────────────────────────────────────────────────

# Read VPS_HOST/VPS_USER/VPS_SSH_KEY from project .env.local + .env (same
# pattern as scripts/vps.mjs in the repo).
vps_load_env() {
    local repo="$1"
    for f in "$repo/.env.local" "$repo/.env"; do
        [ -f "$f" ] || continue
        while IFS= read -r line; do
            [[ "$line" =~ ^[[:space:]]*([A-Z][A-Z0-9_]*)[[:space:]]*=[[:space:]]*(.*)$ ]] || continue
            local key="${match[1]}"
            local val="${match[2]}"
            val="${val%\"}"; val="${val#\"}"
            val="${val%\'}"; val="${val#\'}"
            # Die App-Credentials der Next.js-App gehören NICHT in die
            # Agent-Umgebung: ein exportierter ANTHROPIC_API_KEY würde jeden
            # claude-Call des Agenten auf API-Billing umleiten (Vorfall
            # 2026-07-16, "Credit balance is too low" im Release-Notes-Review).
            [ "$key" = "ANTHROPIC_API_KEY" ] && continue
            [ -z "${(P)key:-}" ] && export "$key=$val"
        done < "$f"
    done
    : "${VPS_HOST:?VPS_HOST not set in .env.local or .env}"
    : "${VPS_USER:=deploy}"
    export VPS_HOST VPS_USER VPS_SSH_KEY
}

# ── ssh wrapper ────────────────────────────────────────────────────────────

vps_ssh() {
    local opts=(-o ConnectTimeout=10 -o ServerAliveInterval=30 -o BatchMode=yes)
    [ -n "${VPS_SSH_KEY:-}" ] && opts+=(-i "$VPS_SSH_KEY")
    ssh "${opts[@]}" "${VPS_USER}@${VPS_HOST}" "$@"
}

vps_ping() {
    vps_ssh "echo ok" 2>/dev/null | grep -q "^ok$"
}

# ── tag discovery ──────────────────────────────────────────────────────────

# Try a list of plausible tag suffixes for an upstream version. Returns the
# first one that's pullable from the VPS. Uses `podman pull` (more reliable
# than `manifest inspect` which can fail on multi-arch images or specific
# registry auth configurations) — pulled layers are cached for the actual
# build that follows, so the cost is reused.
# Usage: vps_find_image_tag "ghcr.io/openclaw/openclaw" "2026.5.7"
vps_find_image_tag() {
    local image_repo="$1"
    local base_version="$2"
    # Force anonymous pull via empty authfile. VPS may have `podman login ghcr.io`
    # active for the user's own packages; that auth doesn't grant read:packages on
    # foreign repos like openclaw/openclaw, so anonymous wins for public images.
    local auth_file="/tmp/.cron-anon-auth.json"
    vps_ssh "echo '{\"auths\":{}}' > $auth_file" >/dev/null 2>&1
    local rc=1 candidate
    for candidate in "$base_version" "${base_version}-1" "${base_version}-2" "${base_version}-3"; do
        printf "  trying %s:%s\n" "$image_repo" "$candidate" >&2
        if vps_ssh "podman pull --authfile=$auth_file ${image_repo}:${candidate}" >/dev/null 2>&1; then
            printf "%s\n" "$candidate"
            rc=0
            break
        fi
    done
    vps_ssh "rm -f $auth_file" >/dev/null 2>&1
    return $rc
}

# Pull the OpenClaw image anonymously into the VPS image store so the
# subsequent `podman compose build` re-uses the cached layer (avoids 403
# on the build's implicit pull). Call after vps_find_image_tag succeeds.
vps_pre_pull_anonymous() {
    local image_ref="$1"  # e.g. ghcr.io/openclaw/openclaw:2026.5.7
    local auth_file="/tmp/.cron-anon-auth.json"
    vps_ssh "echo '{\"auths\":{}}' > $auth_file && podman pull --authfile=$auth_file '$image_ref' && rm -f $auth_file"
}

# ── workspace lifecycle ────────────────────────────────────────────────────

# Set up a fresh validate workspace on the VPS by rsyncing a local Mac
# worktree (the VPS doesn't have a git checkout — only deployed files —
# so cloning from VPS-local doesn't work). Symlinks .env from the prod
# directory so secrets remain on the VPS, never traverse the rsync.
vps_setup_workspace() {
    local workspace="$1"
    local local_source="$2"  # absolute path to Mac worktree
    [ -d "$local_source" ] || { echo "ERROR: local_source '$local_source' does not exist" >&2; return 1; }

    vps_ssh "rm -rf '$workspace' && mkdir -p '$workspace'"

    # rsync excludes: caches, build outputs, secrets, big binary trees
    rsync -az --delete \
        --exclude='.git/' --exclude='node_modules/' --exclude='.next/' \
        --exclude='coverage/' --exclude='storybook-static/' \
        --exclude='imports-local/' --exclude='*.log' \
        --exclude='.env' --exclude='.env.local' \
        -e "ssh -o ConnectTimeout=10 -o BatchMode=yes${VPS_SSH_KEY:+ -i $VPS_SSH_KEY}" \
        "${local_source}/" "${VPS_USER}@${VPS_HOST}:${workspace}/" >/dev/null

    # Symlink secrets that live on the VPS only (never cross the wire)
    vps_ssh "cd '$workspace' && ln -sf \"\$HOME/hausverwaltung/.env\" .env"
}

# Generate per-run docker-compose.validate.yml on the VPS by DERIVING it from
# the canonical docker-compose.yml that was rsynced into the workspace — never
# by re-declaring the services here.
#
# WHY derive instead of hand-write: a hand-written validate compose silently
# rots whenever production's compose changes. That is exactly what broke this
# harness — production added `command: [openclaw gateway --allow-unconfigured …]`
# to the openclaw service (upstream's 2026.5.26+ startup guard refuses to bind
# without it), but the hand-written validate compose never got it, so the
# gateway died at boot ("Missing config … pass --allow-unconfigured"), /healthz
# was unreachable, /api/health returned 503, and EVERY drift-day run false-failed
# with `health_failed` and filed a spurious "stack unhealthy" issue (e.g. #369).
#
# By copying the canonical `openclaw` (and `nextjs`) service dicts verbatim, the
# command override, the openclaw.json + workspace bind mounts, and the env
# mappings are all inherited and can never drift again. We mutate ONLY what MUST
# differ on a host already running the prod stack:
#   - openclaw: drop the host port publish (prod owns :18789; nextjs reaches the
#     gateway via service DNS over the project network) + retag the image so the
#     build doesn't clobber prod's `homeclaw:latest`.
#   - nextjs:   publish on the tailnet IP:<port> so the Mac can curl /api/health
#     over the tunnel + retag the image so the build doesn't clobber prod's
#     `…hausverwaltung-api:latest` + inject NEXT_PUBLIC_* build args (Next.js
#     inlines these at build time, so env_file alone isn't enough).
#   - keep only nextjs + openclaw (drop caddy / cloudflared / pgboss-dashboard).
#
# NOTE: native `podman compose -f base -f override` layering can't do this —
# podman-compose 1.5.0 (the VPS provider) appends list keys (so colliding host
# ports can't be removed) and ignores the `!reset`/`!override` tags. Hence the
# PyYAML transform. The project name (workspace dir basename) namespaces the
# network + named volumes away from the prod `hausverwaltung` project.
# Optional 3rd arg gw_port: publish the validate openclaw gateway on
# ${VPS_HOST}:${gw_port}:18789 (tailnet-only, short-lived) so a caller can run a
# real protocol-negotiated WS connect probe against it. Omitted (default) ⇒ the
# gateway publishes no host port (reached only via service DNS), as before.
vps_write_validate_compose() {
    local workspace="$1"
    local port="${2:-3001}"
    local gw_port="${3:-}"
    vps_ssh "cd '$workspace' && \
      VPS_HOST='${VPS_HOST}' \
      VALIDATE_PORT='${port}' \
      VALIDATE_GW_PORT='${gw_port}' \
      NEXT_PUBLIC_SUPABASE_URL='${NEXT_PUBLIC_SUPABASE_URL:-}' \
      NEXT_PUBLIC_SUPABASE_ANON_KEY='${NEXT_PUBLIC_SUPABASE_ANON_KEY:-}' \
      python3 - <<'PYEOF'
import os, sys, yaml

host = os.environ['VPS_HOST']
port = os.environ['VALIDATE_PORT']
gwport = os.environ.get('VALIDATE_GW_PORT', '').strip()

with open('docker-compose.yml') as f:
    c = yaml.safe_load(f)

svcs = c.get('services', {})
missing = [s for s in ('nextjs', 'openclaw') if s not in svcs]
if missing:
    sys.exit('ERROR: canonical compose missing service(s): ' + ', '.join(missing))

# Keep only the two services we validate; top-level volumes stay declared so
# the named volumes the services reference resolve (project-namespaced => fresh).
c['services'] = {k: svcs[k] for k in ('nextjs', 'openclaw')}

oc = c['services']['openclaw']
oc.pop('restart', None)
oc['image'] = 'localhost/hv-validate-homeclaw:latest'
if gwport:
    # publish on the tailnet IP only (like nextjs) so the Mac can WS-probe it;
    # NOT prod's :18789 (that collides with the running prod gateway).
    oc['ports'] = ['{}:{}:18789'.format(host, gwport)]
else:
    oc.pop('ports', None)  # default: reach the gateway only via service DNS

nx = c['services']['nextjs']
nx.pop('restart', None)
nx['image'] = 'localhost/hv-validate-nextjs:latest'
nx['ports'] = ['{}:{}:3000'.format(host, port)]
b = nx.get('build', '.')
b = {'context': b} if isinstance(b, str) else dict(b)
b.setdefault('args', {})
b['args'].update({
    'NEXT_PUBLIC_SUPABASE_URL': os.environ.get('NEXT_PUBLIC_SUPABASE_URL', ''),
    'NEXT_PUBLIC_SUPABASE_ANON_KEY': os.environ.get('NEXT_PUBLIC_SUPABASE_ANON_KEY', ''),
    'NEXT_PUBLIC_APP_URL': 'http://{}:{}'.format(host, port),
})
nx['build'] = b

with open('docker-compose.validate.yml', 'w') as f:
    yaml.safe_dump(c, f, default_flow_style=False, sort_keys=False)
print('derived docker-compose.validate.yml from canonical (services: nextjs, openclaw)')
PYEOF"
}

# ── stack lifecycle ────────────────────────────────────────────────────────

# Note on exit codes: a naïve `cmd | tail` pipeline returns tail's status,
# not cmd's. We write the full log to a tmpfile on VPS and re-emit the tail
# while preserving the build's exit code via $?.
vps_build_stack() {
    local workspace="$1"
    vps_ssh "cd '$workspace' && podman compose -f docker-compose.validate.yml build > /tmp/.validate-build.log 2>&1; rc=\$?; tail -40 /tmp/.validate-build.log; exit \$rc"
}

vps_up_stack() {
    local workspace="$1"
    vps_ssh "cd '$workspace' && podman compose -f docker-compose.validate.yml up -d > /tmp/.validate-up.log 2>&1; rc=\$?; tail -10 /tmp/.validate-up.log; exit \$rc"
}

# Retrieve the saved build log tail (call after build_stack failure).
vps_get_build_log() {
    vps_ssh "tail -60 /tmp/.validate-build.log 2>/dev/null || echo '(no build log)'"
}

# Tear down the validate stack and remove the workspace directory.
vps_teardown() {
    local workspace="$1"
    [ -z "$workspace" ] && return 0
    vps_ssh "cd '$workspace' 2>/dev/null && podman compose -f docker-compose.validate.yml down -v 2>&1 | tail -5
        rm -rf '$workspace' 2>/dev/null
        true" || true
}

vps_collect_logs() {
    local workspace="$1"
    vps_ssh "cd '$workspace' 2>/dev/null && podman compose -f docker-compose.validate.yml logs --tail=80 2>&1 | tail -100"
}

# Approve the validate stack's Next.js gateway-client pairing so /qa can ACTUALLY
# test chat. The validate stack boots unpaired; without this every chat surface
# 502s and /qa mis-attributes it to the image (the spurious #383 false positive).
# The validate gateway runs --allow-unconfigured but still loads our mounted
# openclaw.json (dangerouslyDisableDeviceAuth=true), so the Control-UI approve
# path works. gw_port = the tailnet host port the gateway is published on.
# Pair the validate Next.js container with the fresh validate gateway.
#
# ROOT CAUSE this routine fixes (runs 3-5, 2026-07-16/17): Next.js connects to
# the gateway LAZILY (gateway-client.ts `ensureConnected()` — only on the first
# gateway RPC, e.g. a chat call), NOT at boot. And its connect frame uses the
# SAME `client.id: "gateway-client"` as our WS probe. So at pairing time only
# the probe has registered a pending request; approving "all pending" grabs the
# probe's and returns success while Next.js never registered — its request
# appears only when QA fires the first chat, long after pairing. Result:
# NOT_PAIRED chat surface through both gates, three verdicts contaminated.
#
# The fix is a TRIGGER + real VERIFY:
#   1. curl an authenticated endpoint that forces a gateway RPC
#      (/api/chat/sessions → chatSessionsList → ensureConnected) so Next.js
#      registers its gateway-client pending request DURING the pairing window.
#   2. poll + approve every pending request each cycle (probe + Next.js share
#      clientId, so approve all — harmless on a throwaway stack), re-triggering
#      the connect so a raced first attempt still lands.
#   3. VERIFY for real: once approved, Next.js reconnects with its granted
#      deviceToken and no longer registers a pending request. A pending.json
#      that STAYS empty after a re-trigger = paired. (The old verify —
#      /api/health `openclaw.ok` — is HTTP /healthz reachability only, a proven
#      false positive: green while the chat surface was NOT_PAIRED.)
#
# Args: <gw_port> <validate_url> <auth_cookie>
vps_pair_validate_nextjs() {
    local gw_port="$1" validate_url="$2" cookie="$3"
    local container token i pending reqids rid
    container=$(vps_ssh "podman ps --format '{{.Names}}'" 2>/dev/null | grep -i validate | grep -vi nextjs | grep -i openclaw | head -1)
    [ -z "$container" ] && { echo "  pairing: no validate openclaw container found — skipping"; return 1; }
    token=$(vps_ssh "podman exec '$container' sh -c 'echo \$OPENCLAW_GATEWAY_TOKEN'" 2>/dev/null | tr -d '\r\n ')
    [ -z "$token" ] && { echo "  pairing: could not read gateway token"; return 1; }

    local -A approved
    local paired=0
    for i in $(seq 1 20); do
        # (Re)trigger Next.js's lazy gateway connect so it registers its
        # gateway-client pending request. Authenticated → hits the gateway path.
        curl -s -o /dev/null --max-time 8 -H "Cookie: ${cookie}" "${validate_url}/api/chat/sessions" 2>/dev/null || true
        sleep 3
        pending=$(vps_ssh "podman exec '$container' cat /home/node/.openclaw/devices/pending.json 2>/dev/null")
        reqids=$(printf '%s' "$pending" | python3 -c "import json,sys
try: d=json.load(sys.stdin)
except Exception: d={}
print(' '.join(r.get('requestId','') for r in (d.values() if isinstance(d,dict) else d) if isinstance(r,dict) and r.get('requestId')))" 2>/dev/null)
        for rid in ${=reqids}; do
            [ -n "${approved[$rid]:-}" ] && continue
            echo "  pairing: approving pending request ${rid} ..."
            OC_GW_URL="ws://${VPS_HOST}:${gw_port}" OC_ORIGIN="http://${VPS_HOST}:${gw_port}" \
                OC_TOKEN="$token" OC_REQUEST_ID="$rid" \
                NODE_PATH="$HOME/hausverwaltung/node_modules" \
                node /Users/dan/.local/lib/openclaw-approve.cjs && approved[$rid]=1
        done
        # VERIFY: after ≥1 approval, a re-trigger that produces NO new pending
        # request means Next.js reconnected with its granted deviceToken.
        if [ ${#approved[@]} -gt 0 ] && [ -z "$reqids" ]; then
            paired=1; echo "  pairing: verified — Next.js reconnected paired (no new pending after ${i} cycles, ${#approved[@]} approved)"; break
        fi
    done
    [ "$paired" -eq 1 ] && return 0
    echo "  pairing: NOT verified after ~2min (approved ${#approved[@]}, last pending: ${reqids:-none}) — chat surface may be NOT_PAIRED."
    return 1
}

# ── healthcheck (called from Mac, hits VPS over tailnet) ──────────────────

vps_wait_healthy() {
    local url="$1"
    local max_attempts="${2:-45}"
    for i in $(seq 1 $max_attempts); do
        if curl -sf -o /dev/null --max-time 5 "$url"; then
            echo "✓ Healthy at $url after $((i * 2))s"
            return 0
        fi
        sleep 2
    done
    return 1
}

# ── pretty header ──────────────────────────────────────────────────────────

vps_print_header() {
    local label="$1"
    echo ""
    echo "=========================================="
    echo "  $label: $(date -Iseconds)"
    echo "=========================================="
}
