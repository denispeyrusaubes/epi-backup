# 03 — PRA Full Restore

Scénario de Plan de Reprise d'Activité (PRA) : redéploiement complet d'un cluster avec ses applications et leurs Persistent Volumes via Velero (DataMover).

## Objectif

Valider la capacité de Velero à restaurer un ensemble d'applications avec leurs données persistantes sur un nouveau cluster (ou après perte totale du cluster d'origine). Ce test simule un scénario de PRA complet.

## Statut

**À définir** — Les applications qui composeront ce test PRA doivent encore être déterminées.

## Workflow prévu

1. **Déployer** l'ensemble des applications du PRA via le chart Helm
2. **Insérer des données** dans chaque application via `scripts/insert-data.sh`
3. **Créer un backup** Velero de l'ensemble des namespaces concernés
4. **Simuler la perte** du cluster (suppression des namespaces ou bascule vers un nouveau cluster)
5. **Restaurer** le backup complet via Velero
6. **Vérifier** que toutes les applications et leurs données sont fonctionnelles via `scripts/verify-data.sh`

## Différences avec les tests unitaires (01, 02)

- Backup/restore de **plusieurs namespaces** simultanément
- Vérification de la cohérence **inter-applications** (si applicable)
- Test sur un **cluster différent** du cluster source (si possible)
- Validation du temps de restauration (RTO)

## Prérequis

- Cluster Kubernetes accessible via `kubectl`
- Helm v3+
- Velero installé et configuré avec DataMover
- (Optionnel) Second cluster pour le test de restore cross-cluster

## Paramètres du chart Helm

| Paramètre | Description | Défaut |
|-----------|-------------|--------|
| `namespace` | Namespace de déploiement | `pra-test` |
| `storageClass` | StorageClass pour les PVC | `""` (défaut du cluster) |

*D'autres paramètres seront ajoutés une fois les applications choisies.*
