#!/usr/bin/env bash
# After cloning genkan-setup: git clone --recurse-submodules ... (or run this)
set -euo pipefail
cd "$(dirname "$0")/.."
git submodule update --init --recursive
git submodule foreach 'git checkout main && git pull --ff-only'
