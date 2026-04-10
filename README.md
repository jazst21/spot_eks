# EKS Spot Instances — Best Practices & Implementation

Production-ready reference for running Spot instances on Amazon EKS with managed node groups, including Terraform infrastructure, Kubernetes manifests, cost visibility tooling, and interruption simulation.

## Bookinfo Application Architecture

![Bookinfo Architecture](/image/bookinfo-architecture.png)

The sample app consists of 4 polyglot microservices: **productpage** (Python) → **reviews** v1/v2/v3 (Java) → **ratings** (Node.js), and **productpage** → **details** (Ruby). Each service demonstrates a different Spot placement strategy.

## Repository Structure

```
├── best_practice.md            # Best practices organized by layer (summary)
├── best_practice_config.md     # Best practices with config snippets (detailed)
├── asg/
│   ├── tf/                     # Terraform — VPC, EKS, Spot node groups, NTH
│   │   ├── variables.tf        # Cluster name, region, instance types, scaling
│   │   ├── providers.tf        # AWS + Helm providers
│   │   ├── vpc.tf              # VPC, 3-AZ public/private subnets, NAT
│   │   ├── eks.tf              # EKS cluster, System + On-Demand + Spot node groups
│   │   ├── nth.tf              # Node Termination Handler (SQS, EventBridge, Helm)
│   │   ├── cluster-autoscaler.tf # CA with priority expander (prefer Spot)
│   │   ├── coredns.tf          # CoreDNS addon → system node group
│   │   ├── metrics-server.tf   # Metrics Server addon → system node group
│   │   ├── ebs-csi.tf          # EBS CSI driver + gp3 StorageClass → system node group
│   │   └── outputs.tf          # Cluster endpoint, SQS URL, kubeconfig command
│   └── k8s/                    # Kubernetes manifests — Bookinfo app + tooling
│       ├── namespace.yaml      # bookinfo namespace with Istio injection
│       ├── productpage.yaml    # Python frontend (On-Demand, nodeSelector)
│       ├── details.yaml        # Ruby service (mixed Spot/On-Demand, weighted affinity)
│       ├── ratings.yaml        # Node.js service (full Spot, required affinity)
│       ├── reviews.yaml        # Java reviews v1/v2/v3 (prefer Spot, soft affinity)
│       ├── hpa.yaml            # HPA for all services
│       ├── locust.yaml         # Load testing (Locust)
│       ├── app_good/           # Demo app with Spot best practices
│       ├── app_bad/            # Demo app without Spot best practices
│       ├── kube-ops-view.yaml  # Cluster visualization (system node group)
│       ├── kubecost.yaml       # Kubecost namespace
│       ├── kubecost-values.yaml# Helm values with Spot cost config
│       ├── install_kubecost.sh # Kubecost install script
│       ├── install_kube_ops_view.sh # kube-ops-view install script
│       └── port_forward.sh     # Port-forward all dashboards
├── karpenter/                  # Alternative: Karpenter-based setup
│   ├── tf/                     # Terraform for Karpenter
│   └── k8s/                    # K8s manifests for Karpenter
├── script/
│   ├── install_dep.sh          # Install kubectl, helm, gitleaks, trufflehog, pre-commit hooks
│   ├── install_istio.sh        # Install Istio + Kiali + Prometheus (system node group)
│   ├── simulate_spot_interruption.py  # SQS-based Spot interruption simulator
│   ├── spot_readiness.py       # Spot readiness assessment (TUI/CSV/JSON)
│   └── setup_github_repo.sh    # Configure GitHub repo security settings
├── .pre-commit-config.yaml     # gitleaks (commit) + TruffleHog (push) hooks
├── .gitleaks.toml              # Secret scanning rules + allowlist
├── .github/
│   ├── workflows/secrets.yml   # CI secret scanning + weekly history sweep
│   ├── secret-scanning.yml     # GitHub secret scanning path exclusions
│   └── CODEOWNERS              # Require owner approval for all changes
```

## Best Practices Implemented

Organized across four layers + security:

