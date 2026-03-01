# 05 — Kafka + Strimzi — Backup/Restore

Test de backup et restauration d'un cluster Kafka déployé via **Strimzi v0.47** en mode **KRaft** avec authentification **SCRAM-SHA-512**.

Ce cas de test reproduit la configuration EPI : Strimzi operator, KafkaNodePool, autorisation simple, et security contexts compatibles Tanzu.

## Architecture déployée

| Composant | Détail |
|-----------|--------|
| Strimzi Operator | v0.47 (installé via Helm) |
| Kafka | 4.0.0, mode KRaft |
| Node Pool | 3 nœuds combinés (controller + broker) |
| Stockage | 5Gi par nœud (PVC) |
| Authentification | SCRAM-SHA-512 sur le listener `sasl` (port 9093) |
| Autorisation | Simple ACL, superUser `admin1` |
| Security Context | `runAsNonRoot`, UID/GID 1001, capabilities drop ALL |

## Prérequis

- Cluster Kubernetes accessible via `kubectl`
- Helm v3+
- Velero installé et configuré (voir `00-velero-setup/`)

## Scénario de test

```
1. Installer Strimzi  ──→  2. Déployer Kafka CR  ──→  3. Insérer données
                                                             │
                                                             ▼
6. Vérifier données   ←──  5. Restaurer Velero   ←──  4. Supprimer namespace
```

## 1. Installation de l'opérateur Strimzi

```bash
# Via le script fourni
chmod +x scripts/install-strimzi.sh
./scripts/install-strimzi.sh

# Ou manuellement :
helm repo add strimzi https://strimzi.io/charts/
helm repo update
helm install strimzi-operator strimzi/strimzi-kafka-operator \
  --namespace strimzi \
  --create-namespace \
  --version 0.47.0 \
  --set watchNamespaces="{strimzi,kafka}" \
  --wait --timeout 120s

# Vérifier que l'opérateur est prêt
kubectl get pods -n strimzi
```

## 2. Déploiement du cluster Kafka

```bash
# Créer le namespace
kubectl apply -f manifests/00-namespace.yaml

# Déployer le node pool puis le cluster
kubectl apply -f manifests/01-kafka-node-pool.yaml
kubectl apply -f manifests/02-kafka-cluster.yaml

# Attendre que le cluster soit prêt (peut prendre 2-3 minutes)
kubectl wait kafka/epi-kafka-cluster --for=condition=Ready --timeout=300s -n kafka

# Vérifier les pods
kubectl get pods -n kafka
# Attendu : 3 pods epi-kafka-cluster-combined-{0,1,2} + entity-operator
```

Pour spécifier une `StorageClass`, modifier le champ `spec.storage.class` dans [manifests/01-kafka-node-pool.yaml](manifests/01-kafka-node-pool.yaml).

### Créer le user et le topic de test

```bash
kubectl apply -f manifests/03-kafka-user.yaml
kubectl apply -f manifests/04-kafka-topic.yaml

# Vérifier que le user et le topic sont prêts
kubectl get kafkauser -n kafka
kubectl get kafkatopic -n kafka
```

## 3. Insertion des données

```bash
chmod +x scripts/insert-data.sh
./scripts/insert-data.sh
```

Le script :
1. Récupère le mot de passe SCRAM-SHA-512 du user `test-user` depuis le secret Kubernetes
2. Configure l'authentification SASL dans le pod broker
3. Produit 10 messages numérotés sur le topic `test-backup`

## 4. Backup Velero

```bash
# Créer le backup du namespace kafka
kubectl apply -f velero/backup.yaml

# Suivre l'avancement
velero backup describe kafka-strimzi-backup
velero backup logs kafka-strimzi-backup
```

Le backup inclut :
- Les PV/PVC des 3 brokers (snapshots EBS)
- Les ressources Strimzi (Kafka, KafkaNodePool, KafkaUser, KafkaTopic)
- Les secrets (dont le mot de passe SCRAM)
- Le ConfigMap, Services, etc.

## 5. Simulation de perte et restauration

```bash
# Supprimer le namespace kafka
kubectl delete namespace kafka

# Attendre la suppression complète
kubectl get namespace kafka  # doit retourner NotFound

# Restaurer le backup complet
velero restore create kafka-strimzi-restore \
  --from-backup kafka-strimzi-backup

# Suivre l'avancement
velero restore describe kafka-strimzi-restore
velero restore logs kafka-strimzi-restore

# Attendre que le cluster Kafka soit de nouveau prêt
kubectl get pods -n kafka -w
```

**Note** : l'opérateur Strimzi (namespace `strimzi`) n'est pas affecté par la suppression du namespace `kafka`. Il détectera les CRs restaurées et reconciliera l'état du cluster.

## 6. Vérification

```bash
chmod +x scripts/verify-data.sh
./scripts/verify-data.sh
```

Le script vérifie que les 10 messages sont toujours présents dans le topic après la restauration.

## Points d'attention

- **Strimzi operator** : doit rester actif pendant le restore. Ne pas inclure le namespace `strimzi` dans le backup/restore, sinon l'opérateur pourrait entrer en conflit avec lui-même
- **KafkaUser secret** : le secret contenant le mot de passe SCRAM est dans le namespace `kafka` et sera restauré avec le backup. Si le secret est perdu, l'opérateur le recréera (mais avec un nouveau mot de passe)
- **StorageClass** : si le cluster cible utilise une StorageClass différente, configurer un [StorageClass mapping](https://velero.io/docs/main/restore-reference/#changing-pvpvc-storage-classes) dans Velero
- **Ordre de réconciliation** : après le restore, Strimzi peut mettre quelques minutes à réconcilier l'état du cluster (rolling restart des pods si nécessaire)
- **Kafka 4.0 + KRaft** : pas de dépendance à ZooKeeper, le quorum est géré par les nœuds controller via le protocole KRaft
