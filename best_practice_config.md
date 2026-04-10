# AWS EKS Spot Instance Best Practices — With Config Snippets

## Layer 1: AWS (EC2 / Account Level)

### Diversify instance types

The more types you allow, the better EC2 can find capacity and reduce interruption risk.

```hcl
# asg/tf/variables.tf
variable "spot_instance_types" {
  description = "Diversified instance types for Spot node group (same vCPU/memory family)"
  default     = ["m5.large", "m5a.large", "m5d.large", "m5ad.large", "m6i.large", "m6a.large", "m7i.large", "m7i-flex.large"]
}
```

Use [ec2-instance-selector](https://github.com/aws/amazon-ec2-instance-selector) to discover compatible types:

```bash
ec2-instance-selector --vcpus 2 --memory 8 --cpu-architecture x86_64 --region ap-southeast-3
```

Verify availability per-AZ before adding:

```bash
aws ec2 describe-instance-type-offerings \
  --filters "Name=instance-type,Values=m7i.large" \
  --location-type availability-zone \
  --region ap-southeast-3
```

### Use price-capacity-optimized allocation

EKS managed node groups with `capacity_type = "SPOT"` automatically use capacity-optimized allocation.

```hcl
# asg/tf/eks.tf
resource "aws_eks_node_group" "spot" {
  capacity_type  = "SPOT"
  instance_types = var.spot_instance_types
  subnet_ids     = aws_subnet.private[*].id  # 3 AZs
}
```

### Spread across multiple Availability Zones

Independent Spot capacity pools per AZ.

```hcl
# asg/tf/vpc.tf
locals {
  azs = slice(data.aws_availability_zones.available.names, 0, 3)
}

resource "aws_subnet" "private" {
  count             = length(local.azs)
  availability_zone = local.azs[count.index]
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, count.index + 100)
}
```

### EventBridge rules for Spot interruption events

```hcl
# asg/tf/nth.tf
resource "aws_cloudwatch_event_rule" "spot_interruption" {
  name          = "${var.cluster_name}-spot-interruption"
  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    "detail-type" = ["EC2 Spot Instance Interruption Warning"]
  })
}

resource "aws_cloudwatch_event_rule" "rebalance" {
  name          = "${var.cluster_name}-rebalance"
  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    "detail-type" = ["EC2 Instance Rebalance Recommendation"]
  })
}
```

---

## Layer 2: Auto Scaling Groups / EKS Managed Node Groups

### Separate On-Demand and Spot node groups

Use a 3-group pattern: system (infra), on-demand (critical apps), spot (fault-tolerant).

```hcl
# asg/tf/eks.tf — System (cluster infrastructure, tainted)
resource "aws_eks_node_group" "system" {
  capacity_type  = "ON_DEMAND"
  instance_types = ["m5.large"]
  labels         = { "workload-type" = "system" }

  taint {
    key    = "workload-type"
    value  = "system"
    effect = "NO_SCHEDULE"
  }
}

# asg/tf/eks.tf — On-Demand (critical app workloads)
resource "aws_eks_node_group" "on_demand" {
  capacity_type  = "ON_DEMAND"
  instance_types = ["m5.large"]
  labels         = { "workload-type" = "critical" }
}

# asg/tf/eks.tf — Spot (fault-tolerant workloads)
resource "aws_eks_node_group" "spot" {
  capacity_type  = "SPOT"
  instance_types = var.spot_instance_types
  labels         = { "workload-type" = "spot-tolerant" }

  taint {
    key    = "spot"
    value  = "true"
    effect = "NO_SCHEDULE"
  }
}
```

### Cluster Autoscaler with Priority Expander

Prefer Spot node group for scale-up, fall back to On-Demand.

```hcl
# asg/tf/cluster-autoscaler.tf
resource "helm_release" "cluster_autoscaler" {
  name       = "cluster-autoscaler"
  repository = "https://kubernetes.github.io/autoscaler"
  chart      = "cluster-autoscaler"

  set { name = "autoDiscovery.clusterName"; value = var.cluster_name }
  set { name = "awsRegion";                 value = var.region }
  set { name = "image.tag";                 value = "v${var.cluster_version}.0" }
  set { name = "extraArgs.expander";        value = "priority" }
  set { name = "extraArgs.balance-similar-node-groups"; value = "true" }
  set { name = "extraArgs.skip-nodes-with-local-storage"; value = "false" }
}

# Priority ConfigMap — higher number = preferred
resource "kubernetes_config_map" "ca_priority_expander" {
  metadata {
    name      = "cluster-autoscaler-priority-expander"
    namespace = "kube-system"
  }
  data = {
    priorities = yamlencode({
      10 = [".*on-demand.*"]
      50 = [".*spot.*"]
    })
  }
}
```

### AWS Node Termination Handler (Queue Processor mode)

```hcl
# asg/tf/nth.tf
resource "aws_sqs_queue" "nth" {
  name                      = "${var.cluster_name}-nth"
  message_retention_seconds = 300
  sqs_managed_sse_enabled   = true
}

resource "aws_autoscaling_lifecycle_hook" "spot_termination" {
  name                   = "${var.cluster_name}-nth-term-hook"
  autoscaling_group_name = aws_eks_node_group.spot.resources[0].autoscaling_groups[0].name
  lifecycle_transition   = "autoscaling:EC2_INSTANCE_TERMINATING"
  default_result         = "CONTINUE"
  heartbeat_timeout      = 300
}

resource "helm_release" "nth" {
  name       = "aws-node-termination-handler"
  repository = "oci://public.ecr.aws/aws-ec2/helm"
  chart      = "aws-node-termination-handler"
  version    = "0.25.1"

  set { name = "enableSqsTerminationDraining"; value = "true" }
  set { name = "queueURL";                     value = aws_sqs_queue.nth.url }
}
```

---

## Layer 3: Karpenter

### NodePool with Spot capacity and taint

```yaml
# karpenter/tf/karpenter.tf — Spot NodePool
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: spot
spec:
  weight: 50
  template:
    spec:
      requirements:
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["spot"]
        - key: kubernetes.io/arch
          operator: In
          values: ["amd64"]
        - key: node.kubernetes.io/instance-type
          operator: In
          values: ["m5.large", "m5a.large", "m5d.large", "m6i.large", "m6a.large"]
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: default
      taints:
        - key: spot
          value: "true"
          effect: NoSchedule
  limits:
    cpu: "100"
    memory: "200Gi"
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: "60s"
```

### Native interruption handling via SQS

```hcl
# karpenter/tf/karpenter.tf
resource "helm_release" "karpenter" {
  set { name = "settings.interruptionQueue"; value = aws_sqs_queue.karpenter.name }
}
```

Do NOT run NTH alongside Karpenter — Karpenter handles interruptions natively.

### Run controller on dedicated On-Demand nodes

```hcl
# karpenter/tf/karpenter.tf
resource "helm_release" "karpenter" {
  set { name = "nodeSelector.workload-type"; value = "system" }
}
```

---

## Layer 4: Kubernetes (Pod / Workload Level)

### Spot Placement Strategies (Bookinfo Example)

Each microservice demonstrates a different placement strategy:

| Service | Strategy | Scheduling Mechanism | Capacity Mix | Use Case |
|---|---|---|---|---|
| **productpage** | Full On-Demand | `nodeSelector: ON_DEMAND` | ON_DEMAND only | User-facing frontend — can't tolerate interruption |
| **details** | Mixed (prefer Spot) | `preferredDuringScheduling` weight 70 Spot / 30 On-Demand + topology spread on `capacityType` | ON_DEMAND + SPOT | Resilient to interruption, spreads across both capacity types for availability |
| **ratings** | Full Spot (required) | `requiredDuringScheduling` SPOT + Spot toleration | SPOT only | Fully Spot-committed, cheapest, most exposed to interruption |
| **reviews** v1/v2/v3 | Prefer Spot (soft) | `preferredDuringScheduling` weight 90 Spot + Spot toleration | SPOT or ON_DEMAND | Soft preference — falls back to On-Demand if Spot unavailable |

### Tolerations for Spot taint

```yaml
# asg/k8s/ratings.yaml
tolerations:
  - key: spot
    operator: Equal
    value: "true"
    effect: NoSchedule
```

### Node affinity — require Spot

```yaml
# asg/k8s/ratings.yaml
affinity:
  nodeAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      nodeSelectorTerms:
        - matchExpressions:
            - key: eks.amazonaws.com/capacityType
              operator: In
              values: ["SPOT"]
```

### Node affinity — prefer Spot with On-Demand fallback

```yaml
# asg/k8s/details.yaml
affinity:
  nodeAffinity:
    preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 70
        preference:
          matchExpressions:
            - key: eks.amazonaws.com/capacityType
              operator: In
              values: ["SPOT"]
      - weight: 30
        preference:
          matchExpressions:
            - key: eks.amazonaws.com/capacityType
              operator: In
              values: ["ON_DEMAND"]
```

### Node selector — On-Demand only (critical workloads)

```yaml
# asg/k8s/productpage.yaml
nodeSelector:
  eks.amazonaws.com/capacityType: ON_DEMAND
```

### Pod Disruption Budget

Match both `app` and `version` labels for 1:1 PDB-to-Deployment mapping (required for Kubecost Spot Checklist to evaluate correctly).

```yaml
# asg/k8s/reviews.yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: reviews-v1-pdb
spec:
  minAvailable: 1
  selector:
    matchLabels:
      app: reviews
      version: v1
```

### Rolling Update Strategy

Default 25% maxUnavailable fails Kubecost's check with 2 replicas (`floor(2×0.25)=0`, ratio=1.0). Set explicit `maxUnavailable: 1`:

```yaml
# asg/k8s/ratings.yaml
strategy:
  type: RollingUpdate
  rollingUpdate:
    maxUnavailable: 1
```

### Topology spread constraints

Spread replicas across failure domains so a single Spot interruption doesn't take down all replicas. Each service uses a different combination based on its placement strategy:

| Service | Zone | Host | Capacity Type | Instance Type |
|---|---|---|---|---|
| **productpage** | ✅ `DoNotSchedule` | ✅ `ScheduleAnyway` | — | — |
| **details** | ✅ `DoNotSchedule` | ✅ `ScheduleAnyway` | ✅ `DoNotSchedule` | — |
| **ratings** | ✅ `DoNotSchedule` | ✅ `DoNotSchedule` | — | ✅ `ScheduleAnyway` |
| **reviews** v1/v2/v3 | ✅ `DoNotSchedule` | ✅ `ScheduleAnyway` | — | — |

What each `topologyKey` protects against:
- `topology.kubernetes.io/zone` — AZ failure or AZ-wide Spot capacity drain
- `kubernetes.io/hostname` — single node interruption
- `eks.amazonaws.com/capacityType` — ensures replicas on both Spot and On-Demand (details uses this for mixed strategy)
- `node.kubernetes.io/instance-type` — single instance-type Spot pool exhaustion (ratings uses this since it's 100% Spot)

`DoNotSchedule` = hard (won't schedule if can't spread), `ScheduleAnyway` = best-effort.

Full Spot example (ratings — spread across zones, hosts, and instance types):

```yaml
# asg/k8s/ratings.yaml
topologySpreadConstraints:
  - maxSkew: 1
    topologyKey: topology.kubernetes.io/zone
    whenUnsatisfiable: DoNotSchedule
    labelSelector:
      matchLabels:
        app: ratings
  - maxSkew: 1
    topologyKey: kubernetes.io/hostname
    whenUnsatisfiable: DoNotSchedule
    labelSelector:
      matchLabels:
        app: ratings
  - maxSkew: 1
    topologyKey: node.kubernetes.io/instance-type
    whenUnsatisfiable: ScheduleAnyway
    labelSelector:
      matchLabels:
        app: ratings
```

Mixed strategy example (details — spread across Spot and On-Demand capacity types):

```yaml
# asg/k8s/details.yaml
topologySpreadConstraints:
  - maxSkew: 1
    topologyKey: eks.amazonaws.com/capacityType
    whenUnsatisfiable: DoNotSchedule
    labelSelector:
      matchLabels:
        app: details
  - maxSkew: 1
    topologyKey: topology.kubernetes.io/zone
    whenUnsatisfiable: DoNotSchedule
    labelSelector:
      matchLabels:
        app: details
  - maxSkew: 1
    topologyKey: kubernetes.io/hostname
    whenUnsatisfiable: ScheduleAnyway
    labelSelector:
      matchLabels:
        app: details
```

### Resource requests for bin-packing

```yaml
# asg/k8s/ratings.yaml
resources:
  requests:
    cpu: 100m
    memory: 128Mi
  limits:
    memory: 256Mi
```

### HPA for auto-scaling on Spot

When HPA scales pods beyond node capacity, Cluster Autoscaler adds Spot nodes (preferred via priority expander).

```yaml
# asg/k8s/hpa.yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: ratings
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: ratings-v1
  minReplicas: 2
  maxReplicas: 10
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70
```

### Graceful shutdown for Spot workloads

Application code must handle SIGTERM — this is not an infra concern. The `preStop` hook is a safety net for the routing propagation delay.

```yaml
# Add to every Spot-targeted deployment
containers:
  - name: my-app
    lifecycle:
      preStop:
        exec:
          command: ["/bin/sleep", "10"]
          # Delays SIGTERM so Istio/iptables remove pod from routing first
    readinessProbe:
      httpGet:
        path: /health
        port: 8080
      # App should return 503 from /health once SIGTERM received
terminationGracePeriodSeconds: 60
# preStop (10s) + app drain (up to 50s) = 60s total, within 2-min Spot window
```

Application-level SIGTERM handlers (developer responsibility):

```python
# Python
import signal, sys
def shutdown(signum, frame):
    server.stop(grace=10)  # finish in-flight requests
    db.close()
    sys.exit(0)
signal.signal(signal.SIGTERM, shutdown)
```

```javascript
// Node.js
process.on('SIGTERM', () => {
  server.close(() => { process.exit(0); });
});
```

```java
// Java
Runtime.getRuntime().addShutdownHook(new Thread(() -> {
    server.shutdown();
    server.awaitTermination(10, TimeUnit.SECONDS);
}));
```

### Spot Readiness Assessment (Kubecost)

Use [Kubecost Spot Checklist](https://www.ibm.com/docs/en/kubecost/self-hosted/2.x?topic=savings-spot-checklist) or `script/spot_readiness.py` to evaluate workloads:

```bash
# TUI output
python3 script/spot_readiness.py -n bookinfo

# CSV export
python3 script/spot_readiness.py --csv report.csv

# JSON for automation
python3 script/spot_readiness.py --json
```

---

## Observability: Visualizing Spot Spread & Drain Behavior

### kube-ops-view

Use [kube-ops-view](https://codeberg.org/hjacobs/kube-ops-view) to get a real-time visual overview of nodes and pod placement. During FIS Spot interruption tests, it shows pod drain animations, node status changes, and rescheduling across AZs — confirming that topology spread, PDBs, and NTH work as expected.

```bash
# Install
./asg/k8s/install_kube_ops_view.sh

# Access
kubectl port-forward -n kube-ops-view svc/kube-ops-view 8082:80
# Open http://localhost:8082
```

```yaml
# asg/k8s/kube-ops-view.yaml (key resources)
apiVersion: apps/v1
kind: Deployment
metadata:
  name: kube-ops-view
  namespace: kube-ops-view
spec:
  replicas: 1
  template:
    spec:
      serviceAccountName: kube-ops-view
      containers:
        - name: kube-ops-view
          image: hjacobs/kube-ops-view:latest
          ports:
            - containerPort: 8080
---
# ClusterRole grants read-only access to nodes, pods, and metrics
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: kube-ops-view
rules:
  - apiGroups: [""]
    resources: [nodes, pods]
    verbs: [list, get, watch]
  - apiGroups: ["metrics.k8s.io"]
    resources: [nodes, pods]
    verbs: [list, get]
```

**What to watch during an FIS Spot interruption test:**
1. Node turns red/yellow as NTH cordons it
2. Pods animate off the draining node
3. New pods appear on remaining nodes, spread across AZs/hosts per topology constraints
4. PDB ensures at least `minAvailable` pods stay running throughout the drain

---

## Testing: Simulate Spot Interruptions

After all config, readiness checks, and observability are in place, validate end-to-end by simulating Spot interruptions.

### Option 1: AWS Fault Injection Service (FIS)

The official way to test. Sends a real EC2 Spot Interruption Warning with a 2-minute notice, then terminates the instance.

```bash
aws fis create-experiment-template \
  --actions '{"spot-interrupt":{"actionId":"aws:ec2:send-spot-instance-interruptions","parameters":{"durationBeforeInterruption":"PT2M"},"targets":{"SpotInstances":"spot-targets"}}}' \
  --targets '{"spot-targets":{"resourceType":"aws:ec2:spot-instance","selectionMode":"COUNT(1)","resourceTags":{"eks:cluster-name":"eks-spot-asg"}}}'
```

> **Note:** FIS `aws:ec2:send-spot-instance-interruptions` is not available in all regions. If your region doesn't support it, use Option 2.

### Option 2: SQS-based simulation (`simulate_spot_interruption.py`)

Works in any region by injecting EventBridge-format messages directly into the NTH/Karpenter SQS queue. NTH processes them identically to real events — cordons the node, drains pods (respecting PDBs), and the script optionally terminates the instance.

```bash
# Interactive — pick a Spot node from a table, send interruption, watch drain, terminate
python3 script/simulate_spot_interruption.py

# Dry run — send event + watch drain, but don't terminate (auto-uncordons after)
python3 script/simulate_spot_interruption.py --dry-run

# Rebalance recommendation (advisory — NTH cordons+drains but no termination)
python3 script/simulate_spot_interruption.py --event rebalance

# Target a specific node
python3 script/simulate_spot_interruption.py --node-name ip-10-0-101-89.ap-southeast-3.compute.internal

# Check pod spread across nodes/AZs before and after
python3 script/simulate_spot_interruption.py --check-spread
```

Key behaviors:
- Builds an EventBridge-format JSON message (`EC2 Spot Instance Interruption Warning` or `EC2 Instance Rebalance Recommendation`) and sends it to the NTH SQS queue
- Watches the node for cordon + drain progress in real time
- For `--event interruption` (default): terminates the instance after drain, then watches for ASG replacement node
- For `--dry-run`: uncordons the node after drain so it returns to service
- `--check-spread`: shows a table of pod topology spread per deployment (nodes, AZs, capacity mix) — useful before/after comparison

### Test workflow

```bash
# 1. Open kube-ops-view to watch visually
kubectl port-forward -n kube-ops-view svc/kube-ops-view 8082:80 &

# 2. Check current pod spread
python3 script/simulate_spot_interruption.py --check-spread

# 3. Simulate interruption (dry run first)
python3 script/simulate_spot_interruption.py --dry-run

# 4. Full test with termination
python3 script/simulate_spot_interruption.py

# 5. Verify spread recovered
python3 script/simulate_spot_interruption.py --check-spread
```

## References

- [EKS Managed Node Groups](https://docs.aws.amazon.com/eks/latest/userguide/managed-node-groups.html)
- [EKS Best Practices — Cluster Autoscaler](https://docs.aws.amazon.com/eks/latest/best-practices/cas.html)
- [Karpenter Best Practices](https://docs.aws.amazon.com/eks/latest/best-practices/karpenter.html)
- [EC2 Spot Allocation Strategies](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-fleet-allocation-strategy.html)
- [Prepare for Spot Interruptions](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/prepare-for-interruptions.html)
- [AWS Node Termination Handler](https://github.com/aws/aws-node-termination-handler)
- [Cluster Autoscaler Priority Expander](https://github.com/kubernetes/autoscaler/blob/master/cluster-autoscaler/expander/priority/readme.md)
- [Kubecost Spot Checklist](https://www.ibm.com/docs/en/kubecost/self-hosted/2.x?topic=savings-spot-checklist)
- [Configure Container Lifecycle Hooks (AWS Prescriptive Guidance)](https://docs.aws.amazon.com/prescriptive-guidance/latest/ha-resiliency-amazon-eks-apps/lifecycle-hooks.html)
- [Gracefully Shutdown Applications (EKS Best Practices)](https://docs.aws.amazon.com/eks/latest/best-practices/load-balancing.html#_gracefully_shutdown_applications)
- [ec2-instance-selector](https://github.com/aws/amazon-ec2-instance-selector)
- [kube-ops-view](https://codeberg.org/hjacobs/kube-ops-view)
