#################### Providers ####################
terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.11"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.31"
    }
    http = {
      source  = "hashicorp/http"
      version = "~> 3.2"
    }
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
  cluster_version = "1.30"
  vpc_id          = module.vpc.vpc_id
  subnet_ids      = module.vpc.private_subnets

  cluster_endpoint_public_access  = true
  cluster_endpoint_private_access = true
  cluster_endpoint_public_access_cidrs = ["0.0.0.0/0"]

  eks_managed_node_groups = {
    spot_small = {
      desired_size   = 1
      max_size       = 2
      instance_types = ["t3.small"]
      capacity_type  = "SPOT"
    }
  }

  enable_cluster_creator_admin_permissions = false

  authentication_mode = "API_AND_CONFIG_MAP"

  access_entries = {
    github_actions = {
      principal_arn     = var.aws_role_arn          # GitHub OIDC role
      kubernetes_groups = ["cluster-admins"]        # ← valid, not reserved
      username          = "github-actions"
    }
  }
}

########################  EKS DESCRIPTOR  ########################
data "aws_eks_cluster" "eks" {
  name = module.eks.cluster_name
  depends_on = [module.eks]
}

data "aws_eks_cluster_auth" "eks" {
  name = module.eks.cluster_name
  depends_on = [module.eks]
}

########################  KUBERNETES PROVIDER  ###################
provider "kubernetes" {
  host                   = data.aws_eks_cluster.eks.endpoint
  cluster_ca_certificate = base64decode(
    data.aws_eks_cluster.eks.certificate_authority[0].data)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token",
      "--cluster-name", module.eks.cluster_name,
      "--region", var.aws_region]
  }
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

# Download official JSON policy from the controller repo
data "http" "lb_ctlr_policy_doc" {
  url = "https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.7.1/docs/install/iam_policy.json"
}

resource "aws_iam_policy" "lb_ctlr" {
  name   = "AWSLoadBalancerControllerIAMPolicy"
  policy = data.http.lb_ctlr_policy_doc.response_body
}

resource "aws_iam_role_policy_attachment" "lb_ctlr_attach" {
  role       = aws_iam_role.lb_ctlr.name
  policy_arn = aws_iam_policy.lb_ctlr.arn
}

resource "kubernetes_cluster_role_binding" "cluster_admins" {
  metadata { name = "cluster-admins" }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "cluster-admin"
  }

  subject {
    kind      = "Group"
    name      = "cluster-admins"
    api_group = "rbac.authorization.k8s.io"
  }
}

#################### Helm – AWS LB Controller #####
provider "helm" {
  kubernetes {
    host                   = data.aws_eks_cluster.eks.endpoint
    cluster_ca_certificate = base64decode(
      data.aws_eks_cluster.eks.certificate_authority[0].data)
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token",
        "--cluster-name", module.eks.cluster_name,
        "--region", var.aws_region]
    }
  }
}

resource "helm_release" "lb_controller" {
  depends_on = [kubernetes_cluster_role_binding.cluster_admins]
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
  depends_on = [kubernetes_cluster_role_binding.cluster_admins]
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
        "alb.ingress.kubernetes.io/listen-ports" = "[{\"HTTP\":80},{\"HTTPS\":443}]"
        "alb.ingress.kubernetes.io/ssl-redirect"  = "443"
      }
    }
  })]
}
