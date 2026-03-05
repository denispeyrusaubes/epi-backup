# 02 — Kafka Backup/Restore (KRaft)

Test de sauvegarde et restauration des Persistent Volumes d'un cluster Kafka (mode KRaft, sans Zookeeper) via Velero (DataMover).

## Objectif

Valider que les données stockées dans les PV d'un broker Kafka sont correctement sauvegardées et restaurées par Velero. Le test vérifie que les messages produits avant le backup sont toujours disponibles après la restauration.

## Prérequis

- Cluster Kubernetes accessible via `kubectl`
- Helm v3+
- Velero installé et configuré (voir `00-velero-setup/`)

## 1. Déploiement

```bash
helm upgrade -i kafka-test ./chart/kafka-test \
  -n kafka-test --create-namespace \
  --set storageClass="kubernetes-gold-storage-policy"

# Appliquer les Pod Security Standards
kubectl label namespace kafka-test \
  pod-security.kubernetes.io/enforce=baseline \
  pod-security.kubernetes.io/enforce-version=latest \
  pod-security.kubernetes.io/warn=baseline \
  pod-security.kubernetes.io/warn-version=latest \
  pod-security.kubernetes.io/audit=baseline \
  pod-security.kubernetes.io/audit-version=latest \
  --overwrite

# Vérifier que le pod est prêt
kubectl get pods -n kafka-test -w
```

Le démarrage de Kafka prend environ 30-60 secondes (formatage KRaft au premier lancement).

## 2. Insertion des données

```bash
chmod +x scripts/insert-data.sh
./scripts/insert-data.sh
```

Ce script :
- Crée un topic `velero-backup-test`
- Produit 10 messages numérotés avec un timestamp

## 3. Backup Velero

```bash
# Créer le backup via le manifeste
kubectl apply -f velero/backup.yaml

# Suivre l'avancement
velero backup describe kafka-backup
velero backup logs kafka-backup
```

Le fichier `velero/backup.yaml` crée une ressource `Backup` qui sauvegarde le namespace `kafka-test` avec une rétention de 30 jours.

## 4. Simulation de perte

```bash
# Supprimer le namespace pour simuler une perte
kubectl delete namespace kafka-test
```

## 5. Restauration

```bash
# Restaurer le backup
velero restore create kafka-restore --from-backup kafka-backup

# Suivre l'avancement
velero restore describe kafka-restore
velero restore logs kafka-restore

# Attendre que le pod soit prêt (peut prendre 1-2 minutes)
kubectl get pods -n kafka-test -w
```

## 6. Vérification

```bash
chmod +x scripts/verify-data.sh
./scripts/verify-data.sh
```

Le script vérifie :
- L'existence du topic `velero-backup-test`
- La présence de tous les messages produits
- La cohérence individuelle de chaque message

## Paramètres du chart Helm

| Paramètre | Description | Défaut |
|-----------|-------------|--------|
| `namespace` | Namespace de déploiement | `kafka-test` |
| `storageClass` | StorageClass pour les PVC | `""` (défaut du cluster) |
| `kafka.image` | Image Kafka | `apache/kafka` |
| `kafka.tag` | Tag de l'image | `3.7.0` |
| `kafka.clusterId` | ID du cluster KRaft | `MkU3OEVBNTcwNTJENDM2Qk` |
| `persistence.size` | Taille du PV | `2Gi` |

## Notes techniques

- Le broker Kafka fonctionne en mode **KRaft combiné** (rôles `broker` + `controller` sur le même noeud)
- Pas de Zookeeper nécessaire
- Un `initContainer` gère le formatage initial du stockage KRaft
- Le formatage est idempotent : il ne s'exécute que si `meta.properties` n'existe pas encore
