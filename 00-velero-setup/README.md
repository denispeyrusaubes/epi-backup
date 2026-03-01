# 00 — Installation de Velero sur EKS

Mise en place de l'infrastructure AWS (S3 + IAM) et installation de Velero sur un cluster EKS.

## Architecture

```
                ┌──────────────┐
                │   Cluster    │
                │     EKS      │
                │              │
                │  ┌────────┐  │   credentials   ┌──────────┐
                │  │ Velero │──┼─────────────────►│  S3      │
                │  │ Server │  │  (secret k8s)    │  Bucket  │
                │  └────────┘  │                  └──────────┘
                │              │
                └──────────────┘
```

Velero accède au bucket S3 via un **IAM user dédié** dont les credentials sont stockées dans un secret Kubernetes.

## Prérequis

- AWS CLI configuré (profil par défaut)
- Terraform >= 1.0
- `kubectl` configuré avec l'accès au cluster EKS
- Velero CLI installé ([doc officielle](https://velero.io/docs/main/basic-install/#install-the-cli))

## 1. Provisionner l'infrastructure (Terraform)

Terraform utilise le profil AWS par défaut configuré sur votre poste. Il n'accède pas à Kubernetes.

```bash
cd terraform/

# Copier et adapter le fichier de variables
cp terraform.tfvars.example terraform.tfvars
# Éditer terraform.tfvars si nécessaire

# Appliquer
terraform init
terraform plan
terraform apply
```

### Ressources créées

| Ressource | Description |
|-----------|-------------|
| S3 Bucket | Stockage des backups Velero (versionné, chiffré, accès public bloqué) |
| IAM User | Utilisateur dédié pour Velero |
| IAM Access Key | Clés d'accès pour l'utilisateur Velero |
| IAM Policy | Permissions S3 (lecture/écriture bucket) + EC2 (snapshots EBS) |

## 2. Générer le fichier credentials pour Velero

```bash
cd terraform/

# Générer le fichier credentials
terraform output -raw credentials_file_content > /tmp/velero-credentials

# Vérifier le contenu
cat /tmp/velero-credentials
```

## 3. Installer Velero

```bash
BUCKET_NAME=$(cd terraform && terraform output -raw bucket_name)
REGION="eu-west-1"

velero install \
  --provider aws \
  --plugins velero/velero-plugin-for-aws:v1.10.0 \
  --bucket "${BUCKET_NAME}" \
  --backup-location-config region=${REGION} \
  --snapshot-location-config region=${REGION} \
  --secret-file /tmp/velero-credentials
```

## 4. Vérifier l'installation

```bash
# Vérifier que les pods Velero sont running
kubectl get pods -n velero

# Vérifier la connexion au bucket
velero backup-location get

# Créer un backup de test
velero backup create test-install --include-namespaces default
velero backup describe test-install
```

## 5. Nettoyage

```bash
# Supprimer le fichier credentials temporaire
rm -f /tmp/velero-credentials

# Désinstaller Velero du cluster
velero uninstall

# Détruire l'infrastructure AWS
cd terraform/
terraform destroy
```

## Variables Terraform

| Variable | Description | Défaut |
|----------|-------------|--------|
| `region` | Région AWS | `eu-west-1` |
| `bucket_name` | Nom du bucket S3 | `velero-backups` |
| `eks_cluster_name` | Nom du cluster EKS (utilisé pour nommer les ressources IAM) | `epi` |
| `velero_namespace` | Namespace Velero | `velero` |
| `tags` | Tags AWS | `Project=epi-backup` |

## Outputs Terraform

| Output | Description |
|--------|-------------|
| `bucket_name` | Nom du bucket S3 |
| `bucket_arn` | ARN du bucket |
| `velero_access_key_id` | Access Key ID de l'utilisateur Velero |
| `velero_secret_access_key` | Secret Access Key (sensible) |
| `credentials_file_content` | Contenu prêt à écrire dans un fichier pour `--secret-file` |
