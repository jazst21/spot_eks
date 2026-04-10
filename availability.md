# Maintaining Workload Availability on Spot Instances

This project uses multiple layered strategies to keep services available despite Spot interruptions. No single mechanism is sufficient — they work together.

## 1. Diversified Instance Types

The Spot node group uses 7 instance types from the same family (`m5.large`, `m5a.large`, `m5d.large`, `m5ad.large`, `m4.large`, `m6i.large`, `m6a.large`). Each type draws from a separate Spot capacity pool. When one type is reclaimed, others remain available.

**Where:** `asg/tf/eks.tf` — `instance_types` on the Spot node group.

## 2. Multi-AZ Spread

Nodes are provisioned across 3 Availability Zones. Spot capacity pools are independent per AZ, so a shortage in one zone doesn't affect the others.

**Where:** `asg/tf/vpc.tf` — private subnets in 3 AZs.

## 3. Topology Spread Constraints

Pods are distributed across failure domains so a single interruption can't take down all replicas.

| Service | Spread across zones | Spread across hosts | Spread across capacity types | Spread across instance types |
|---------|:---:|:---:|:---:|:---:|
| productpage (On-Demand) | ✅ hard | ✅ soft | — | — |
| details (mixed) | ✅ hard | ✅ soft | ✅ hard | — |
| ratings (full Spot) | ✅ hard | ✅ hard | — | ✅ soft |
| reviews (Spot-preferred) | ✅ hard | ✅ soft | — | — |

The `details` service spreads across `eks.amazonaws.com/capacityType`, guaranteeing replicas on both Spot and On-Demand nodes. The `ratings` service spreads across `node.kubernetes.io/instance-type` so replicas land on different Spot instance types.

**Where:** `asg/k8s/*.yaml` — `topologySpreadConstraints` in each Deployment.

## 4. Mixed Spot / On-Demand Placement

Not all services run the same way:

| Service | Placement | Why |
|---------|-----------|-----|
| productpage | On-Demand only | User-facing frontend — zero interruption tolerance |
| details | Mixed (Spot + On-Demand) | At least 1 replica always on stable On-Demand node |
| ratings | Spot only | Stateless, high replica count, spread across instance types |
| reviews | Spot-preferred | Tolerates Spot, falls back to On-Demand if needed |

This is achieved through combinations of `nodeSelector`, `requiredDuringScheduling`, `preferredDuringScheduling`, and Spot tolerations.

**Where:** `asg/k8s/productpage.yaml`, `details.yaml`, `ratings.yaml`, `reviews.yaml`.

## 5. Pod Disruption Budgets (PDBs)

Every service has a PDB with `minAvailable: 1`. When a Spot node is drained (by NTH or EKS managed node group draining), the Kubernetes API will not evict the last running pod until a replacement is scheduled elsewhere.

**Where:** `asg/k8s/*.yaml` — `PodDisruptionBudget` resource per service.

## 6. Node Termination Handler (NTH)

NTH Queue Processor monitors SQS for Spot interruption warnings, rebalance recommendations, and ASG lifecycle events. When it detects an upcoming interruption, it cordons and drains the node *before* the instance is reclaimed, giving pods time to reschedule.

**Where:** `asg/tf/nth.tf` — SQS queue, EventBridge rules, ASG lifecycle hook, Helm release.

## 7. Multiple Replicas

All services run 2–3 replicas minimum. Combined with topology spread, this ensures that losing one node (or one AZ, or one instance type) still leaves healthy replicas serving traffic.

## How They Work Together

```
Spot interruption detected
        │
        ▼
   NTH cordons + drains node          ← Layer: NTH
        │
        ▼
   PDB ensures min pods stay up       ← Layer: PDB
        │
        ▼
   Pod rescheduled to another node     ← Layer: Topology spread
        │                                        ensures targets
        ▼                                        exist in other
   Other AZs / instance types /                  AZs, hosts,
   On-Demand nodes still have                    capacity types
   healthy replicas                    ← Layer: Diversification
```

No single layer prevents downtime alone. The combination of early warning (NTH), controlled eviction (PDB), pre-distributed replicas (topology spread), and infrastructure diversity (multi-AZ, multi-instance-type, mixed capacity) is what maintains availability.
