#!/usr/bin/env zsh
# OpenClaw upstream SECURITY watch helpers.
#
# Three checks, each de-duped via its own state file so a weekly cron only
# alerts on NEW findings. Entry point: ocsec_run. Accumulates into globals:
#   OCSEC_NEW (1 if anything new), OCSEC_REPORT (markdown), OCSEC_SUMMARY.
#
#   advisories  GitHub Security Advisories for openclaw/openclaw (gh api).
#               Flags 🔴 if our pinned version is in the vulnerable range OR the
#               advisory is high/critical; 🟠 otherwise. De-dup by GHSA id.
#   commits     security-keyword commits that landed since the last watch SHA
#               (incremental). De-dup is implicit (range moves forward).
#   image-cve   Trivy scan of the pinned image (what we actually run) for
#               HIGH/CRITICAL CVEs. De-dup by CVE id.

OCSEC_SECURITY_KEYWORDS='security|CVE-|vulnerab|\bRCE\b|injection|sandbox escape|sandbox-escape|auth bypass|authentication bypass|\bSSRF\b|\bXSS\b|path traversal|privilege escalation|fix\(sec'

# Numeric dotted-version compare: returns 0 (true) if $1 <= $2. Date-style
# versions (2026.5.27) compare field-by-field numerically. Non-numeric ⇒ false.
_ocsec_ver_le() {
    local a="$1" b="$2"
    [[ "$a" =~ ^[0-9.]+$ && "$b" =~ ^[0-9.]+$ ]] || return 1
    local -a ax bx; ax=("${(@s:.:)a}"); bx=("${(@s:.:)b}")
    local i n=$(( ${#ax} > ${#bx} ? ${#ax} : ${#bx} ))
    for (( i=1; i<=n; i++ )); do
        local x=${ax[i]:-0} y=${bx[i]:-0}
        (( x < y )) && return 0
        (( x > y )) && return 1
    done
    return 0  # equal
}

# Best-effort "does this range include our pinned version?" Handles the common
# `< X` / `<= X` shapes; anything else ⇒ "unknown" (caller surfaces for manual
# review rather than asserting safety).
# Echoes: yes | no | unknown
_ocsec_range_affects() {  # range pinned
    local range="$1" pinned="$2" bound
    range="${range## }"; range="${range%% }"
    if [[ "$range" == "<= "* ]]; then
        bound="${range#<= }"; _ocsec_ver_le "$pinned" "$bound" && echo yes || echo no
    elif [[ "$range" == "< "* ]]; then
        bound="${range#< }"
        # pinned < bound  ⇔  pinned <= bound AND pinned != bound
        if _ocsec_ver_le "$pinned" "$bound" && [ "$pinned" != "$bound" ]; then echo yes; else echo no; fi
    else
        echo unknown
    fi
}

# 1) GitHub Security Advisories
_ocsec_advisories() {  # slug pinned state_dir  → appends to OCSEC_* ; returns 0 if new
    local slug="$1" pinned="$2" sdir="$3"
    local seen="$sdir/seen-advisories"; touch "$seen"
    local tsv new_lines=() hard=0 any=0
    # Filter via gh's OWN --jq (lenient about the raw control chars some
    # advisory summaries carry, which standalone jq 1.7 rejects). Emit one
    # TSV row per advisory; sanitize the summary so tabs/newlines can't break
    # the field split.
    tsv=$(gh api "/repos/${slug}/security-advisories?per_page=100" \
        --jq '.[] | [.ghsa_id, (.severity // "unknown"), ([.vulnerabilities[]?.vulnerable_version_range] | join(", ")), ((.summary // "") | gsub("[\r\n\t]"; " "))] | @tsv' \
        2>/dev/null) || {
        OCSEC_REPORT+=$'\n- ⚠️ **advisories**: gh api call failed (network/auth) — skipped this run.'
        return 1
    }
    local ghsa sev rng summ
    while IFS=$'\t' read -r ghsa sev rng summ; do
        [ -z "$ghsa" ] && continue
        grep -qxF "$ghsa" "$seen" && continue          # already alerted
        local affects="unknown" r
        for r in ${(s:,:)rng}; do
            # (no trim here — _ocsec_range_affects trims its own input)
            case "$(_ocsec_range_affects "$r" "$pinned")" in
                yes) affects=yes; break;;
                no) [ "$affects" = unknown ] && affects=no;;
            esac
        done
        local mark="🟠"
        { [ "$affects" = yes ] || [[ "$sev" == (high|critical) ]]; } && { mark="🔴"; hard=1; }
        new_lines+=("  - ${mark} [\`${ghsa}\`](https://github.com/${slug}/security/advisories/${ghsa}) · **${sev}** · affects-our-pin: **${affects}** · range \`${rng}\` — ${summ}")
        echo "$ghsa" >> "$seen"
        any=1
    done <<< "$tsv"
    [ "${OCSEC_BASELINE:-0}" = 1 ] && return 0   # first run: ids recorded, no alert
    if [ "$any" -eq 1 ]; then
        OCSEC_NEW=1
        [ "$hard" -eq 1 ] && OCSEC_HARD=1
        OCSEC_REPORT+=$'\n### New security advisories (pinned: '"${pinned}"$')\n'"$(printf '%s\n' "${new_lines[@]}")"
        return 0
    fi
    return 1
}

# 2) security-keyword commits since the last watch SHA (incremental)
_ocsec_commit_scan() {  # openclaw_ref last_sha head
    local repo="$1" last="$2" head="$3"
    [ -z "$last" ] && return 1
    local hits
    hits=$(git -C "$repo" log "${last}..${head}" --no-merges --regexp-ignore-case \
        --grep="$OCSEC_SECURITY_KEYWORDS" --extended-regexp \
        --pretty=format:'  - `%h` %s' 2>/dev/null)
    if [ -n "$hits" ]; then
        OCSEC_NEW=1
        OCSEC_REPORT+=$'\n### Security-relevant commits since last review\n'"$hits"
        return 0
    fi
    return 1
}

# 3) Trivy image CVE scan of the pinned image (what we run)
_ocsec_image_scan() {  # image_ref state_dir
    local image="$1" sdir="$2"
    command -v trivy >/dev/null 2>&1 || {
        OCSEC_REPORT+=$'\n- ℹ️ **image-cve**: trivy not installed (`brew install trivy`) — skipped.'
        return 1
    }
    local seen="$sdir/seen-cves"; touch "$seen"
    local rows new_lines=() any=0
    # Use trivy's NATIVE template output (id\tseverity\tpkg) — NOT --format json
    # piped to jq: trivy's JSON carries free-text vuln descriptions with invalid
    # escapes that standalone jq rejects. Title is dropped (it's the escape-prone
    # field, and id/severity/pkg never contain tabs).
    rows=$(trivy image --quiet --scanners vuln --severity HIGH,CRITICAL \
        --format template \
        --template '{{ range . }}{{ range .Vulnerabilities }}{{ .VulnerabilityID }}{{ "\t" }}{{ .Severity }}{{ "\t" }}{{ .PkgName }}{{ "\n" }}{{ end }}{{ end }}' \
        "$image" 2>/dev/null) || {
        OCSEC_REPORT+=$'\n- ⚠️ **image-cve**: trivy scan of `'"$image"'` failed (pull/auth?) — skipped.'
        return 1
    }
    while IFS=$'\t' read -r id sev pkg; do
        [ -z "$id" ] && continue
        grep -qxF "$id" "$seen" && continue        # de-dup across runs AND within (same CVE, many pkgs)
        new_lines+=("  - 🔴 \`${id}\` · ${sev} · \`${pkg}\`")
        echo "$id" >> "$seen"
        any=1
    done <<< "$rows"
    [ "${OCSEC_BASELINE:-0}" = 1 ] && return 0   # first run: ids recorded, no alert
    if [ "$any" -eq 1 ]; then
        OCSEC_NEW=1; OCSEC_HARD=1
        OCSEC_REPORT+=$'\n### New HIGH/CRITICAL CVEs in the pinned image (`'"${image}"$'`)\n'"$(printf '%s\n' "${new_lines[@]}")"
        return 0
    fi
    return 1
}

# Orchestrator. Args: slug pinned_version openclaw_ref last_sha head image_ref state_dir
# Sets OCSEC_NEW / OCSEC_HARD / OCSEC_REPORT / OCSEC_SUMMARY.
ocsec_run() {
    local slug="$1" pinned="$2" repo="$3" last_sha="$4" head="$5" image="$6" sdir="$7"
    OCSEC_NEW=0; OCSEC_HARD=0; OCSEC_REPORT=""
    mkdir -p "$sdir"
    # First-ever security run: record the current advisories + CVEs as the
    # baseline (no alert on 30 historical advisories), then alert only on NEW.
    # The helpers communicate ONLY via OCSEC_* globals + the seen files — they
    # have no legitimate stdout. Redirect their stdout to /dev/null: a bare
    # `case "$(fn)"` over the version ranges leaks the loop var to stdout in
    # this zsh, and there's no reason to let any helper stdout reach the cron log.
    # (Redirection here is NOT a subshell, so the global assignments persist.)
    if [ ! -f "$sdir/.sec-baselined" ]; then
        OCSEC_BASELINE=1
        _ocsec_advisories "$slug" "$pinned" "$sdir" >/dev/null
        _ocsec_image_scan "$image" "$sdir" >/dev/null
        OCSEC_BASELINE=0
        touch "$sdir/.sec-baselined"
        OCSEC_NEW=0; OCSEC_REPORT=""
        OCSEC_SUMMARY="security: baseline recorded (advisories + CVEs)"
        return 0
    fi
    _ocsec_advisories "$slug" "$pinned" "$sdir" >/dev/null
    _ocsec_commit_scan "$repo" "$last_sha" "$head" >/dev/null
    _ocsec_image_scan "$image" "$sdir" >/dev/null
    if [ "$OCSEC_NEW" -eq 1 ]; then
        OCSEC_SUMMARY="security: new findings${OCSEC_HARD:+ (incl. 🔴)}"
    else
        OCSEC_SUMMARY="security: nothing new"
    fi
}
