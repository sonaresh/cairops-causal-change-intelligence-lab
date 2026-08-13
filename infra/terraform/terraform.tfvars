region      = "us-east-1"
project     = "cairops-p6"
environment = "research"
eks_version = "1.35"

# Replace with YOUR public IPv4 /32, for example: ["203.0.113.10/32"]
cluster_endpoint_public_access_cidrs = ["24.210.201.2/32"]

node_instance_types = ["t3.medium"]
node_desired_size   = 2
node_min_size       = 2
node_max_size       = 4
