#!/usr/bin/env bash
# Port-forward all dashboards in background. Ctrl+C to stop all.
set -euo pipefail
trap 'kill 0' EXIT

echo "Starting port-forwards..."
kubectl port-forward -n istio-system svc/kiali 20001:20001 &
kubectl port-forward -n bookinfo svc/productpage 9080:9080 &
kubectl port-forward -n kubecost svc/kubecost-cost-analyzer 9090:9090 &
kubectl port-forward -n bookinfo svc/locust 8089:8089 &
kubectl port-forward -n kube-ops-view svc/kube-ops-view 8082:80 &

echo ""
echo "  Kiali:        http://localhost:20001"
echo "  Productpage:  http://localhost:9080"
echo "  Kubecost:     http://localhost:9090"
echo "  Locust:       http://localhost:8089"
echo "  Kube Ops View: http://localhost:8082"
echo ""
echo "Press Ctrl+C to stop all."
wait
