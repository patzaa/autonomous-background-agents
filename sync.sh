#!/usr/bin/env zsh
# Snapshot the LIVE agent files into this repo for versioning.
# Canonical copies live in ~/.local/bin, ~/.local/lib, ~/Library/LaunchAgents.
set -euo pipefail
cd "$(dirname "$0")"

cp ~/.local/bin/hausverwaltung-*.sh bin/
cp ~/.local/lib/hausverwaltung-*.sh ~/.local/lib/openclaw-approve.cjs lib/
cp ~/Library/LaunchAgents/com.hausverwaltung.*.plist launchagents/

git add -A
if git diff --cached --quiet; then
    echo "No changes."
else
    git status --short
    echo "Staged — commit with: git commit -m 'sync: <what changed>'"
fi
