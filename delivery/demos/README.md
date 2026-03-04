# Démonstrations Velero + Kopia VGDP

Scénarios de test validant le backup et la restauration avec Velero en mode VGDP
sur un cluster Tanzu/vSphere avec MinIO.

Chaque démo est autonome et suit le même cycle :
**déploiement → insertion de données → backup → destruction → restauration → vérification**

---

## Prérequis

- Velero installé et opérationnel (voir `../install/`)
- BSL `default` en phase `Available`
- CLI `velero` disponible (optionnel, `kubectl` suffit)

---

## Démos disponibles

| # | Répertoire | Scénario | Technologie |
|---|-----------|----------|-------------|
| 01 | `01-redis-backup-restore` | Backup/restore complet | Redis (StatefulSet + PVC) |
| 02 | `02-kafka-backup-restore` | Backup/restore cluster | Kafka KRaft (3 brokers, sans Zookeeper) |
| 03 | `03-partial-restore-pvc` | Restauration sélective PVC | Redis — restore PVC uniquement, redéploiement app via Helm |
| 04 | `04-kafka-strimzi-backup-restore` | Backup/restore opérateur | Kafka Strimzi (KRaft + SCRAM-SHA-512) |

---

## 01 — Redis backup/restore

Valide le cycle complet de sauvegarde et restauration d'un Redis déployé en StatefulSet.

- Déploiement Redis 7.2 via Helm (StatefulSet + PVC 1Gi)
- Insertion de 5 clés de test + `BGSAVE` (flush mémoire → disque)
- Backup Velero du namespace complet (rétention 30 jours)
- Suppression du namespace (simulation de perte)
- Restauration complète
- Vérification des 5 clés et de leurs valeurs

**Point technique** : Redis stocke les données en mémoire — le `BGSAVE` est indispensable
avant le snapshot pour garantir la persistance sur le PV.

---

## 02 — Kafka KRaft backup/restore

Valide le backup et la restauration d'un cluster Kafka 3.7 en mode KRaft (sans Zookeeper).

- Déploiement de 3 brokers Kafka en mode combiné (broker + controller)
- Création d'un topic `velero-backup-test` (3 partitions, RF=3)
- Production de 10 messages numérotés avec timestamps
- Backup Velero du namespace complet
- Suppression du namespace
- Restauration et vérification des 10 messages

**Point technique** : en mode KRaft, les métadonnées du cluster sont stockées dans les PVs
des brokers eux-mêmes. La restauration des PVs reconstruit à la fois les données et les métadonnées.

---

## 03 — Restauration sélective PVC (partielle)

Valide un scénario réaliste de disaster recovery où seules les données (PVC/PV) sont
restaurées par Velero, et l'application est redéployée séparément via Helm (ou CI/CD).

- Déploiement Redis + insertion de données (identique à la démo 01)
- Backup Velero complet
- Suppression du namespace
- **Restauration sélective** : uniquement les PVC et PV (`--include-resources persistentvolumeclaims,persistentvolumes`)
- Redéploiement de Redis via Helm
- Vérification que Redis retrouve ses données

**Point technique** : le StatefulSet utilise des noms de PVC déterministes
(`redis-data-redis-test-redis-0`). Quand Helm redéploie, Kubernetes détecte le PVC
existant et le réutilise au lieu d'en créer un nouveau.

---

## 04 — Kafka Strimzi backup/restore

Valide le backup et la restauration d'un cluster Kafka géré par l'opérateur Strimzi,
avec authentification SCRAM-SHA-512 — configuration proche de la production EPI.

- Installation de l'opérateur Strimzi v0.47 via Helm
- Déploiement d'un cluster Kafka 4.0 en KRaft (3 nœuds combinés, PVC 5Gi)
- Création d'un KafkaUser avec authentification SCRAM-SHA-512
- Production de 10 messages authentifiés
- Backup Velero du namespace `kafka` (PVs + CRs Strimzi + secrets)
- Suppression du namespace `kafka` (l'opérateur Strimzi reste actif)
- Restauration et vérification des messages avec authentification

**Point technique** : l'opérateur Strimzi (namespace `strimzi`) n'est pas supprimé.
À la restauration, il reconcilie automatiquement les CRs Kafka restaurées.
Les secrets d'authentification SCRAM sont inclus dans le backup.
