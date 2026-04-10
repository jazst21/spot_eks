# Karpenter — EKS Spot with NodePools

## Karpenter vs ASG for Spot

| Aspect | ASG (Managed Node Groups) | Karpenter |
|---|---|---|
| **Instance selection** | Fixed list per node group (9 types in our ASG config) | Automatic — picks from all compatible types per NodePool constraints, maximizing Spot pool diversity |
| **Right-sizing** | One instance size per group; over-provisions if pods are small | Bin-packs pods and launches the smallest instance that fits, reducing waste |
| **Spot interruption** | Requires NTH (separate SQS + EventBridge + Helm chart) | Native `--interruption-queue` built in — no extra component |
| **Scaling speed** | CA polls every 10s, then ASG launches; 2+ min typical | Direct EC2 fleet API call on pending pod; ~30s to node ready |
| **Consolidation** | CA only removes underutilized nodes | Actively replaces nodes — moves pods to cheaper/smaller instances and deletes empty nodes |
| **Node groups to manage** | Must pre-create separate On-Demand + Spot groups | Zero node groups — NodePools are declarative intent, Karpenter creates/destroys nodes dynamically |
| **Spot fallback** | Priority expander ConfigMap (regex-based) | Built-in — if Spot unavailable, falls back to on-demand per NodePool `capacity-type` list |
| **Multi-arch / GPU** | Separate node group per arch/GPU | Single NodePool with requirements, Karpenter picks the right instance |

**Bottom line**: Karpenter is better for Spot because it sees the full instance type catalog, reacts faster to interruptions, and consolidates aggressively — all without managing ASGs.

## Node Pool Design

Two NodePools (logical, not pre-provisioned infrastructure) plus one small MNG for the Karpenter controller itself.

| Resource | Type | Purpose |
|---|---|---|
| `eks-spot-karpenter-system` | MNG (On-Demand, m5.large × 2) | Karpenter controller, istiod, system components — never managed by Karpenter |
| `spot` NodePool | Karpenter (Spot) | Fault-tolerant workloads, tainted `spot=true:NoSchedule`, 11 instance types, consolidates aggressively |
| `on-demand` NodePool | Karpenter (On-Demand) | Critical workloads, no taint, 3 instance types, conservative consolidation |

### Workload Placement

| Workload | NodePool | Mechanism |
|---|---|---|
| productpage | on-demand | `nodeSelector: karpenter.sh/capacity-type: on-demand` |
| details | Spot + On-Demand (spread) | Toleration + `topologySpreadConstraint` on `karpenter.sh/capacity-type` |
| ratings | Spot (required) | Toleration + `requiredDuringScheduling` spot |
| reviews v1/v2/v3 | Spot (preferred) | Toleration + `preferredDuringScheduling` spot |
| Kubecost / Prometheus | on-demand | `nodeSelector: on-demand` in Helm values |
| Karpenter controller | system MNG | `nodeSelector: workload-type: system` — must not run on nodes it manages |

## Deployment Order

### 1. Infrastructure (Terraform)

```bash
cd karpenter/tf
terraform init
terraform apply
```

Creates: VPC (3-AZ), EKS cluster, system MNG, Karpenter (Helm + IRSA + SQS interruption queue), EC2NodeClass, Spot + On-Demand NodePools.

### 2. Configure kubectl

```bash
aws eks update-kubeconfig --name eks-spot-karpenter --region ap-southeast-3
```

### 3. Install Istio

```bash
./script/install_istio.sh
```

### 4. Deploy Bookinfo App

```bash
kubectl apply -f karpenter/k8s/namespace.yaml
kubectl apply -f karpenter/k8s/
```

Karpenter will automatically provision Spot and On-Demand nodes as pods become pending.

### 5. Install Kubecost

```bash
./karpenter/k8s/install_kubecost.sh
```

Access Spot Checklist: Kubecost UI → Settings → Spot Instances → Spot Checklist.
