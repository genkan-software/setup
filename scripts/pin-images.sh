#!/usr/bin/env bash
# scripts/pin-images.sh 1.2.0   -> sets every image tag in k8s/base/kustomization.yaml (and docker-compose.prod.yml) to that version
set -euo pipefail
v="${1:?usage: pin-images.sh <version, without the v>}"
cd "$(dirname "$0")/.."
sed -i -E "s|(newTag:).*|\1 $v|" k8s/base/kustomization.yaml
sed -i -E "s|(image: ghcr.io/genkan-software/[a-z]+):.*|\1:$v|" docker-compose.prod.yml
grep -n "newTag\|ghcr.io" k8s/base/kustomization.yaml docker-compose.prod.yml
