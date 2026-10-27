#!/usr/bin/env bash
# Deploys Genkan in the right order: namespace -> migrator Job (must complete) -> services.
#   k8s/deploy.sh            services scaled on CPU
#   k8s/deploy.sh --keda     notification scaled on the RabbitMQ queue length (KEDA must be installed)
#
# Prerequisites: the secrets (secrets.example.yaml) and the infrastructure (dev-infra.yaml or your own) already exist.
# Pin the images first: edit "images:" in base/kustomization.yaml (or: cd k8s/base && kustomize edit set image ghcr.io/...=ghcr.io/...:sha-1a2b3c4).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

ns=genkan
target="base"
[ "${1:-}" = "--keda" ] && target="overlays/keda"

rendered="$(mktemp)"
trap 'rm -f "$rendered"' EXIT
kubectl kustomize "$target" > "$rendered"

kubectl apply -f base/namespace.yaml

# 1. database structure. A Job cannot be changed in place, so replace it.
kubectl -n "$ns" delete job migrator --ignore-not-found --wait=true
kubectl apply -f "$rendered" -l app.kubernetes.io/component=migrator
if ! kubectl -n "$ns" wait --for=condition=complete job/migrator --timeout=600s; then
  echo "Migration failed, logs of the migrator:" >&2
  kubectl -n "$ns" logs job/migrator --tail=100 >&2 || true
  exit 1
fi

# 2. everything else
kubectl apply -f "$rendered" -l 'app.kubernetes.io/component!=migrator'
for d in auth lab notification gateway; do
  kubectl -n "$ns" rollout status "deploy/$d" --timeout=300s
done
echo "Deployed."
