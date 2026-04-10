# Spot Readiness — Kubecost Checklist Results

## What the Checklist Evaluates

Kubecost's Spot Checklist (Savings → Insights → Spot) runs 6 checks per workload:

| # | Check | Pass Condition |
|---|---|---|
| 1 | Controller Type | Deployment (not StatefulSet) |
| 2 | Replica Count | > 1 |
| 3 | Local Storage | No emptyDir volumes |
| 4 | Controller PDB | minAvailable/replicas ≤ 0.5 |
| 5 | Rolling Update Strategy | minAvailable/replicas ≤ 0.9 |
| 6 | Annotation Override | `spot.kubecost.com/spot-ready=true` forces pass |

## Issue: Rolling Update Failing on 2-Replica Deployments

Default RollingUpdate strategy uses 25% maxUnavailable. With 2 replicas:

```
floor(2 × 0.25) = 0  →  maxUnavailable = 0
minAvailable = 2 - 0 = 2
ratio = 2/2 = 1.0  →  FAIL (threshold is 0.9)
```

### Fix

Added explicit `maxUnavailable: 1` to all Spot workload deployments:

```yaml
strategy:
  type: RollingUpdate
  rollingUpdate:
    maxUnavailable: 1
```

This gives ratio = 1/2 = 0.5, well under the 0.9 threshold.

Files changed: `details.yaml`, `ratings.yaml`, `reviews.yaml`

## Final Results

### ✅ Spot Ready (bookinfo workloads)

| Workload | All Checks Pass | Notes |
|---|---|---|
| reviews-v1 | ✅ | Spot preferred (weight 90) |
| reviews-v2 | ✅ | Spot preferred (weight 90) |
| reviews-v3 | ✅ | Spot preferred (weight 90) |
| details-v1 | ✅ | Spot preferred (weight 70/30 mixed) |
| ratings-v1 | ✅ | Spot required |

### ❓ / 🔴 Not Spot Ready (by design)

| Workload | Reason | Intentional? |
|---|---|---|
| productpage-v1 | Rolling Update 2/2 (no maxUnavailable set) | ✅ Yes — user-facing, runs on On-Demand |
| cluster-autoscaler | 1 replica | ✅ Yes — uses leader election, critical system component |
| kiali | 1 replica | ✅ Yes — observability, not business-critical |
| kubecost-prometheus | 1 replica + local storage | ✅ Yes — stateful metrics store |
| ebs-csi-controller | Local storage (socket) | ✅ Yes — system component on On-Demand |
| metrics-server | Local storage | ✅ Yes — system component on On-Demand |

This is the correct outcome: fault-tolerant microservices are Spot-ready, critical infrastructure stays on On-Demand.
