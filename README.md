# Velero Backup/Restore — Cas de tests

Ce dépôt contient les ressources nécessaires pour valider la sauvegarde et la restauration de Persistent Volumes sur un cluster Kubernetes via **Velero** (fonction "DataMover" du Velero déployé sur le superviseur Tanzu).

## Prérequis

- `kubectl` configuré avec un accès au cluster cible
- `helm` v3+
- `terraform` >= 1.0 (pour le setup initial)
- Velero CLI ([installation](https://velero.io/docs/main/basic-install/#install-the-cli))
- Un `StorageClass` disponible sur le cluster

## Structure

| # | Répertoire | Description | Statut |
|---|-----------|-------------|--------|
| 00 | `00-velero-setup/` | Installation Velero sur EKS (Terraform : S3 + IAM user) | Prêt |
| 01 | `01-redis-backup-restore/` | Backup et restore d'un PV Redis | Prêt |
| 02 | `02-kafka-backup-restore/` | Backup et restore des PV d'un cluster Kafka (KRaft, Helm) | Prêt |
| 03 | `03-pra-full-restore/` | PRA : redéploiement complet d'un cluster avec applications et PVs | À définir |
| 04 | `04-partial-restore-pvc/` | Restore partiel : PVC uniquement, redéploiement applicatif via Helm | À tester |
| 05 | `05-kafka-strimzi-backup-restore/` | Backup et restore Kafka via Strimzi v0.47 (KRaft, SCRAM-SHA-512) | À tester |

**Commencer par `00-velero-setup/`** pour provisionner le bucket S3 et installer Velero sur le cluster EKS.

## Utilisation générale

Chaque cas de test suit le même workflow :

1. **Déployer** l'application via son chart Helm ou ses manifests Kubernetes
2. **Insérer des données** via le script `scripts/insert-data.sh`
3. **Créer un backup** Velero (`kubectl apply -f velero/backup.yaml`)
4. **Simuler la perte** (suppression du namespace ou des PVCs)
5. **Restaurer** le backup via Velero CLI
6. **Vérifier** les données restaurées via le script `scripts/verify-data.sh`

Chaque répertoire contient un `README.md` détaillé avec les commandes spécifiques.

## Paramétrage de la StorageClass

Tous les charts Helm acceptent le paramètre `storageClass` pour adapter le déploiement au cluster cible :

```bash
# Exemple avec une StorageClass spécifique
helm install redis-test ./01-redis-backup-restore/chart/redis-test --set storageClass=gp3

# Utiliser la StorageClass par défaut du cluster
helm install redis-test ./01-redis-backup-restore/chart/redis-test
```
