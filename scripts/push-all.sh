#!/usr/bin/env bash
# One-time: pushes every folder of src/ to its own GitHub repo, then records them as submodules of this repo.
# Needs only git. The six EMPTY repos must exist first (GitHub > New repository, no README/.gitignore/license):
#   shared  gateway  auth  notification  migrator  setup
# HTTPS (default) asks for a token as password; for SSH:  BASE=git@github.com:genkan-software scripts/push-all.sh
set -euo pipefail
BASE="${BASE:-https://github.com/genkan-software}"
cd "$(dirname "$0")/.."

push_repo() {
  local n="$1"
  ( cd "src/$n"
    [ -d .git ] || { git init -q -b main; git add -A; git commit -q -m "chore: initial import (split from notification-microservice)"; }
    # Maps the folder name directly to the repo name without a 'genkan-' prefix
    git remote get-url origin >/dev/null 2>&1 || git remote add origin "$BASE/$n.git"
    git push -u origin main )
}

push_repo shared
( cd src/shared && git tag -f v1.0.0 && git push -f origin v1.0.0 )
echo ">> Wait for the Genkan.Shared 1.0.0 package: shared > Actions (publish workflow green)."
echo ">> Then let the service repos read it: github.com/orgs/genkan-software/packages > Genkan.Shared > Package settings >"
echo "   Manage Actions access (add the 4 service repos), or add a PACKAGES_TOKEN secret (read:packages) to each of them."
read -rp "   Press Enter when done... "

for n in gateway auth notification migrator; do push_repo "$n"; done

[ -d .git ] || git init -q -b main
for n in shared gateway auth notification migrator; do
  git update-index --add --cacheinfo "160000,$(git -C "src/$n" rev-parse HEAD),src/$n"
done
git add -A
git commit -q -m "chore: setup repo with service submodules" || true
# Point setup repo to setup.git
git remote get-url origin >/dev/null 2>&1 || git remote add origin "$BASE/setup.git"
git push -u origin main
echo "Done. Add the RELEASE_TOKEN secret to setup, then: git tag v1.0.0 && git push --tags"