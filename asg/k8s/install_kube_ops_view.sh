#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "==> Deploying kube-ops-view"
kubectl apply -f "${SCRIPT_DIR}/kube-ops-view.yaml"

echo "==> Waiting for deployment to be ready"
kubectl rollout status deployment/kube-ops-view -n kube-ops-view --timeout=2m

echo "==> kube-ops-view installed. Access dashboard:"
echo "    kubectl port-forward -n kube-ops-view svc/kube-ops-view 8082:80"
echo "    Open http://localhost:8082"
