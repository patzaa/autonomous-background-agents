#!/usr/bin/env zsh
# Deterministic OpenClaw breakage sentinels.
#
# Asserts that the contract our app HARDCODES against OpenClaw still holds in
# the reference checkout (~/openclaw) — either at HEAD (weekly drift warning)
# or at a specific release tag (pre-flight for an image bump). These are the
# 🔴 "invisible until runtime" couplings from the breakage audit: a change to
# any of them breaks prod silently on the next OpenClaw update.
#
# Source after PATH setup. Entry point: run_openclaw_sentinels. Results land in
# globals: OCS_DRIFT (1 if any 🔴 drift), OCS_REPORT (markdown), OCS_SIGNATURE
# (stable string for alert de-dup), OCS_SUMMARY (one-line).
#
# Coupling map (our file:line → upstream anchor):
#   protocol   gateway-client.ts:565-566 / openclaw-{debug,dev}.mjs
#                                   → packages/gateway-protocol/src/version.ts
#   rpc        gateway-client.ts (chat.send/chat.history/sessions.list/…)
#                                   → src/gateway/methods/core-descriptors.ts
#   cli-flags  docker-compose.yml command override (--allow-unconfigured/--bind/--port)
#                                   → src/cli/gateway-run-argv.ts
#   docker-cmd docker-compose.yml override assumes a node-gateway entrypoint
#                                   → Dockerfile CMD/ENTRYPOINT
# (env-var / config-key / wire-shape coupling is intentionally left to the
#  claude diff-eval — upstream config-key indirection makes name-matching unreliable.)

# RPC methods our app calls over the gateway WS (audit: all in core-descriptors).
OCS_RPC_METHODS=(chat.send chat.history sessions.list agents.list device.pair.approve exec.approval.resolve)
# The subset the BACKEND client (gateway-client.ts) calls — these must be covered
# by the scopes that client requests (OCS_OUR_SCOPES). device.pair.approve is a
# DIFFERENT client (the dev approve script, operator.pairing) so it's not here.
OCS_BACKEND_METHODS=(chat.send chat.history sessions.list agents.list exec.approval.resolve)
# Scopes the backend client requests on connect (gateway-client.ts:546-551).
OCS_OUR_SCOPES=(operator.read operator.write operator.admin operator.approvals)
# Gateway CLI flags our docker-compose command override depends on.
OCS_CLI_FLAGS=(allow-unconfigured bind port)

# Read a file at a git ref, or from the working tree when ref is "" / "WT".
# NB: the local must NOT be named `path` — in zsh that is a tied alias of $PATH,
# so `local path=…` silently breaks command lookup for the rest of the function.
_ocs_read() {  # repo ref relpath
    local repo="$1" ref="$2" relpath="$3"
    if [ -z "$ref" ] || [ "$ref" = "WT" ]; then
        cat "$repo/$relpath" 2>/dev/null
    else
        git -C "$repo" show "${ref}:${relpath}" 2>/dev/null
    fi
}

# Grep the tree at a ref (or working tree). Prints matching lines.
_ocs_grep_tree() {  # repo ref pattern [pathspec...]
    local repo="$1" ref="$2" pat="$3"; shift 3
    if [ -z "$ref" ] || [ "$ref" = "WT" ]; then
        grep -rhoE "$pat" "$repo"/${1:-src} 2>/dev/null
    else
        git -C "$repo" grep -hoE "$pat" "$ref" -- "${@:-src}" 2>/dev/null
    fi
}

# Upstream PROTOCOL_VERSION integer at a ref. Robust to the file having moved
# (it relocated src/gateway/protocol/ → packages/gateway-protocol/ once already).
ocs_upstream_protocol() {  # repo ref
    local repo="$1" ref="$2" v
    v=$(_ocs_read "$repo" "$ref" "packages/gateway-protocol/src/version.ts" \
        | grep -E "PROTOCOL_VERSION[[:space:]]*=" | grep -oE "[0-9]+" | head -1)
    [ -z "$v" ] && v=$(_ocs_read "$repo" "$ref" "src/gateway/protocol/version.ts" \
        | grep -E "PROTOCOL_VERSION[[:space:]]*=" | grep -oE "[0-9]+" | head -1)
    if [ -z "$v" ]; then
        # tree-wide fallback — search BOTH src/ and packages/ (the file has
        # already moved from src/gateway/protocol/ → packages/gateway-protocol/).
        if [ -z "$ref" ] || [ "$ref" = "WT" ]; then
            v=$(grep -rhoE "PROTOCOL_VERSION[[:space:]]*=[[:space:]]*[0-9]+" "$repo/src" "$repo/packages" 2>/dev/null | grep -oE "[0-9]+" | head -1)
        else
            v=$(git -C "$repo" grep -hoE "PROTOCOL_VERSION[[:space:]]*=[[:space:]]*[0-9]+" "$ref" 2>/dev/null | grep -oE "[0-9]+" | head -1)
        fi
    fi
    echo "$v"
}

