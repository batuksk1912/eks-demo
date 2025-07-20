provider "aws" {
  region = var.aws_region
}

################################  VPC  ################################
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.5.0"

  name = "eks-demo-vpc"
  cidr = "10.0.0.0/16"
  azs  = ["us-east-1a", "us-east-1b"]

  private_subnets = ["10.0.1.0/24", "10.0.2.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24"]

  enable_nat_gateway = true
  single_nat_gateway = true
}

################################  EKS  ################################
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "20.8.4"

  cluster_name    = "hiive-demo"
  cluster_version = "1.29"
  vpc_id          = module.vpc.vpc_id
  subnet_ids      = module.vpc.private_subnets

  manage_aws_auth_configmap = true
  aws_auth_roles = [{
    rolearn  = var.aws_role_arn
    username = "github"
    groups   = ["system:masters"]
  }]

  eks_managed_node_groups = {
    spot_small = {
      desired_size   = 1
      max_size       = 2
      instance_types = ["t3.small"]
      capacity_type  = "SPOT"
    }
  }
}

################################  ALB ADD‑ON  #########################
module "addons" {
  source       = "terraform-aws-modules/eks/aws//modules/kubernetes-addons"
  cluster_name = module.eks.cluster_name
  region       = var.aws_region

  addon_config = {
    aws-load-balancer-controller = { most_recent = true }
  }
}

################################  ACM CERT  ###########################
data "aws_acm_certificate" "app_cert" {
  domain   = "app.baturaykayaturk.com"
  statuses = ["ISSUED"]
}

################################  HELM SITE  ##########################
resource "helm_release" "nginx" {
  name       = "demo-site"
  repository = "https://charts.bitnami.com/bitnami"
  chart      = "nginx"
  version    = "15.12.1"

  namespace  = "prod"
  create_namespace = true

  values = [yamlencode({
    replicaCount = 2
    ingress = {
      enabled            = true
      ingressClassName   = "alb"
      hosts              = [ "app.baturaykayaturk.com" ]
      annotations = {
        "alb.ingress.kubernetes.io/scheme"          = "internet-facing"
        "alb.ingress.kubernetes.io/target-type"     = "ip"
        "alb.ingress.kubernetes.io/certificate-arn" = data.aws_acm_certificate.app_cert.arn
        "alb.ingress.kubernetes.io/listen-ports"    = "[{\"HTTPS\":443}]"
      }
    }
  })]
}
