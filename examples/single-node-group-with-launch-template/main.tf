provider "aws" {
  region = "eu-west-1"
}

#####
# VPC and subnets
#####
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "2.64.0"

  name = "simple-vpc"

  cidr = "10.0.0.0/16"

  azs             = ["eu-west-1a", "eu-west-1b", "eu-west-1c"]
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = "1"
  }

  public_subnet_tags = {
    "kubernetes.io/role/elb" = "1"
  }

  enable_dns_hostnames   = true
  enable_dns_support     = true
  enable_nat_gateway     = true
  enable_vpn_gateway     = true
  single_nat_gateway     = true
  one_nat_gateway_per_az = false

  tags = {
    "kubernetes.io/cluster/eks" = "shared",
    Environment                 = "test"
  }
}

#####
# EKS Cluster
#####

resource "aws_eks_cluster" "cluster" {
  enabled_cluster_log_types = []
  name                      = "eks"
  role_arn                  = aws_iam_role.cluster.arn
  version                   = "1.18"

  vpc_config {
    subnet_ids              = flatten([module.vpc.public_subnets, module.vpc.private_subnets])
    security_group_ids      = []
    endpoint_private_access = "true"
    endpoint_public_access  = "true"
  }
}

resource "aws_iam_role" "cluster" {
  name = "eks-cluster-role"

  assume_role_policy = <<POLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "eks.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
POLICY
}

resource "aws_iam_role_policy_attachment" "cluster_AmazonEKSClusterPolicy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.cluster.name
}

resource "aws_iam_role_policy_attachment" "cluster_AmazonEKSServicePolicy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSServicePolicy"
  role       = aws_iam_role.cluster.name
}

#####
# Launch Template with AMI
#####
data "aws_ssm_parameter" "cluster" {
  name = "/aws/service/eks/optimized-ami/${aws_eks_cluster.cluster.version}/amazon-linux-2/recommended/image_id"
}

data "aws_launch_template" "cluster" {
  name = aws_launch_template.cluster.name

  depends_on = [aws_launch_template.cluster]
}

resource "aws_launch_template" "cluster" {
  image_id               = data.aws_ssm_parameter.cluster.value
  instance_type          = "t3.medium"
  name                   = "eks-launch-template-test"
  update_default_version = true

  key_name = "eks-test"

  block_device_mappings {
    device_name = "/dev/sda1"

    ebs {
      volume_size = 20
    }
  }

  tag_specifications {
    resource_type = "instance"

    tags = {
      Name                        = "eks-node-group-instance-name"
      "kubernetes.io/cluster/eks" = "owned"
    }
  }

  user_data = base64encode(templatefile("userdata.tpl", { CLUSTER_NAME = aws_eks_cluster.cluster.name, B64_CLUSTER_CA = aws_eks_cluster.cluster.certificate_authority[0].data, API_SERVER_URL = aws_eks_cluster.cluster.endpoint }))
}

#####
# EKS Node Group
#####
module "eks-node-group" {
  source = "../../"

  cluster_name = aws_eks_cluster.cluster.id

  subnet_ids = flatten([module.vpc.private_subnets])

  desired_size = 1
  min_size     = 1
  max_size     = 1

  launch_template = {
    id      = data.aws_launch_template.cluster.id
    version = data.aws_launch_template.cluster.latest_version
  }

  kubernetes_labels = {
    lifecycle = "OnDemand"
  }

  tags = {
    "kubernetes.io/cluster/eks" = "owned"
    Environment                 = "test"
  }

  depends_on = [data.aws_launch_template.cluster]
}
