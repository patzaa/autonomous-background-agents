#!/usr/bin/env zsh
# Local-first full-stack validate. Builds + boots the prod-equivalent stack on
# the Mac (podman, native arm64), runs /api/health + a real WS connect probe,
# tears the stack down, then STOPS the podman VM (it shouldn't idle in the
# background). Intended as the gate you run BEFORE any VPS work — green here ⇒
# promote to the VPS.
#
# Usage: hausverwaltung-validate-local.sh [repo] [nextjs_port] [gw_port]
#   repo defaults to ~/hausverwaltung. Exit 0 = local validate passed.

set -uo pipefail
export PATH="/Users/dan/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"

source /Users/dan/.local/lib/hausverwaltung-validate-local.sh

REPO="${1:-$HOME/hausverwaltung}"
PORT="${2:-3001}"
GW="${3:-18790}"

echo "=========================================="
echo "  Local validate: $(date -Iseconds)"
echo "  repo=$REPO  nextjs=:$PORT  gateway=:$GW"
echo "=========================================="

# Ensure the podman VM is up for the duration; remember if WE started it.
STARTED_VM=0
if ! podman machine inspect --format '{{.State}}' 2>/dev/null | grep -q running; then
    echo "Starting podman machine ..."
    podman machine start 2>&1 | tail -2
    STARTED_VM=1
fi

validate_local "$REPO" "$PORT" "$GW"
RC=$?

echo ""
echo "------------------------------------------"
if [ "$RC" -eq 0 ]; then
    echo "✅ LOCAL VALIDATE PASSED — safe to promote to the VPS."
else
    echo "❌ LOCAL VALIDATE FAILED at stage: ${VL_STAGE}"
fi
echo "$VL_REPORT"
echo "------------------------------------------"

# Don't leave the VM idling in the background.
echo "Stopping podman machine ..."
podman machine stop 2>&1 | tail -1

exit $RC
