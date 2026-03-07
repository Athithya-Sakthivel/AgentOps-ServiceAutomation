environment  = "staging"
region       = "us-east-1"
cluster_name = "agentops-eks-staging"

vpc_cidr = "10.1.0.0/16"

private_subnet_cidrs = [
  "10.1.32.0/20",
  "10.1.48.0/20"
]

system_nodegroup = {
  instance_type = "t3.small"
  min_size      = 2
  desired_size  = 2
  max_size      = 2
}

inference_nodegroup = {
  instance_type = "m7i-flex.large"
  min_size      = 2
  desired_size  = 2
  max_size      = 6
}