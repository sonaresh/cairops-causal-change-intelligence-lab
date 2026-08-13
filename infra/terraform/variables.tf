variable "region" {
  type    = string
  default = "us-east-1"
}

variable "project" {
  type    = string
  default = "cairops-p6"
}

variable "environment" {
  type    = string
  default = "research"
}

variable "eks_version" {
  type    = string
  default = "1.35"
}

variable "cluster_endpoint_public_access_cidrs" {
  type        = list(string)
  description = "Set to your current public IP /32. Do not use 0.0.0.0/0 for this research lab."
}

variable "node_instance_types" {
  type    = list(string)
  default = ["t3.medium"]
}

variable "node_desired_size" {
  type    = number
  default = 2
}

variable "node_min_size" {
  type    = number
  default = 2
}

variable "node_max_size" {
  type    = number
  default = 4
}

variable "evidence_retention_days" {
  type    = number
  default = 365
}
