#!/usr/bin/env zsh
# Local full-stack validate — build + boot the prod-equivalent stack on the Mac
# (podman, native arm64) as a FAST PRE-GATE before any VPS work. Same derive-from-
# canonical approach as the VPS path, but: localhost ports, the local .env.local
# backend, local image tags (never touches prod tags), and local `podman compose`.
#
# Entry: validate_local <repo> [nextjs_port] [gw_port]
# Sets globals: VL_OK (1 pass / 0 fail), VL_STAGE (last stage), VL_REPORT (detail).
#
# Stages: derive → build → up → health → ws-probe → teardown.
# The stack talks to whatever .env.local points at (dev Supabase) — this gate
# proves the image boots, the gateway negotiates our protocol, and /api/health is
# green. Backend-integration fidelity (real prod data) stays the VPS gate's job.

VL_PROJECT="hv-validate-local"
_VL_COMPOSE=""

_vl_teardown() {
    [ -n "$_VL_COMPOSE" ] || return 0
    podman compose -p "$VL_PROJECT" -f "$_VL_COMPOSE" down -v >/dev/null 2>&1
    rm -f "$_VL_COMPOSE"
    _VL_COMPOSE=""
}

validate_local() {
    local repo="$1" port="${2:-3001}" gw="${3:-18790}"
    VL_OK=0; VL_STAGE="derive"; VL_REPORT=""
    [ -f "$repo/docker-compose.yml" ] || { VL_REPORT="no docker-compose.yml in $repo"; return 1; }
    [ -f "$repo/.env.local" ]        || { VL_REPORT="no .env.local in $repo"; return 1; }

    _VL_COMPOSE="$(mktemp -t hv-vl).yml"
    REPO="$repo" PORT="$port" GW="$gw" OUT="$_VL_COMPOSE" python3 - <<'PY'
import os, yaml
repo, port, gw, out = os.environ['REPO'], os.environ['PORT'], os.environ['GW'], os.environ['OUT']
with open(repo + '/docker-compose.yml') as f:
    c = yaml.safe_load(f)
svcs = c.get('services', {})
c['services'] = {k: svcs[k] for k in ('nextjs', 'openclaw') if k in svcs}

# read NEXT_PUBLIC_* from .env.local (Next.js inlines these at build time)
env = {}
for line in open(repo + '/.env.local'):
    line = line.strip()
    if line.startswith('NEXT_PUBLIC_') and '=' in line:
        k, v = line.split('=', 1)
        env[k] = v.strip().strip('"').strip("'")

oc = c['services']['openclaw']
oc.pop('restart', None)
oc['image'] = 'localhost/hv-vl-homeclaw:latest'         # never clobber prod homeclaw:latest
oc['ports'] = ['127.0.0.1:{}:18789'.format(gw)]         # loopback only
ocb = oc.get('build', '.'); ocb = {'context': ocb} if isinstance(ocb, str) else dict(ocb)
ocb['context'] = repo; oc['build'] = ocb                # absolute context (compose lives in /tmp)
oc['env_file'] = repo + '/.env.local'

nx = c['services']['nextjs']
nx.pop('restart', None)
nx['image'] = 'localhost/hv-vl-nextjs:latest'
nx['ports'] = ['127.0.0.1:{}:3000'.format(port)]
nxb = nx.get('build', '.'); nxb = {'context': nxb} if isinstance(nxb, str) else dict(nxb)
nxb['context'] = repo
nxb.setdefault('args', {})
nxb['args'].update({
    'NEXT_PUBLIC_SUPABASE_URL': env.get('NEXT_PUBLIC_SUPABASE_URL', ''),
    'NEXT_PUBLIC_SUPABASE_ANON_KEY': env.get('NEXT_PUBLIC_SUPABASE_ANON_KEY', ''),
    'NEXT_PUBLIC_APP_URL': 'http://localhost:{}'.format(port),
})
nx['build'] = nxb
nx['env_file'] = repo + '/.env.local'

# Absolutize `./`-relative bind-mount sources. The canonical compose anchors
# them to the compose file's dir; ours lives in /tmp, so `./openclaw/openclaw.json`
# would resolve to /tmp/... — podman then auto-creates it as a DIRECTORY and the
# gateway reads a dir (EISDIR). Anchor every `./X` mount at the repo instead.
for _svc in (oc, nx):
    vols = _svc.get('volumes')
    if vols:
        _svc['volumes'] = [
            (repo + v[1:] if isinstance(v, str) and v.startswith('./') else v)
            for v in vols
        ]

with open(out, 'w') as f:
    yaml.safe_dump(c, f, sort_keys=False)
print('derived local validate compose (services: nextjs, openclaw)')
PY
    [ -s "$_VL_COMPOSE" ] || { VL_REPORT="compose derivation failed"; return 1; }

    local cmpose=(podman compose -p "$VL_PROJECT" -f "$_VL_COMPOSE" --env-file "$repo/.env.local")

    VL_STAGE="build"
    echo "[$(date -Iseconds)] local build (podman, arm64) ..."
    if ! "${cmpose[@]}" build > /tmp/hv-vl-build.log 2>&1; then
        VL_REPORT="build failed:"$'\n'"$(tail -30 /tmp/hv-vl-build.log)"
        _vl_teardown; return 1
    fi

    VL_STAGE="up"
    echo "[$(date -Iseconds)] up ..."
    "${cmpose[@]}" up -d > /tmp/hv-vl-up.log 2>&1

    VL_STAGE="health"
    echo "[$(date -Iseconds)] waiting for http://localhost:${port}/api/health ..."
    local i ok=0
    for i in $(seq 1 45); do
        if curl -sf -o /dev/null --max-time 5 "http://localhost:${port}/api/health"; then ok=1; break; fi
        sleep 2
    done
    if [ "$ok" -ne 1 ]; then
        VL_REPORT="/api/health did not come up within 90s:"$'\n'"$("${cmpose[@]}" logs --tail=40 2>&1 | tail -40)"
        _vl_teardown; return 1
    fi

    VL_STAGE="ws-probe"
    echo "[$(date -Iseconds)] WS connect probe (ws://localhost:${gw}) ..."
    local probe
    # The probe runs `pnpm debug:openclaw`, which needs node_modules + the debug
    # device key. When $repo is a bare worktree (cron bump) that has neither, set
    # VL_PROBE_REPO to a full checkout (e.g. the main repo) — same protocol-4
    # client, so it's a faithful probe of the freshly-built gateway.
    probe=$( cd "${VL_PROBE_REPO:-$repo}" && OPENCLAW_DEBUG_GATEWAY_URL="ws://localhost:${gw}" timeout 60 pnpm -s debug:openclaw sessions 2>&1 )
    if echo "$probe" | grep -qiE 'protocol[_ ]?mismatch|unsupported protocol'; then
        VL_REPORT="WS PROTOCOL_MISMATCH against the new gateway:"$'\n'"$(echo "$probe" | tail -15)"
        _vl_teardown; return 1
    fi

    # Leave the stack running for interactive QA when asked (VL_KEEP_UP=1);
    # caller is then responsible for `podman compose -p hv-validate-local ... down -v`.
    [ -n "${VL_KEEP_UP:-}" ] || _vl_teardown
    VL_OK=1; VL_STAGE="done"
    VL_REPORT="local stack built + booted; /api/health green; WS connect negotiated protocol OK (pairing/auth reply expected for a fresh gateway).${VL_KEEP_UP:+ Stack left UP (compose: $_VL_COMPOSE).}"
    return 0
}
