#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="${1:-eks-spot-karpenter}"
REGION="${2:-ap-southeast-3}"
NAMESPACE="kubecost"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "==> Updating kubeconfig for cluster: ${CLUSTER_NAME} in ${REGION}"
aws eks update-kubeconfig --name "${CLUSTER_NAME}" --region "${REGION}"

echo "==> Authenticating Helm to public ECR"
aws ecr-public get-login-password --region us-east-1 | \
  helm registry login --username AWS --password-stdin public.ecr.aws

echo "==> Creating namespace: ${NAMESPACE}"
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

echo "==> Installing Kubecost via Helm"
helm upgrade --install kubecost \
  oci://public.ecr.aws/kubecost/kubecost/cost-analyzer \
  --namespace "${NAMESPACE}" \
  -f "${SCRIPT_DIR}/kubecost-values.yaml" \
  --wait --timeout 5m

echo "==> Kubecost installed. Access dashboard:"
echo "    kubectl port-forward -n ${NAMESPACE} svc/kubecost-cost-analyzer 9090:9090"
echo "    Open http://localhost:9090"
echo "    Spot Checklist: Settings > Spot Instances > Spot Checklist"
