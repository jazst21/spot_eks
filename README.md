# EKS Spot Instances — Best Practices & Implementation

Production-ready reference for running Spot instances on Amazon EKS with managed node groups, including Terraform infrastructure, Kubernetes manifests, and cost visibility tooling.

## Bookinfo Application Architecture

![Bookinfo Architecture](/image/bookinfo-architecture.png)

The sample app consists of 4 polyglot microservices: **productpage** (Python) → **reviews** v1/v2/v3 (Java) → **ratings** (Node.js), and **productpage** → **details** (Ruby). Each service demonstrates a different Spot placement strategy.

## Repository Structure

```
├── notes.md                    # Best practices organized by layer
├── notes.xlsx                  # Same content in spreadsheet format
├── asg/
│   ├── tf/                     # Terraform — VPC, EKS, Spot node groups, NTH
│   │   ├── variables.tf        # Cluster name, region, instance types, scaling
│   │   ├── providers.tf        # AWS + Helm providers
│   │   ├── vpc.tf              # VPC, 3-AZ public/private subnets, NAT
│   │   ├── eks.tf              # EKS cluster, On-Demand + Spot managed node groups
│   │   ├── nth.tf              # Node Termination Handler (SQS, EventBridge, Helm)
│   │   └── outputs.tf          # Cluster endpoint, SQS URL, kubeconfig command
│   └── k8s/                    # Kubernetes manifests — Bookinfo app + Kubecost
│       ├── namespace.yaml      # bookinfo namespace with Istio injection
│       ├── productpage.yaml    # Python frontend (Deployment + Service + PDB)
│       ├── details.yaml        # Ruby book info service
│       ├── ratings.yaml        # Node.js ratings service
│       ├── reviews.yaml        # Java reviews v1/v2/v3
│       ├── kubecost.yaml       # Kubecost namespace + install instructions
│       ├── kubecost-values.yaml# Helm values with Spot cost config
│       └── install_kubecost.sh # One-command Kubecost install script
```

## Best Practices Implemented

Organized across four layers:

| Layer | What | Key Practices |
|-------|------|---------------|
| **AWS** | EC2 / Account | Diversified instance types (7 m-family), multi-AZ, EventBridge, FIS testing |
| **ASG / MNG** | Node groups | Separate On-Demand + Spot groups, NTH Queue Processor, CA priority expander |
| **Karpenter** | Node provisioning | Documented in notes.md (alternative to ASG approach) |
| **Kubernetes** | Pod / Workload | Tolerations, node affinity, PDBs, topology spread, resource requests |

See [notes.md](notes.md) for the full breakdown or [notes.xlsx](notes.xlsx) for the spreadsheet version.

## Quick Start

### Prerequisites

- AWS CLI configured with appropriate permissions
- Terraform >= 1.5
- kubectl
- Helm 3

### 1. Deploy Infrastructure

```bash
cd asg/tf
terraform init
terraform apply
```

This creates:
- VPC with 3-AZ public/private subnets
- EKS cluster (v1.35)
- On-Demand managed node group (critical workloads)
- Spot managed node group (7 diversified instance types, tainted with `spot=true:NoSchedule`)
- AWS Node Termination Handler (Queue Processor mode with SQS + EventBridge)

### 2. Configure kubectl

```bash
aws eks update-kubeconfig --name eks-spot-cluster --region ap-southeast-3
```

### 3. Deploy Bookinfo Sample App

```bash
kubectl apply -f asg/k8s/namespace.yaml
kubectl apply -f asg/k8s/
```

All Bookinfo microservices are configured to:
- Tolerate the Spot node taint
- Prefer Spot nodes via node affinity
- Spread across AZs and nodes via topology constraints
- Maintain availability via PDBs (`minAvailable: 1`)

### 4. Install Kubecost (Spot Readiness Assessment)

```bash
./asg/k8s/install_kubecost.sh
```

Access the Spot Checklist at: **Kubecost UI → Settings → Spot Instances → Spot Checklist**

Kubecost automatically evaluates each workload's Spot readiness based on controller type, replica count, local storage, PDBs, and update strategy.

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
- [Karpenter Best Practices](https://docs.aws.amazon.com/eks/latest/best-practices/karpenter.html)
- [EC2 Spot Allocation Strategies](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-fleet-allocation-strategy.html)
- [Prepare for Spot Interruptions](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/prepare-for-interruptions.html)
- [AWS Node Termination Handler](https://github.com/aws/aws-node-termination-handler)
- [Cluster Autoscaler Priority Expander](https://github.com/kubernetes/autoscaler/blob/master/cluster-autoscaler/expander/priority/readme.md)
- [Kubecost Spot Checklist](https://www.ibm.com/docs/en/kubecost/self-hosted/2.x?topic=savings-spot-checklist)
