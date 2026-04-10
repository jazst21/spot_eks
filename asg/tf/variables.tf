variable "region" {
  default = "ap-southeast-3"
}

variable "cluster_name" {
  default = "eks-spot-asg"
}

variable "cluster_version" {
  default = "1.35"
}

variable "vpc_cidr" {
  default = "10.0.0.0/16"
}

variable "spot_instance_types" {
  description = "Diversified instance types for Spot node group (same vCPU/memory family)"
  default     = ["m5.large", "m5a.large", "m5d.large", "m5ad.large", "m6i.large", "m6a.large", "m7i.large", "m7i-flex.large"]
}

variable "on_demand_instance_types" {
  default = ["m5.large"]
}

variable "spot_desired_size" {
  default = 2
}

variable "spot_min_size" {
  default = 2
}

variable "spot_max_size" {
  default = 10
}

variable "on_demand_desired_size" {
  default = 2
}
