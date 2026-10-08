

provider "aws" {
  region = var.region
}

locals {
  cluster_name = "my-eks-cluster"
}

# 1. Network Infrastructure (VPC & Subnets)
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~>6.0"

  name = "eks-vpc"
  cidr = "10.0.0.0/16"

  azs             = ["us-east-1a", "us-east-1b"]
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24"]

  enable_nat_gateway = true
  single_nat_gateway = true # Set to false for high-availability production

  public_subnet_tags = {
    "kubernetes.io/role/elb" = "1"
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = "1"
  }
}

# 2. Amazon EKS Cluster & Node Groups
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name    = local.cluster_name
  
  kubernetes_version = "1.33"

  endpoint_public_access           = true
  enable_cluster_creator_admin_permissions = true

  addons={
     coredns={}
     eks-pod-identity-agent={
        before_compute=true
     }
     kube-proxy={}
     vpc-cni={
        before_compute=true
     }
     aws-ebs-csi-driver = {
      before_compute=true
      service_account_role_arn = aws_iam_role.ebs_csi.arn
    }
  }

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  eks_managed_node_groups = {
      myng12 = {
      name = "myEKSMO-ngroup1"
      ami_type="AL2023_x86_64_STANDARD"
      instance_types = ["t3.small"]
    
      min_size     = 1
      max_size     = 3
      desired_size = 2
    }
  }

  
}

# 3. Dynamic Kubernetes & Helm Provider Authentication
data "aws_eks_cluster_auth" "cluster" {
  name = module.eks.cluster_name
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  token                  = data.aws_eks_cluster_auth.cluster.token
}

provider "helm" {
  kubernetes ={
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    token                  = data.aws_eks_cluster_auth.cluster.token
  }
}

# 4. Deploy ArgoCD via Helm
resource "kubernetes_namespace" "argocd" {
  metadata {
    name = "argocd"
  }
}

data "aws_iam_policy_document" "ebs_csi_irsa" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:sub"

      values = [
        "system:serviceaccount:kube-system:ebs-csi-controller-sa"
      ]
    }

    effect = "Allow"
  }
}
resource "aws_iam_role" "ebs_csi" {
  name               = "ebs-csi"
  assume_role_policy = data.aws_iam_policy_document.ebs_csi_irsa.json
}

resource "aws_iam_role_policy_attachment" "AmazonEBSCSIDriverPolicy" {
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
  role       = aws_iam_role.ebs_csi.name
}

resource "helm_release" "argocd" {
  name       = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = "7.7.0" # Use a stable chart version matching your setup
  namespace  = kubernetes_namespace.argocd.metadata[0].name

  # Optional configurations (e.g., expose UI via AWS LoadBalancer)
  # set {
  #   name  = "server.service.type"
  #   value = "LoadBalancer"
  # }
}