| Layer | What | Key Practices |
|-------|------|---------------|
| **AWS** | EC2 / Account | Diversified instance types (7 m-family), multi-AZ, EventBridge |
| **ASG / MNG** | Node groups | 3-group pattern (system/on-demand/spot), NTH Queue Processor, CA priority expander |
| **Karpenter** | Node provisioning | Documented in best_practice.md (alternative to ASG approach) |
| **Kubernetes** | Pod / Workload | Tolerations, node affinity, PDBs, topology spread, resource requests, graceful shutdown |
| **Observability** | Visualization | kube-ops-view for real-time node/pod placement |
| **Testing** | Interruption sim | FIS + SQS-based simulator for regions without FIS |
| **Security** | Credential protection | gitleaks + TruffleHog pre-commit hooks, GitHub Actions CI, secret scanning |

See [best_practice.md](best_practice.md) for the summary or [best_practice_config.md](best_practice_config.md) for the detailed version with config snippets.

## Quick Start

### Prerequisites

- AWS CLI configured with appropriate permissions
- Terraform >= 1.5

```bash
# Install kubectl, helm, gitleaks, trufflehog, pre-commit hooks
./script/install_dep.sh
```

### 1. Deploy Infrastructure

```bash
cd asg/tf
terraform init
terraform apply
```

This creates:
- VPC with 3-AZ public/private subnets
- EKS cluster (v1.35)
- System node group (On-Demand, tainted — cluster infra)
- On-Demand node group (critical app workloads)
- Spot node group (7 diversified instance types, tainted with `spot=true:NoSchedule`)
- AWS Node Termination Handler (Queue Processor mode with SQS + EventBridge)
- Cluster Autoscaler with priority expander (prefer Spot)
- CoreDNS, metrics-server, EBS CSI → system node group

### 2. Install Istio + Addons

```bash
./script/install_istio.sh
```

Installs istiod, Kiali, Prometheus — all on the system node group.

### 3. Configure kubectl & Deploy App

```bash
aws eks update-kubeconfig --name eks-spot-asg --region ap-southeast-3
kubectl apply -f asg/k8s/namespace.yaml
kubectl apply -f asg/k8s/
```

### 4. Install Observability & Cost Tools

```bash
./asg/k8s/install_kubecost.sh        # Spot readiness assessment
./asg/k8s/install_kube_ops_view.sh   # Real-time cluster visualization
```

### 5. Access Dashboards

```bash
./asg/k8s/port_forward.sh
```

| Dashboard | URL |
|---|---|
| Kiali | http://localhost:20001 |
| Productpage | http://localhost:9080 |
| Kubecost | http://localhost:9090 |
| Locust | http://localhost:8089 |
| kube-ops-view | http://localhost:8082 |

### 6. Test Spot Interruption

```bash
# Check pod spread
python3 script/simulate_spot_interruption.py --check-spread

# Dry run (no termination)
python3 script/simulate_spot_interruption.py --dry-run

# Full test
python3 script/simulate_spot_interruption.py
```

## Node Group Architecture

| Node Group | Type | Taint | Workloads |
|---|---|---|---|
| **system** | ON_DEMAND | `workload-type=system:NoSchedule` | NTH, CA, CoreDNS, metrics-server, EBS CSI, istiod, Kiali, Prometheus, Kubecost, kube-ops-view |
| **on-demand** | ON_DEMAND | — | productpage (critical frontend) |
| **spot** | SPOT | `spot=true:NoSchedule` | details, ratings, reviews, app_good, app_bad |

## Spot Node Group Configuration

| Setting | Value | Why |
|---------|-------|-----|
| `capacity_type` | `SPOT` | Up to 90% savings vs On-Demand |
| `instance_types` | 7 m-family types | Diversification reduces interruption risk |
| Subnets | 3 AZs | Independent Spot capacity pools |
| Taint | `spot=true:NoSchedule` | Only Spot-tolerant workloads scheduled |
| NTH mode | Queue Processor | Handles Spot ITN, rebalance, ASG lifecycle, health events |

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
- [kube-ops-view](https://codeberg.org/hjacobs/kube-ops-view)
- [gitleaks](https://github.com/gitleaks/gitleaks)
- [TruffleHog](https://github.com/trufflesecurity/trufflehog)
