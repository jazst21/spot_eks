variable "region" {
  default = "ap-southeast-3"
}

variable "cluster_name" {
  default = "eks-spot-karpenter"
}

variable "cluster_version" {
  default = "1.35"
}

variable "vpc_cidr" {
  default = "10.0.0.0/16"
}

variable "karpenter_version" {
  default = "1.1.1"
}
