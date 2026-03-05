# 04 — Restore partiel (PVC uniquement)

Test de restauration partielle : seuls les Persistent Volumes (PV/PVC) sont restaurés par Velero. L'application est redéployée manuellement via Helm, simulant un redéploiement CI/CD.

## Objectif

Valider que Velero peut restaurer uniquement les données (PV/PVC) sans restaurer les workloads (StatefulSet, Service, ConfigMap...). Ce scénario est pertinent lorsque :

- L'application est gérée par un pipeline CI/CD (GitOps, ArgoCD, Flux...)
- On veut restaurer les données sur un nouveau cluster sans importer la configuration applicative
- On souhaite mettre à jour la version de l'application tout en conservant les données

## Prérequis

- Cluster Kubernetes accessible via `kubectl`
- Helm v3+
- Velero installé et configuré (voir `00-velero-setup/`)
- Le chart Redis de `01-redis-backup-restore/` est utilisé pour le déploiement

## Scénario de test

```
1. Déployer Redis     ──→  2. Insérer données  ──→  3. BGSAVE + Backup Velero
                                                            │
                                                            ▼
6. Vérifier données   ←──  5. Redéployer Helm  ←──  4. Supprimer namespace
                                (sans données)        (simuler perte totale)
                                    │
                                    ▼
                           Restore partiel Velero
                           (PVC/PV uniquement)
```

**Différence avec le test 01** : ici Velero ne restaure que les PVC/PV. Le StatefulSet, le Service et le namespace sont recréés par Helm, pas par Velero.

## 1. Déploiement

```bash
helm upgrade -i redis-test ../01-redis-backup-restore/chart/redis-test \
  -n redis-test --create-namespace \
  --set storageClass="kubernetes-gold-storage-policy"

# Appliquer les Pod Security Standards
kubectl label namespace redis-test \
  pod-security.kubernetes.io/enforce=baseline \
  pod-security.kubernetes.io/enforce-version=latest \
  pod-security.kubernetes.io/warn=baseline \
  pod-security.kubernetes.io/warn-version=latest \
  pod-security.kubernetes.io/audit=baseline \
  pod-security.kubernetes.io/audit-version=latest \
  --overwrite

# Attendre que le pod soit prêt
kubectl get pods -n redis-test -w
```

## 2. Insertion des données

```bash
chmod +x scripts/insert-data.sh
./scripts/insert-data.sh
```

Le script insère 5 clés dans Redis puis force un `BGSAVE` pour écrire les données sur disque.

## 3. Backup Velero

```bash
# Créer le backup complet du namespace
kubectl apply -f velero/backup.yaml

# Suivre l'avancement
velero backup describe redis-partial-backup
velero backup logs redis-partial-backup
```

Le backup sauvegarde l'intégralité du namespace `redis-test` (ressources + PV snapshots).

## 4. Simulation de perte

```bash
# Supprimer le namespace pour simuler une perte totale
kubectl delete namespace redis-test
```

## 5. Restore partiel + Redéploiement

C'est l'étape clé de ce test : on ne restaure que les PVC et PV.

```bash
# Restaurer UNIQUEMENT les PVC et PV depuis le backup
velero restore create redis-partial-restore \
  --from-backup redis-partial-backup \
  --include-resources persistentvolumeclaims,persistentvolumes \
  --include-namespaces redis-test

# Suivre l'avancement
velero restore describe redis-partial-restore
velero restore logs redis-partial-restore

# Vérifier que les PVC sont restaurés (Bound)
kubectl get pvc -n redis-test
```

Ensuite, redéployer l'application via Helm (simule un pipeline CI/CD) :

```bash
# Redéployer Redis — Helm réutilise le PVC existant
helm upgrade -i redis-test ../01-redis-backup-restore/chart/redis-test \
  -n redis-test --create-namespace \
  --set storageClass="kubernetes-gold-storage-policy"

# Attendre que le pod soit prêt
kubectl get pods -n redis-test -w
```

Le StatefulSet créé par Helm va chercher un PVC nommé `redis-data-redis-test-redis-0`. Comme ce PVC a été restauré par Velero et est déjà `Bound` au PV contenant les données, Redis démarre avec les données intactes.

## 6. Vérification

```bash
chmod +x scripts/verify-data.sh
./scripts/verify-data.sh
```

Le script vérifie que toutes les clés insérées à l'étape 2 sont toujours présentes.

## Détails techniques

### Pourquoi ça fonctionne ?

Le `volumeClaimTemplates` d'un StatefulSet génère des PVC avec un nom déterministe :
```
<volumeClaimTemplate.name>-<statefulset.name>-<ordinal>
→ redis-data-redis-test-redis-0
```

Quand Velero restaure le PVC avec ce nom, puis que Helm recrée le StatefulSet, Kubernetes constate que le PVC existe déjà et le réutilise au lieu d'en créer un nouveau.

### Ordre des opérations

1. `velero restore` : restaure le namespace (s'il n'existe plus), le PV (depuis le snapshot EBS) et le PVC (lié au PV)
2. `helm upgrade -i` : crée le StatefulSet → le StatefulSet trouve le PVC existant → le pod monte le PV avec les données

### Restauration du namespace

L'option `--include-resources` filtre les ressources restaurées, mais Velero restaure automatiquement le namespace s'il n'existe pas (il est nécessaire pour créer les PVC). Si le namespace existe déjà, Velero le réutilise.

## Points d'attention

- Le **nom du release Helm** doit être identique à celui utilisé lors du backup (ici `redis-test`), sinon les noms de PVC ne correspondront pas
- Le `BGSAVE` est indispensable avant le backup : Redis étant in-memory, sans flush sur disque le snapshot PV sera vide
- Si la `StorageClass` du cluster cible diffère, il faudra adapter `--set storageClass=...` lors du `helm upgrade -i` et potentiellement un `ConfigMap` de mapping dans Velero
