# --- Karpenter IAM (IRSA) ---

data "aws_iam_openid_connect_provider" "eks" {
  url = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  oidc_provider     = replace(aws_eks_cluster.this.identity[0].oidc[0].issuer, "https://", "")
  account_id        = data.aws_caller_identity.current.account_id
  partition         = data.aws_partition.current.partition
}

# Controller IRSA role
resource "aws_iam_role" "karpenter_controller" {
  name = "${var.cluster_name}-karpenter-controller"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = { Federated = data.aws_iam_openid_connect_provider.eks.arn }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_provider}:sub" = "system:serviceaccount:kube-system:karpenter"
          "${local.oidc_provider}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "karpenter_controller" {
  name = "${var.cluster_name}-karpenter-controller"
  role = aws_iam_role.karpenter_controller.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ec2:CreateFleet", "ec2:CreateLaunchTemplate", "ec2:CreateTags",
          "ec2:DeleteLaunchTemplate", "ec2:DescribeAvailabilityZones",
          "ec2:DescribeImages", "ec2:DescribeInstances", "ec2:DescribeInstanceTypeOfferings",
          "ec2:DescribeInstanceTypes", "ec2:DescribeLaunchTemplates",
          "ec2:DescribeSecurityGroups", "ec2:DescribeSubnets",
          "ec2:RunInstances", "ec2:TerminateInstances",
          "iam:PassRole", "pricing:GetProducts",
          "ssm:GetParameter",
        ]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["sqs:DeleteMessage", "sqs:GetQueueAttributes", "sqs:GetQueueUrl", "sqs:ReceiveMessage"]
        Resource = aws_sqs_queue.karpenter.arn
      },
      {
        Effect   = "Allow"
        Action   = ["eks:DescribeCluster"]
        Resource = aws_eks_cluster.this.arn
      },
    ]
  })
}

# Node instance profile — Karpenter launches EC2 directly, not via node groups
resource "aws_iam_instance_profile" "karpenter_node" {
  name = "${var.cluster_name}-karpenter-node"
  role = aws_iam_role.node.name
}

# --- SQS for Karpenter native interruption handling ---
# Best practice: use --interruption-queue, do NOT use NTH alongside Karpenter

resource "aws_sqs_queue" "karpenter" {
  name                      = "${var.cluster_name}-karpenter"
  message_retention_seconds = 300
  sqs_managed_sse_enabled   = true
}

resource "aws_sqs_queue_policy" "karpenter" {
  queue_url = aws_sqs_queue.karpenter.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = ["events.amazonaws.com", "sqs.amazonaws.com"] }
      Action    = "sqs:SendMessage"
      Resource  = aws_sqs_queue.karpenter.arn
    }]
  })
}

# EventBridge rules → SQS

resource "aws_cloudwatch_event_rule" "spot_interruption" {
  name          = "${var.cluster_name}-spot-interruption"
  event_pattern = jsonencode({ source = ["aws.ec2"], "detail-type" = ["EC2 Spot Instance Interruption Warning"] })
}
resource "aws_cloudwatch_event_target" "spot_interruption" {
  rule = aws_cloudwatch_event_rule.spot_interruption.name
  arn  = aws_sqs_queue.karpenter.arn
}

resource "aws_cloudwatch_event_rule" "rebalance" {
  name          = "${var.cluster_name}-rebalance"
  event_pattern = jsonencode({ source = ["aws.ec2"], "detail-type" = ["EC2 Instance Rebalance Recommendation"] })
}
resource "aws_cloudwatch_event_target" "rebalance" {
  rule = aws_cloudwatch_event_rule.rebalance.name
  arn  = aws_sqs_queue.karpenter.arn
}

resource "aws_cloudwatch_event_rule" "state_change" {
  name          = "${var.cluster_name}-state-change"
  event_pattern = jsonencode({ source = ["aws.ec2"], "detail-type" = ["EC2 Instance State-change Notification"] })
}
resource "aws_cloudwatch_event_target" "state_change" {
  rule = aws_cloudwatch_event_rule.state_change.name
  arn  = aws_sqs_queue.karpenter.arn
}

resource "aws_cloudwatch_event_rule" "scheduled_change" {
  name = "${var.cluster_name}-scheduled-change"
  event_pattern = jsonencode({
    source        = ["aws.health"]
    "detail-type" = ["AWS Health Event"]
    detail        = { service = ["EC2"], eventTypeCategory = ["scheduledChange"] }
  })
}
resource "aws_cloudwatch_event_target" "scheduled_change" {
  rule = aws_cloudwatch_event_rule.scheduled_change.name
  arn  = aws_sqs_queue.karpenter.arn
}

