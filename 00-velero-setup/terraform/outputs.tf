output "bucket_name" {
  description = "Nom du bucket S3 Velero"
  value       = aws_s3_bucket.velero.id
}

output "bucket_arn" {
  description = "ARN du bucket S3 Velero"
  value       = aws_s3_bucket.velero.arn
}

output "velero_access_key_id" {
  description = "Access Key ID pour Velero"
  value       = aws_iam_access_key.velero.id
}

output "velero_secret_access_key" {
  description = "Secret Access Key pour Velero"
  value       = aws_iam_access_key.velero.secret
  sensitive   = true
}

output "credentials_file_content" {
  description = "Contenu du fichier credentials pour velero install --secret-file"
  sensitive   = true
  value       = <<-EOT
    [default]
    aws_access_key_id=${aws_iam_access_key.velero.id}
    aws_secret_access_key=${aws_iam_access_key.velero.secret}
  EOT
}
