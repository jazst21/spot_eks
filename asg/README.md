# ASG — EKS Spot with Managed Node Groups

## Node Group Design

Two managed node groups, separated by capacity type ([AWS best practice](https://docs.aws.amazon.com/eks/latest/best-practices/cas.html) — distinct scheduling properties and interruption behavior).

| Node Group | Capacity | Instance Types | Scheduling Gate |
|---|---|---|---|
| `eks-spot-asg-on-demand` | ON_DEMAND | m5.large | Default (no taint) |
| `eks-spot-asg-spot` | SPOT | 7 m-family types | Taint `spot=true:NoSchedule` |

### Workload Placement

| Workload | Node Group | Mechanism |
|---|---|---|
| productpage | On-Demand | `nodeSelector: ON_DEMAND` |
| details | Spot (preferred) | Toleration + `preferredDuringScheduling` weight 70/30 |
| ratings | Spot (required) | Toleration + `requiredDuringScheduling` SPOT |
| reviews v1/v2/v3 | Spot (preferred) | Toleration + `preferredDuringScheduling` weight 90 |
| Kubecost / Prometheus | On-Demand | `nodeSelector: ON_DEMAND` in Helm values |
| istiod, NTH, CA | On-Demand | No spot toleration → can't land on tainted Spot nodes |

The Spot taint acts as a gate — only workloads with an explicit toleration can schedule there. Everything else (system components, observability, user-facing frontend) naturally lands on On-Demand.

## Deployment Order

### 1. Infrastructure (Terraform)

```bash
cd asg/tf
terraform init
terraform apply
```

Creates: VPC (3-AZ), EKS cluster, On-Demand + Spot node groups, OIDC provider, NTH (SQS + EventBridge), Cluster Autoscaler (Helm + priority expander).

### 2. Configure kubectl

```bash
aws eks update-kubeconfig --name eks-spot-asg --region ap-southeast-3
```

### 3. Install Istio

Run **before** deploying bookinfo — the namespace has `istio-injection: enabled`, so the sidecar injector must be running first.

```bash
./script/install_istio.sh
```

### 4. Deploy Bookinfo App

```bash
kubectl apply -f asg/k8s/namespace.yaml
kubectl apply -f asg/k8s/
```

### 5. Install Kubecost

```bash
./asg/k8s/install_kubecost.sh
```

Access Spot Checklist: Kubecost UI → Settings → Spot Instances → Spot Checklist.
