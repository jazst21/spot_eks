# --- Metrics Server (EKS Add-on) ---
# Required for HPA (kubectl top, pod autoscaling)

resource "aws_eks_addon" "metrics_server" {
  cluster_name = aws_eks_cluster.this.name
  addon_name   = "metrics-server"
  configuration_values = jsonencode({
    nodeSelector = { "workload-type" = "system" }
    tolerations = [{
      key      = "workload-type"
      value    = "system"
      effect   = "NoSchedule"
      operator = "Equal"
    }]
  })
  depends_on = [aws_eks_node_group.on_demand]
}
