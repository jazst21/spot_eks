# --- NTH Queue Processor Infrastructure ---
# SQS queue + EventBridge rules + ASG lifecycle hook + IAM for IRSA

# SQS Queue

resource "aws_sqs_queue" "nth" {
  name                       = "${var.cluster_name}-nth"
  message_retention_seconds  = 300
  sqs_managed_sse_enabled    = true
  tags                       = { Name = "${var.cluster_name}-nth" }
}

resource "aws_sqs_queue_policy" "nth" {
  queue_url = aws_sqs_queue.nth.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = ["events.amazonaws.com", "sqs.amazonaws.com"] }
      Action    = "sqs:SendMessage"
      Resource  = aws_sqs_queue.nth.arn
    }]
  })
}

# EventBridge Rules — Spot ITN, Rebalance, State Change, ASG Lifecycle, Health

resource "aws_cloudwatch_event_rule" "spot_interruption" {
  name          = "${var.cluster_name}-spot-interruption"
  event_pattern = jsonencode({ source = ["aws.ec2"], "detail-type" = ["EC2 Spot Instance Interruption Warning"] })
}

resource "aws_cloudwatch_event_target" "spot_interruption" {
  rule = aws_cloudwatch_event_rule.spot_interruption.name
  arn  = aws_sqs_queue.nth.arn
}

resource "aws_cloudwatch_event_rule" "rebalance" {
  name          = "${var.cluster_name}-rebalance"
  event_pattern = jsonencode({ source = ["aws.ec2"], "detail-type" = ["EC2 Instance Rebalance Recommendation"] })
}

resource "aws_cloudwatch_event_target" "rebalance" {
  rule = aws_cloudwatch_event_rule.rebalance.name
  arn  = aws_sqs_queue.nth.arn
}

resource "aws_cloudwatch_event_rule" "state_change" {
  name          = "${var.cluster_name}-state-change"
  event_pattern = jsonencode({ source = ["aws.ec2"], "detail-type" = ["EC2 Instance State-change Notification"] })
}

resource "aws_cloudwatch_event_target" "state_change" {
  rule = aws_cloudwatch_event_rule.state_change.name
  arn  = aws_sqs_queue.nth.arn
}

resource "aws_cloudwatch_event_rule" "asg_lifecycle" {
  name          = "${var.cluster_name}-asg-lifecycle"
  event_pattern = jsonencode({ source = ["aws.autoscaling"], "detail-type" = ["EC2 Instance-terminate Lifecycle Action"] })
}

resource "aws_cloudwatch_event_target" "asg_lifecycle" {
  rule = aws_cloudwatch_event_rule.asg_lifecycle.name
  arn  = aws_sqs_queue.nth.arn
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
  arn  = aws_sqs_queue.nth.arn
}

# ASG Termination Lifecycle Hook for Spot node group
# EKS managed node groups always create exactly one ASG.

resource "aws_autoscaling_lifecycle_hook" "spot_termination" {
  name                   = "${var.cluster_name}-nth-term-hook"
  autoscaling_group_name = aws_eks_node_group.spot.resources[0].autoscaling_groups[0].name
  lifecycle_transition   = "autoscaling:EC2_INSTANCE_TERMINATING"
  default_result         = "CONTINUE"
  heartbeat_timeout      = 300
}

# OIDC Provider for IRSA (required by NTH + Cluster Autoscaler)

data "tls_certificate" "eks" {
  url = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks" {
  url             = aws_eks_cluster.this.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks.certificates[0].sha1_fingerprint]
}

# IRSA for NTH

resource "aws_iam_role" "nth" {
  name = "${var.cluster_name}-nth"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.eks.arn }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${replace(aws_eks_cluster.this.identity[0].oidc[0].issuer, "https://", "")}:sub" = "system:serviceaccount:kube-system:aws-node-termination-handler"
          "${replace(aws_eks_cluster.this.identity[0].oidc[0].issuer, "https://", "")}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "nth" {
  name = "${var.cluster_name}-nth"
  role = aws_iam_role.nth.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "autoscaling:CompleteLifecycleAction",
        "autoscaling:DescribeAutoScalingInstances",
        "autoscaling:DescribeTags",
        "ec2:DescribeInstances",
        "sqs:DeleteMessage",
        "sqs:ReceiveMessage",
      ]
      Resource = "*"
    }]
  })
}

# Helm release — NTH Queue Processor mode

resource "helm_release" "nth" {
  name       = "aws-node-termination-handler"
  namespace  = "kube-system"
  repository = "oci://public.ecr.aws/aws-ec2/helm"
  chart      = "aws-node-termination-handler"
  version    = "0.25.1"

  set {
    name  = "enableSqsTerminationDraining"
    value = "true"
  }
  set {
    name  = "queueURL"
    value = aws_sqs_queue.nth.url
  }
  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = aws_iam_role.nth.arn
  }
  set {
    name  = "checkTagBeforeDraining"
    value = "false"
  }
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

  depends_on = [
    aws_eks_node_group.on_demand,
    aws_eks_node_group.spot,
  ]
}
