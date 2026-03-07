environment            = "prod"
region                 = "ap-south-1"
cluster_name           = "agentops-eks-prod"
vpc_cidr               = "10.0.0.0/19"
private_subnet_cidrs   = ["10.0.0.0/20", "10.0.16.0/20"]
assign_ipv6_cidr_block = true
enable_ipv6            = true
# nodegroups: bump sizes for prod
system_nodegroup = {
  instance_type = "t3.small"
  min_size      = 3
  desired_size  = 3
  max_size      = 3
}
inference_nodegroup = {
  instance_type = "m7i-flex.large"
  min_size      = 2
  desired_size  = 2
  max_size      = 5
}