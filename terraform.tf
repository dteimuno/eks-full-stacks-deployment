terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.38"
    }
  }
  backend "s3" {
    bucket = "eks-backend-dtm"
    key    = "backend.hcl"
    region = "us-east-1"
  }
}

