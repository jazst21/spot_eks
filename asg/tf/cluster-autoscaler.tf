# --- Cluster Autoscaler ---
# Best practices (https://docs.aws.amazon.com/eks/latest/best-practices/cas.html):
#   - IRSA with least-privilege scoped to this cluster's ASGs
#   - Auto-discovery via cluster tags (EKS MNG sets these automatically)
#   - Priority expander: prefer Spot node group, fall back to On-Demand
#   - balance-similar-node-groups for multi-AZ consistency
#   - skip-nodes-with-local-storage=false for Spot drain compatibility

# IRSA Role

resource "aws_iam_role" "cluster_autoscaler" {
  name = "${var.cluster_name}-cluster-autoscaler"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.eks.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${replace(aws_eks_cluster.this.identity[0].oidc[0].issuer, "https://", "")}:sub" = "system:serviceaccount:kube-system:cluster-autoscaler-aws-cluster-autoscaler"
          "${replace(aws_eks_cluster.this.identity[0].oidc[0].issuer, "https://", "")}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "cluster_autoscaler" {
  name = "${var.cluster_name}-cluster-autoscaler"
  role = aws_iam_role.cluster_autoscaler.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "autoscaling:SetDesiredCapacity",
          "autoscaling:TerminateInstanceInAutoScalingGroup",
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:ResourceTag/k8s.io/cluster-autoscaler/enabled"             = "true"
            "aws:ResourceTag/k8s.io/cluster-autoscaler/${var.cluster_name}" = "owned"
          }
        }
      },
      {
        Effect = "Allow"
        Action = [
          "autoscaling:DescribeAutoScalingGroups",
          "autoscaling:DescribeAutoScalingInstances",
          "autoscaling:DescribeLaunchConfigurations",
          "autoscaling:DescribeScalingActivities",
          "autoscaling:DescribeTags",
          "ec2:DescribeImages",
          "ec2:DescribeInstanceTypes",
          "ec2:DescribeLaunchTemplateVersions",
          "ec2:GetInstanceTypesFromInstanceRequirements",
          "eks:DescribeNodegroup",
        ]
        Resource = "*"
      },
    ]
  })
}

# Helm Release

resource "helm_release" "cluster_autoscaler" {
  name       = "cluster-autoscaler"
  namespace  = "kube-system"
  repository = "https://kubernetes.github.io/autoscaler"
  chart      = "cluster-autoscaler"

  set {
    name  = "autoDiscovery.clusterName"
    value = var.cluster_name
  }
  set {
    name  = "awsRegion"
    value = var.region
  }
  set {
    name  = "image.tag"
    value = "v${var.cluster_version}.0"
  }
  set {
    name  = "rbac.serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = aws_iam_role.cluster_autoscaler.arn
  }

  # Schedule on system nodes
  set {
    name  = "nodeSelector.workload-type"
    value = "system"
  }
  set {
    name  = "tolerations[0].key"
    value = "workload-type"
  }
  set {
    name  = "tolerations[0].value"
    value = "system"
  }
  set {
    name  = "tolerations[0].effect"
    value = "NoSchedule"
  }

  # Best-practice flags
  set {
    name  = "extraArgs.balance-similar-node-groups"
    value = "true"
  }
  set {
    name  = "extraArgs.skip-nodes-with-local-storage"
    value = "false"
  }
  set {
    name  = "extraArgs.expander"
    value = "priority"
  }

  depends_on = [
    aws_eks_node_group.on_demand,
    aws_eks_node_group.spot,
  ]
}

# Priority Expander ConfigMap — prefer Spot, fall back to On-Demand

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
  depends_on = [helm_release.cluster_autoscaler]
}