# Our pinned protocol (single source: gateway-client.ts minProtocol).
ocs_our_protocol() {  # hv_repo
    grep -oE "minProtocol:[[:space:]]*[0-9]+" "$1/src/lib/openclaw/gateway-client.ts" 2>/dev/null \
        | grep -oE "[0-9]+" | head -1
}

# The Dockerfile CMD line at a ref (normalised whitespace).
ocs_dockerfile_cmd() {  # repo ref
    _ocs_read "$1" "$2" "Dockerfile" | grep -E "^CMD" | head -1 | tr -s ' '
}

# Resolve a version string (e.g. 2026.5.28) to an existing ref, trying the
# v-prefix and the -N rebuild suffixes. Echoes the ref or nothing.
ocs_resolve_ref() {  # repo version
    local repo="$1" version="$2" cand
    for cand in "v$version" "$version" "v${version}-1" "${version}-1" "v${version}-2" "${version}-2"; do
        if git -C "$repo" rev-parse --verify --quiet "${cand}^{commit}" >/dev/null 2>&1; then
            echo "$cand"; return 0
        fi
    done
    return 1
}

# Run every sentinel. Args: openclaw_ref hv_repo [upstream_ref] [context_label]
# Sets OCS_DRIFT / OCS_REPORT / OCS_SIGNATURE / OCS_SUMMARY.
run_openclaw_sentinels() {
    local repo="$1" hv="$2" ref="${3:-WT}" ctx="${4:-upstream HEAD}"
    OCS_DRIFT=0
    local lines=() sig=() okcount=0 m flag ev cmd

    # 1) protocol version
    local up_proto our_proto
    up_proto=$(ocs_upstream_protocol "$repo" "$ref")
    our_proto=$(ocs_our_protocol "$hv")
    if [ -z "$up_proto" ]; then
        lines+=("- ⚠️ **protocol**: could not read upstream PROTOCOL_VERSION (file moved again?) — investigate manually.")
        sig+=("proto:unknown")
        OCS_DRIFT=1
    elif [ "$up_proto" = "$our_proto" ]; then
        lines+=("- ✅ **protocol**: upstream \`PROTOCOL_VERSION=${up_proto}\` == our pin \`${our_proto}\`.")
        okcount=$((okcount+1))
    else
        lines+=("- 🔴 **protocol DRIFT**: upstream \`${up_proto}\` ≠ our \`${our_proto}\`. Update \`minProtocol/maxProtocol\` in \`src/lib/openclaw/gateway-client.ts\`, \`scripts/openclaw-debug.mjs\`, \`scripts/openclaw-dev.mjs\` — then verify with \`pnpm debug:openclaw sessions\` (a real connect round-trip; image-boot smoke does NOT catch PROTOCOL_MISMATCH).")
        sig+=("proto:${up_proto}vs${our_proto}")
        OCS_DRIFT=1
    fi

    # 2) RPC method registry
    local descr missing=()
    descr=$(_ocs_read "$repo" "$ref" "src/gateway/methods/core-descriptors.ts")
    [ -z "$descr" ] && descr=$(_ocs_grep_tree "$repo" "$ref" "\"[a-z.]+\"" "src/gateway")
    for m in "${OCS_RPC_METHODS[@]}"; do
        echo "$descr" | grep -q "\"$m\"" || missing+=("$m")
    done
    if [ "${#missing[@]}" -eq 0 ]; then
        lines+=("- ✅ **rpc**: all ${#OCS_RPC_METHODS[@]} called methods still registered (chat.send, chat.history, sessions.list, agents.list, device.pair.approve, exec.approval.resolve).")
        okcount=$((okcount+1))
    else
        lines+=("- 🔴 **rpc DRIFT**: method(s) no longer found in \`core-descriptors.ts\`: \`${missing[*]}\`. Our gateway-client calls them with no fallback → silent hang / 'method not found'.")
        sig+=("rpc:${missing[*]}")
        OCS_DRIFT=1
    fi

    # 2b) auth — per-method scope still covered by what the backend requests.
    # Each backend RPC declares a required `scope:` in core-descriptors; if one
    # moves to a scope our connect frame doesn't request, the call is rejected
    # with an authz error (silent feature break). We check the declared scope of
    # each backend method is in OCS_OUR_SCOPES.
    local scopemiss=() msc
    for m in "${OCS_BACKEND_METHODS[@]}"; do
        msc=$(echo "$descr" | grep -oE "name: \"$m\", scope: \"operator\.[a-z]+\"" | grep -oE "operator\.[a-z]+" | head -1)
        [ -z "$msc" ] && continue   # method-existence already covered above
        if ! print -r -- "${OCS_OUR_SCOPES[@]}" | grep -qwF "$msc"; then
            scopemiss+=("${m}→${msc}")
        fi
    done
    if [ "${#scopemiss[@]}" -eq 0 ]; then
        lines+=("- ✅ **auth/method-scope**: every backend RPC's required scope is in our requested set (\`${OCS_OUR_SCOPES[*]}\`).")
        okcount=$((okcount+1))
    else
        lines+=("- 🔴 **auth/method-scope DRIFT**: method(s) now require a scope we don't request: \`${scopemiss[*]}\`. Add the scope to the connect frame in \`src/lib/openclaw/gateway-client.ts\` (the \`scopes\` array) or the call is authz-rejected.")
        sig+=("scope:${scopemiss[*]}")
        OCS_DRIFT=1
    fi

    # 2c) auth — the scopes we REQUEST are still recognised upstream (a renamed/
    # removed scope ⇒ connect/authz reject). Exact-token match against the
    # gateway's own scope vocabulary.
    local scopeset badscope=()
    scopeset=$(_ocs_grep_tree "$repo" "$ref" "operator\.[a-z]+" "src/gateway")
    for s in "${OCS_OUR_SCOPES[@]}"; do
        echo "$scopeset" | grep -qwF "$s" || badscope+=("$s")
    done
    if [ "${#badscope[@]}" -eq 0 ]; then
        lines+=("- ✅ **auth/scopes**: all requested scopes still exist in the gateway scope vocabulary.")
        okcount=$((okcount+1))
    else
        lines+=("- 🔴 **auth/scopes DRIFT**: scope(s) we request no longer exist upstream: \`${badscope[*]}\`. Renamed/removed → connect or authz rejected. Reconcile \`gateway-client.ts\` scopes with the new vocabulary.")
        sig+=("scopes:${badscope[*]}")
        OCS_DRIFT=1
    fi
    # (device-signature version `v2` + client.mode `backend` are NOT static
    # sentinels — upstream sources don't pin them unambiguously; the runtime WS
    # connect probe in openclaw-upgrade-validate is the guard for those.)

    # 3) gateway CLI flags (the docker-compose command override)
    local argv flagmiss=()
    argv=$(_ocs_read "$repo" "$ref" "src/cli/gateway-run-argv.ts")
    [ -z "$argv" ] && argv=$(_ocs_grep_tree "$repo" "$ref" "allow-unconfigured|--bind|--port" "src/cli")
    for flag in "${OCS_CLI_FLAGS[@]}"; do
        echo "$argv" | grep -qE "\"$flag\"|'$flag'|\b$flag\b" || flagmiss+=("--$flag")
    done
    if [ "${#flagmiss[@]}" -eq 0 ]; then
        lines+=("- ✅ **cli-flags**: \`--allow-unconfigured\`, \`--bind\`, \`--port\` all still accepted by the gateway argv parser.")
        okcount=$((okcount+1))
    else
        lines+=("- 🔴 **cli-flags DRIFT**: flag(s) gone from \`gateway-run-argv.ts\`: \`${flagmiss[*]}\`. Our \`docker-compose.yml\` command override would fail at container boot.")
        sig+=("flags:${flagmiss[*]}")
        OCS_DRIFT=1
    fi

    # NOTE: env-var / config-key / wire-schema coupling is deliberately NOT a
    # deterministic sentinel — upstream maps our OPENCLAW_* env names through
    # config-key indirection (e.g. our OPENCLAW_HOOK_TOKEN ↔ upstream `hooks.token`),
    # so literal name-matching false-positives. Those fuzzier couplings are left
    # to the claude diff-eval in the watch job (which sees the actual diff).

    # 4) Dockerfile CMD (informational — drift detected by the caller across refs)
    cmd=$(ocs_dockerfile_cmd "$repo" "$ref")
    lines+=("- ℹ️ **docker-cmd** @ ${ctx}: \`${cmd:-<none>}\` (our compose overrides this; watch for shape changes that break the override).")

    OCS_REPORT=$(printf '%s\n' "${lines[@]}")
    OCS_SIGNATURE="${(j:|:)sig}"
    if [ "$OCS_DRIFT" -eq 1 ]; then
        OCS_SUMMARY="⚠️ ${#sig[@]} sentinel(s) drifted @ ${ctx}"
    else
        OCS_SUMMARY="✅ all sentinels OK @ ${ctx} (${okcount} checks)"
    fi
}
