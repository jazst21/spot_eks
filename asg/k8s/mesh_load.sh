#!/usr/bin/env bash
# Generate sustained load from inside the mesh so Kiali sees traffic
set -euo pipefail
RATE="${1:-5}"  # requests per second
echo "Sending ~${RATE} req/s from inside the mesh. Ctrl+C to stop."
kubectl run loadgen --rm -i --restart=Never -n bookinfo \
  --image=busybox -- sh -c "
while true; do
  wget -q -O /dev/null http://productpage:9080/productpage
  sleep \$(echo \"scale=2; 1/$RATE\" | bc -l 2>/dev/null || echo 0.2)
done
"
