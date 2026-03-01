variable "region" {
  description = "Région AWS"
  type        = string
  default     = "eu-west-1"
}

variable "bucket_name" {
  description = "Nom du bucket S3 pour les backups Velero"
  type        = string
  default     = "velero-backups"
}

variable "eks_cluster_name" {
  description = "Nom du cluster EKS"
  type        = string
  default     = "epi"
}

variable "velero_namespace" {
  description = "Namespace Kubernetes dans lequel Velero sera installé"
  type        = string
  default     = "velero"
}

variable "tags" {
  description = "Tags à appliquer aux ressources"
  type        = map(string)
  default = {
    Project   = "epi-backup"
    ManagedBy = "terraform"
  }
}
