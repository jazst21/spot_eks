#!/usr/bin/env bash
# Install Istio on EKS using istioctl — run BEFORE deploying bookinfo manifests
set -euo pipefail

ISTIO_VERSION="${1:-1.24.1}"

# Install istioctl if not present
if ! command -v istioctl &>/dev/null; then
  echo "==> Downloading istioctl ${ISTIO_VERSION}"
  curl -fsSL https://istio.io/downloadIstio | ISTIO_VERSION="${ISTIO_VERSION}" sh -
  export PATH="$PWD/istio-${ISTIO_VERSION}/bin:$PATH"
fi

echo "==> Installing Istio (minimal profile — no ingress gateway)"
istioctl install --set profile=minimal \
  --set values.pilot.nodeSelector."workload-type"=system \
  --set values.pilot.tolerations[0].key=workload-type \
  --set values.pilot.tolerations[0].value=system \
  --set values.pilot.tolerations[0].effect=NoSchedule \
  -y

echo "==> Verifying installation"
kubectl -n istio-system wait --for=condition=available deployment/istiod --timeout=120s

echo "==> Installing Istio addons (Kiali, Prometheus)"
kubectl apply -f "$(dirname "$0")/../istio-${ISTIO_VERSION}/samples/addons/prometheus.yaml"
kubectl apply -f "$(dirname "$0")/../istio-${ISTIO_VERSION}/samples/addons/kiali.yaml"

echo "==> Istio ready. Namespaces with 'istio-injection: enabled' will get sidecars."
echo "    Deploy bookinfo:  kubectl apply -f asg/k8s/"
