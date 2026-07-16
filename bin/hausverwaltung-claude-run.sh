#!/usr/bin/env zsh
# claude-Wrapper für die Agenten-Flotte: Modell-Fallback auf Opus.
# Usage: hausverwaltung-claude-run.sh <outfile> <claude-args...>
#
# Läuft claude mit dem Session-Default (Fable). Schlägt der Lauf fehl, WEIL
# das Abo-Modell nicht verfügbar ist (Usage-Limit erreicht / overloaded),
# wird GENAU EINMAL mit --model opus wiederholt (Dan, 2026-07-16: "wenn
# fable nicht verfügbar dann auf opus switchen").
#
# Der Retry ÜBERSCHREIBT das Outfile (mit Marker-Zeile): die Aufrufer greppen
# das Outfile auf Infra-Fehlermuster ("usage limit", …) — bliebe die
# Limit-Zeile von Versuch 1 stehen, würde ein ERFOLGREICHER Opus-Retry
# fälschlich als Infra-Abbruch gewertet. Der Marker vermeidet die Muster.
set -u
OUT="${1:?usage: hausverwaltung-claude-run.sh <outfile> <claude-args...>}"
shift

claude "$@" > "$OUT" 2>&1
rc=$?
if [ "$rc" -ne 0 ] && grep -qiE "reached your .* limit|usage limit|overloaded" "$OUT"; then
    {
        echo "(⤷ Standard-Modell nicht verfügbar — Retry mit --model opus)"
        claude --model opus "$@" 2>&1
    } > "$OUT"
    rc=$?
fi
exit $rc
