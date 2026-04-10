# Kubernetes 1.31 → 1.35: Changes Relevant to This Project

## Breaking Changes / Action Required

| Version | Change | Impact | Action |
|---------|--------|--------|--------|
| 1.33 | No AL2 AMI from AWS | EKS won't publish Amazon Linux 2 AMIs | Use AL2023 (already default in our Karpenter `amiSelectorTerms`) |
| 1.33 | Endpoints API deprecated | Returns warnings when accessed | Migrate scripts to EndpointSlices API |
| 1.34 | Containerd updated to 2.1 | Container runtime change | Check containerd 2.1 compatibility after upgrade |
| 1.34 | AppArmor deprecated | Security profile change | Use seccomp or Pod Security Standards instead |
| 1.35 | **cgroup v1 support removed** | Kubelet refuses to start on cgroup v1 nodes | AL2023 uses cgroup v2 by default ✅. Custom cgroup v1 configs must migrate or set `failCgroupV1: false` |
| 1.35 | Containerd 1.x is last supported | Must use containerd 2.0+ for next version | Ensure nodes run containerd 2.x |
| 1.35 | `--pod-infra-container-image` flag removed | Custom AMI bootstrap scripts break | Remove this flag from any custom bootstrap scripts |
| 1.35 | IPVS mode deprecated in kube-proxy | Will be removed in 1.36 | If using IPVS, plan migration to iptables/nftables |
| 1.35 | Ingress NGINX retired upstream | No more security patches | Migrate to Gateway API or alternative ingress controller |

## Improvements Beneficial to Spot Workloads

| Version | Feature | Benefit |
|---------|---------|---------|
| 1.33 | In-Place Pod Resource Resize (Beta) | Adjust CPU/memory on Spot workloads without restarting pods |
| 1.33 | Sidecar Containers (Stable) | Istio sidecars get proper lifecycle support, improving reliability on Spot nodes |
| 1.34 | Pod-level Resource Requests/Limits (Beta) | Simplifies resource management for multi-container pods (app + sidecar), better bin-packing on Spot |
| 1.35 | In-Place Pod Resize (GA) | Production-ready vertical scaling without pod restarts — reduces rescheduling during Spot interruptions |
| 1.35 | Workload Aware Scheduling (Alpha) | Gang scheduling and opportunistic batching — future benefit for batch workloads needing all-or-nothing Spot placement |
| 1.35 | PreferSameNode Traffic Distribution (Stable) | Reduces cross-node traffic when Spot nodes are spread across AZs |
| 1.35 | Extended Toleration Operators (Alpha) | Numeric comparison for tolerations — future potential for granular Spot node selection |
| 1.32 | QueueingHint scheduling optimization | Faster rescheduling when Spot nodes are drained |

## No Breaking Changes

The core features used in this project remain stable across 1.31 → 1.35 with no breaking changes:

- Topology spread constraints
- Pod Disruption Budgets
- Node affinity / nodeSelector
- Tolerations and taints
- Managed node group Spot draining
- Karpenter NodePool / EC2NodeClass CRDs

## References

- [EKS Standard Support Release Notes](https://docs.aws.amazon.com/eks/latest/userguide/kubernetes-versions-standard.html)
- [EKS Extended Support Release Notes](https://docs.aws.amazon.com/eks/latest/userguide/kubernetes-versions-extended.html)
- [Kubernetes 1.35 Release](https://kubernetes.io/blog/2025/12/17/kubernetes-v1-35-release/)
- [Kubernetes 1.34 Release](https://kubernetes.io/blog/2025/08/27/kubernetes-v1-34-release/)
- [Kubernetes 1.33 Release](https://kubernetes.io/blog/2025/04/23/kubernetes-v1-33-release/)
- [Kubernetes 1.32 Release](https://kubernetes.io/blog/2024/12/11/kubernetes-v1-32-release/)
