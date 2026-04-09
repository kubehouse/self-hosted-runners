terraform {
  required_version = ">= 1.14.8"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.40.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.0.1"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.1.1"
    }
    # alekc/kubectl is the maintained fork of gavinbunney/kubectl
    kubectl = {
      source  = "alekc/kubectl"
      version = "~> 2.2.0"
    }
  }
}
