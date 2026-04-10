# --- CoreDNS (EKS Add-on) ---
# Schedule on system node group for stability

resource "aws_eks_addon" "coredns" {
  cluster_name = aws_eks_cluster.this.name
  addon_name   = "coredns"
  configuration_values = jsonencode({
    nodeSelector = { "workload-type" = "system" }
    tolerations = [{
      key      = "workload-type"
      value    = "system"
      effect   = "NoSchedule"
      operator = "Equal"
    }]
  })
  depends_on = [aws_eks_node_group.system]
}
