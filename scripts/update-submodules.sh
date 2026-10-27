#!/usr/bin/env bash
# Moves every submodule to the latest main, so the next tag of this repo releases those commits.
#   scripts/update-submodules.sh && git commit -am "chore: bump services" && git tag v1.1.0 && git push --follow-tags
set -euo pipefail
cd "$(dirname "$0")/.."
git submodule update --init
git submodule foreach 'git fetch -q origin main && git checkout -q origin/main'
git status --short
