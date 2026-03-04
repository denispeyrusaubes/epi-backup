# 01 — Redis Backup/Restore

Test de sauvegarde et restauration d'un Persistent Volume Redis via Velero.

## Objectif

Valider que les données stockées dans un PV Redis sont correctement sauvegardées et restaurées par Velero.

## Prérequis

- Cluster Kubernetes accessible via `kubectl`
- Helm v3+
- Velero installé et configuré (voir `00-velero-setup/`)

## Point d'attention

Redis stocke ses données en mémoire et les écrit sur disque périodiquement (`dump.rdb`). Le script `insert-data.sh` force un `BGSAVE` après l'insertion pour s'assurer que les données sont bien écrites sur le PV **avant** le snapshot.

## 1. Déploiement

```bash
# Avec la StorageClass par défaut
helm install redis-test ./chart/redis-test

# Avec une StorageClass spécifique
helm install redis-test ./chart/redis-test --set storageClass=gp3

# Vérifier que le pod est prêt
kubectl get pods -n redis-test -w
```

## 2. Insertion des données

```bash
./scripts/insert-data.sh
```

Ce script :
- Insère 5 clés dans Redis avec des valeurs connues
- Force un `BGSAVE` pour écrire les données sur le PV
- Vérifie que le `dump.rdb` est bien présent sur le disque

## 3. Backup Velero

```bash
# Créer le backup via le manifeste
kubectl apply -f velero/backup.yaml

# Suivre l'avancement
velero backup describe redis-backup
velero backup logs redis-backup
```

Le fichier `velero/backup.yaml` crée une ressource `Backup` qui sauvegarde le namespace `redis-test` avec une rétention de 30 jours.

## 4. Simulation de perte

```bash
# Supprimer le namespace pour simuler une perte
kubectl delete namespace redis-test
```

## 5. Restauration

```bash
# Restaurer le backup
velero restore create redis-restore --from-backup redis-backup

# Suivre l'avancement
velero restore describe redis-restore
velero restore logs redis-restore

# Attendre que le pod soit prêt
kubectl get pods -n redis-test -w
```

## 6. Vérification

```bash
./scripts/verify-data.sh
```

Le script vérifie chaque clé et affiche `PASS` ou `FAIL`. Le code de sortie est `0` si toutes les vérifications passent.

## Paramètres du chart Helm

| Paramètre | Description | Défaut |
|-----------|-------------|--------|
| `namespace` | Namespace de déploiement | `redis-test` |
| `storageClass` | StorageClass pour le PVC | `""` (défaut du cluster) |
| `redis.image` | Image Redis | `redis` |
| `redis.tag` | Tag de l'image | `7.2-alpine` |
| `persistence.size` | Taille du PV | `1Gi` |
