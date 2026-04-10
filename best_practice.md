# AWS EKS Spot Instance Best Practices

## Layer 1: AWS (EC2 / Account Level)

- Diversify instance types — the more types you allow, the better EC2 can find capacity and reduce interruption risk.
- Use the `price-capacity-optimized` allocation strategy. It picks pools with the highest available capacity and lowest price.
- Use [ec2-instance-selector](https://github.com/aws/amazon-ec2-instance-selector) CLI to discover compatible instance types by vCPU, memory, and architecture.
- Spread instances across multiple Availability Zones to access independent Spot capacity pools.
- Use **EventBridge rules** on `EC2 Spot Instance Interruption Warning` events for custom automation (e.g., checkpointing).
- Create **CloudWatch billing alarms** to alert when compute costs exceed thresholds.

## Layer 2: Auto Scaling Groups / EKS Managed Node Groups

- Set capacity type to `SPOT` when creating managed node groups. EKS automatically follows Spot best practices including:
  - Capacity-optimized allocation strategy.
  - Automatic draining of Spot nodes before interruption.
- Set `CapacityRebalance: true` on the underlying ASG so the drain process runs correctly on Spot interruption or rebalance notifications.
- Provide multiple instance types in the node group config (same vCPU/memory family) to maximize availability.
- Separate node groups by capacity type — use a **3-group pattern**: system (infra), on-demand (critical apps), spot (fault-tolerant).
- Use a dedicated **system node group** (On-Demand, tainted) for cluster infrastructure: NTH, Cluster Autoscaler, CoreDNS, EBS CSI, metrics-server, Istio control plane, kube-ops-view, Kubecost. Taint with `workload-type=system:NoSchedule` to prevent app workloads from consuming system node capacity.
- PDBs are NOT respected during `AZRebalance` events or when reducing desired node count — add lifecycle hooks to the ASG to extend drain time if needed.

### Cluster Autoscaler Priority Expander

When using Cluster Autoscaler (not Karpenter), the [priority expander](https://github.com/kubernetes/autoscaler/blob/master/cluster-autoscaler/expander/priority/readme.md) controls which node group gets scaled up first.

- Configure via `cluster-autoscaler-priority-expander` ConfigMap in `kube-system`. Changes are picked up live — no restart needed.
- Assign higher priority values to Spot node groups so they are preferred over On-Demand for scale-up.
- Can be integrated with external engines (e.g., Spot pricing optimizers) that update the ConfigMap dynamically to reprioritize node groups based on current interruption rates or pricing.
- Add a catch-all regex `.*` at the lowest priority to ensure all node groups remain eligible for scaling.
- Enable with `--expander=priority` flag on the Cluster Autoscaler deployment.

### AWS Node Termination Handler (NTH)

Use NTH when running **self-managed node groups** or ASG-based setups where EKS managed node group draining or Karpenter is not available. NTH cordons and drains nodes before they go down.

- Two modes of operation:
  - **IMDS Processor** (DaemonSet) — polls instance metadata for Spot ITN, scheduled events, rebalance recommendations, and ASG target lifecycle state changes.
  - **Queue Processor** (Deployment) — monitors an SQS queue fed by EventBridge for Spot ITN, rebalance, ASG lifecycle hooks (scale-in, AZ rebalance, unhealthy instances), instance state changes, and AWS Health scheduled events. Supports lifecycle heartbeats for extended drain (up to 48 hours).
- Queue Processor is more capable (supports ASG lifecycle hooks, AZ rebalance, instance state changes, heartbeats) but requires additional infra: SQS queue, EventBridge rules, IAM role, ASG lifecycle hooks, instance tagging.
- Install via Helm from `public.ecr.aws/aws-ec2/helm/aws-node-termination-handler`.
- Supports webhook notifications (e.g., Slack) for shutdown events.
- Exposes Prometheus metrics (`actions`, `events_error`) for monitoring.
- **Choose one**: NTH **or** Karpenter interruption handling — do NOT run both simultaneously.
- If using **EKS managed node groups**, MNG handles Spot interruption and rebalance draining natively — NTH is not strictly required for those events. However, NTH still adds value on MNG as defense-in-depth:
  - ASG lifecycle hooks (extended drain time beyond the default 5 minutes)
  - EC2 scheduled maintenance events
  - AWS Health events
  - Webhook notifications (e.g., Slack alerts on interruption)
  - Prometheus metrics for interruption monitoring

## Layer 3: Karpenter

- Karpenter natively provisions right-sized Spot nodes based on pending pod requirements — no need to pre-define node groups per instance type.
- Enable **interruption handling** via the `--interruption-queue` SQS argument. Karpenter will automatically taint, drain, and replace nodes ahead of interruption.
  - Do NOT run Karpenter interruption handling alongside AWS Node Termination Handler — use one or the other.
- Avoid overly constraining instance types in NodePools. Let Karpenter choose from a broad set for best Spot availability.
- Uses `price-capacity-optimized` by default for Spot to balance cost and interruption risk.
- Run the Karpenter controller on EKS Fargate or a dedicated On-Demand managed node group — never on a Karpenter-managed Spot node.
- Set CPU/memory **limits on NodePools** to cap Spot spend and prevent runaway scaling.
- Use **timers (TTL)** to automatically delete nodes and cycle capacity.
- Create mutually exclusive or weighted NodePools to avoid random scheduling across overlapping pools.

## Layer 4: Kubernetes (Pod / Workload Level)

### Spot Placement Strategies

Each microservice demonstrates a different placement strategy:

| Service | Strategy | Capacity Mix | Use Case |
|---|---|---|---|
| **productpage** | Full On-Demand | ON_DEMAND only | User-facing frontend — can't tolerate interruption |
| **details** | Mixed (prefer Spot) | ON_DEMAND + SPOT | Resilient to interruption, spreads across both capacity types |
| **ratings** | Full Spot (required) | SPOT only | Fully Spot-committed, cheapest, most exposed to interruption |
| **reviews** v1/v2/v3 | Prefer Spot (soft) | SPOT or ON_DEMAND | Soft preference — falls back to On-Demand if Spot unavailable |

### Spot Readiness Assessment (Kubecost)

Before moving workloads to Spot, use [Kubecost Spot Checklist](https://www.ibm.com/docs/en/kubecost/self-hosted/2.x?topic=savings-spot-checklist) to evaluate which workloads are candidates. It automatically checks:

- **Controller type** — Deployments are generally Spot-ready; StatefulSets are not (stateful, risk of data loss).
- **Replica count** — Single-replica workloads are flagged as not Spot-ready (no redundancy if node is reclaimed).
- **Local storage** — Presence of `emptyDir` volumes indicates not Spot-ready (data lost on interruption).
- **Pod Disruption Budget** — If `minAvailable / replicas > 0.5`, flags high availability requirement that may conflict with Spot.
- **Rolling update strategy** — Evaluates max unavailable vs replica count for Deployments.
- **Manual overrides** — Annotate with `spot.kubecost.com/spot-ready=true` to override checks.

### Workload Configuration

- Design workloads to be **fault-tolerant and stateless**. Save state to persistent storage (EBS, S3, EFS) — instance store data is lost on interruption.
- Break work into small, resumable tasks so interrupted work can be retried cheaply.
- Use **taints and tolerations** to isolate Spot nodes (`spot=true:NoSchedule`).
- Use **node affinity** or `nodeSelector` with label `eks.amazonaws.com/capacityType: SPOT` to prefer or require Spot placement.
- Define **Pod Disruption Budgets (PDBs)** for all services on Spot nodes (`minAvailable: 1`).
- Use **topology spread constraints** so a single Spot interruption doesn't take down all replicas.
- Set accurate **resource requests** on all pods for efficient bin-packing and autoscaler decisions.
- Set explicit `maxUnavailable: 1` in rolling update strategy (default 25% fails Kubecost's check with 2 replicas).

### Topology Spread Constraints

Each service uses a different combination based on its placement strategy:

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

### Graceful Shutdown for Spot Workloads

Spot nodes get a 2-minute warning before termination. Your app must shut down cleanly within that window. This is an **application code responsibility** — infra can only provide safety nets.

**Application code must handle SIGTERM:**
- Stop accepting new connections
- Finish in-flight requests (drain)
- Close DB connections, flush buffers, save state
- Exit with code 0

**Readiness probe should fail on SIGTERM** — once the app starts shutting down, return 503 from the readiness endpoint so the load balancer / Envoy stops sending new traffic.

**Infra safety nets (K8s manifest level):**
- `preStop` hook with `sleep 5-10s` — delays SIGTERM so iptables/Envoy have time to remove the pod from routing.
- `terminationGracePeriodSeconds: 60` — gives enough time for preStop + app cleanup. Must be less than the 2-min Spot warning.
- PDB `minAvailable` — ensures not all replicas drain simultaneously.

**Shutdown sequence on Spot interruption:**
```
T+0:00  Spot Interruption Warning event
T+0:01  NTH cordons node
T+0:05  NTH drains pods (respects PDBs)
T+0:05  preStop hook runs (sleep 10s — wait for routing update)
T+0:15  SIGTERM sent to app container
T+0:15  App finishes in-flight requests, closes connections
T+0:20  App exits cleanly
T+2:00  EC2 terminates instance
```

## Observability: Visualizing Spot Spread & Drain Behavior

### kube-ops-view

Use [kube-ops-view](https://codeberg.org/hjacobs/kube-ops-view) to get a real-time visual overview of nodes and pod placement across the cluster. During Spot interruption testing, it shows:

- Which nodes are in each AZ and their Ready/NotReady status
- Pod distribution across nodes — verify topology spread constraints are working
- Pod lifecycle animations — watch pods drain from a cordoned Spot node and reschedule onto surviving nodes
- CPU/memory usage per node and pod via colored fill indicators

Install:
```bash
./asg/k8s/install_kube_ops_view.sh
kubectl port-forward -n kube-ops-view svc/kube-ops-view 8082:80
# Open http://localhost:8082
```

**What to watch during a Spot interruption test:**
1. Node turns red/yellow as NTH cordons it
2. Pods animate off the draining node
3. New pods appear on remaining nodes, spread across AZs/hosts per topology constraints
4. PDB ensures at least `minAvailable` pods stay running throughout the drain

## Testing: Simulate Spot Interruptions

After all config, readiness checks, and observability are in place, validate end-to-end by simulating Spot interruptions.

### Option 1: AWS Fault Injection Service (FIS)

The official way to test. Sends a real EC2 Spot Interruption Warning with a 2-minute notice, then terminates the instance.

> **Note:** FIS `aws:ec2:send-spot-instance-interruptions` is not available in all regions. If your region doesn't support it, use Option 2.

### Option 2: SQS-based simulation (`simulate_spot_interruption.py`)

Works in any region by injecting EventBridge-format messages directly into the NTH/Karpenter SQS queue. NTH processes them identically to real events — cordons the node, drains pods (respecting PDBs), and the script optionally terminates the instance.

```bash
# Interactive — pick a Spot node, send interruption, watch drain, terminate
python3 script/simulate_spot_interruption.py

# Dry run — send event + watch drain, but don't terminate
python3 script/simulate_spot_interruption.py --dry-run

# Rebalance recommendation (advisory — NTH cordons+drains but no termination)
python3 script/simulate_spot_interruption.py --event rebalance

# Check pod spread across nodes/AZs before and after
python3 script/simulate_spot_interruption.py --check-spread
```

### Test workflow

1. Open kube-ops-view to watch visually (`http://localhost:8082`)
2. Check current pod spread with `--check-spread`
3. Dry run first to validate drain without termination
4. Full test with termination — observe ASG replacement node
5. Verify spread recovered with `--check-spread`

## References

- [EKS Managed Node Groups](https://docs.aws.amazon.com/eks/latest/userguide/managed-node-groups.html)
- [EKS Best Practices — Cluster Autoscaler](https://docs.aws.amazon.com/eks/latest/best-practices/cas.html)
- [Karpenter Best Practices](https://docs.aws.amazon.com/eks/latest/best-practices/karpenter.html)
- [EC2 Spot Allocation Strategies](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-fleet-allocation-strategy.html)
- [Prepare for Spot Interruptions](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/prepare-for-interruptions.html)
- [AWS Fault Injection Service](https://docs.aws.amazon.com/fis/latest/userguide/what-is.html)
- [AWS Node Termination Handler](https://github.com/aws/aws-node-termination-handler)
- [Cluster Autoscaler Priority Expander](https://github.com/kubernetes/autoscaler/blob/master/cluster-autoscaler/expander/priority/readme.md)
- [Kubecost Spot Checklist](https://www.ibm.com/docs/en/kubecost/self-hosted/2.x?topic=savings-spot-checklist)
- [Configure Container Lifecycle Hooks (AWS Prescriptive Guidance)](https://docs.aws.amazon.com/prescriptive-guidance/latest/ha-resiliency-amazon-eks-apps/lifecycle-hooks.html)
- [Gracefully Shutdown Applications (EKS Best Practices)](https://docs.aws.amazon.com/eks/latest/best-practices/load-balancing.html#_gracefully_shutdown_applications)
- [ec2-instance-selector](https://github.com/aws/amazon-ec2-instance-selector)
- [kube-ops-view](https://codeberg.org/hjacobs/kube-ops-view)