# --- Karpenter Helm release ---

resource "helm_release" "karpenter" {
  name       = "karpenter"
  namespace  = "kube-system"
  repository = "oci://public.ecr.aws/karpenter"
  chart      = "karpenter"
  version    = var.karpenter_version

  set {
    name  = "settings.clusterName"
    value = var.cluster_name
  }
  set {
    name  = "settings.clusterEndpoint"
    value = aws_eks_cluster.this.endpoint
  }
  set {
    name  = "settings.interruptionQueue"
    value = aws_sqs_queue.karpenter.name
  }
  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = aws_iam_role.karpenter_controller.arn
  }
  # Run controller on system On-Demand nodes, never on Karpenter-managed Spot nodes
  set {
    name  = "nodeSelector.workload-type"
    value = "system"
  }

  depends_on = [aws_eks_node_group.system]
}

# --- Karpenter EC2NodeClass ---

resource "kubectl_manifest" "node_class" {
  yaml_body = yamlencode({
    apiVersion = "karpenter.k8s.aws/v1"
    kind       = "EC2NodeClass"
    metadata   = { name = "default" }
    spec = {
      amiSelectorTerms = [{ alias = "al2023@latest" }]
      role             = aws_iam_role.node.name
      subnetSelectorTerms = [{
        tags = { "karpenter.sh/discovery" = var.cluster_name }
      }]
      securityGroupSelectorTerms = [{
        tags = { "kubernetes.io/cluster/${var.cluster_name}" = "owned" }
      }]
      tags = {
        "karpenter.sh/discovery" = var.cluster_name
      }
    }
  })
  depends_on = [helm_release.karpenter]
}

# --- Spot NodePool ---
# Best practices:
#   - Broad instance types (no overly constraining)
#   - price-capacity-optimized (Karpenter default for Spot)
#   - CPU/memory limits to cap spend
#   - TTL to cycle nodes
#   - Taint to isolate Spot workloads

resource "kubectl_manifest" "spot_nodepool" {
  yaml_body = yamlencode({
    apiVersion = "karpenter.sh/v1"
    kind       = "NodePool"
    metadata   = { name = "spot" }
    spec = {
      weight = 50
      template = {
        metadata = {
          labels = { "workload-type" = "spot-tolerant" }
        }
        spec = {
          requirements = [
            { key = "karpenter.sh/capacity-type", operator = "In", values = ["spot"] },
            { key = "kubernetes.io/arch", operator = "In", values = ["amd64"] },
            { key = "node.kubernetes.io/instance-type", operator = "In", values = [
              "m5.large", "m5a.large", "m5d.large", "m5ad.large",
              "m4.large", "m6i.large", "m6a.large",
              "m5.xlarge", "m5a.xlarge", "m6i.xlarge", "m6a.xlarge",
            ]},
          ]
          nodeClassRef = { group = "karpenter.k8s.aws", kind = "EC2NodeClass", name = "default" }
          taints = [{ key = "spot", value = "true", effect = "NoSchedule" }]
        }
      }
      limits = {
        cpu    = "100"
        memory = "200Gi"
      }
      disruption = {
        consolidationPolicy = "WhenEmptyOrUnderutilized"
        consolidateAfter    = "60s"
      }
    }
  })
  depends_on = [kubectl_manifest.node_class]
}

# --- On-Demand NodePool ---

resource "kubectl_manifest" "on_demand_nodepool" {
  yaml_body = yamlencode({
    apiVersion = "karpenter.sh/v1"
    kind       = "NodePool"
    metadata   = { name = "on-demand" }
    spec = {
      weight = 10
      template = {
        metadata = {
          labels = { "workload-type" = "critical" }
        }
        spec = {
          requirements = [
            { key = "karpenter.sh/capacity-type", operator = "In", values = ["on-demand"] },
            { key = "kubernetes.io/arch", operator = "In", values = ["amd64"] },
            { key = "node.kubernetes.io/instance-type", operator = "In", values = [
              "m5.large", "m5a.large", "m6i.large",
            ]},
          ]
          nodeClassRef = { group = "karpenter.k8s.aws", kind = "EC2NodeClass", name = "default" }
        }
      }
      limits = {
        cpu    = "20"
        memory = "40Gi"
      }
      disruption = {
        consolidationPolicy = "WhenEmptyOrUnderutilized"
        consolidateAfter    = "300s"
      }
    }
  })
  depends_on = [kubectl_manifest.node_class]
}
