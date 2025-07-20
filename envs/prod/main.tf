#################### Providers ####################
terraform {
  required_version = ">= 1.5"
  required_providers {
    aws    = "~> 5.0"
    helm   = "~> 2.11"
    kubernetes = "~> 2.31"
  }
}

provider "aws" {
  region = var.aws_region
}

################################  VPC  ################################
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.5.0"

  name = "eks-demo-vpc"
  cidr = "10.0.0.0/16"
  azs  = ["ca-central-1a", "ca-central-1b"]

  private_subnets = ["10.0.1.0/24", "10.0.2.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24"]

  enable_nat_gateway = true
  single_nat_gateway = true
  enable_dns_hostnames = true
}

################################  EKS  ################################
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "20.37.2"

  cluster_name    = "hiive-eks-demo"
  cluster_version = "1.29"
  vpc_id          = module.vpc.vpc_id
  subnet_ids      = module.vpc.private_subnets

  eks_managed_node_groups = {
    spot_small = {
      desired_size   = 1
      max_size       = 2
      instance_types = ["t3.small"]
      capacity_type  = "SPOT"
    }
  }
}

############## AWS‑AUTH CONFIGMAP ############
module "aws_auth" {
  source  = "terraform-aws-modules/eks/aws//modules/aws-auth"
  version = "20.37.2"

  cluster_name = module.eks.cluster_name

  aws_auth_roles = [
    {
      rolearn  = var.aws_role_arn
      username = "github"
      groups   = ["system:masters"]
    }
  ]
}

################ IAM for LB Controller ############
data "aws_iam_policy_document" "lb_ctlr_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:sub"
      values   = ["system:serviceaccount:kube-system:aws-load-balancer-controller"]
    }
  }
}

resource "aws_iam_role" "lb_ctlr" {
  name               = "AWSLoadBalancerControllerRole"
  assume_role_policy = data.aws_iam_policy_document.lb_ctlr_assume.json
}

resource "aws_iam_role_policy_attachment" "lb_ctlr_attach" {
  role       = aws_iam_role.lb_ctlr.name
  policy_arn = "arn:aws:iam::aws:policy/AWSLoadBalancerControllerIAMPolicy"
}

#################### Helm – AWS LB Controller #####
provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    token                  = module.eks.cluster_token
  }
}

resource "helm_release" "lb_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  namespace  = "kube-system"
  version    = "1.7.1"

  set {
    name  = "clusterName"
    value = module.eks.cluster_name
  }

  set {
    name  = "serviceAccount.create"
    value = "true"
  }

  set {
    name  = "serviceAccount.name"
    value = "aws-load-balancer-controller"
  }

  set {
    name  = "region"
    value = var.aws_region
  }

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = aws_iam_role.lb_ctlr.arn
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
