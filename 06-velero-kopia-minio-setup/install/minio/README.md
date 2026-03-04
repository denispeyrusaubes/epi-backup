# 06 — Velero + Kopia VGDP : Installation et tests backup/restore

Installation de Velero 1.17.1 avec **Kopia** en mode **VGDP** (Velero Generic Data Path).
Deux variantes de déploiement :

| Variante | Stockage | CSI driver | CA custom | Usage |
|----------|----------|------------|-----------|-------|
| `install/eks/` | AWS S3 | EBS CSI (`ebs.csi.aws.com`) | Non | Mise au point / tests |
| `install/minio/` | MinIO (S3-compatible) | vSphere CSI (`csi.vsphere.volume`) | Oui | Déploiement client Tanzu |

---

## Architecture Velero + Kopia VGDP

### Concept général

Velero orchestre la sauvegarde et la restauration des ressources Kubernetes.
Pour les **Persistent Volumes**, le mode **VGDP** (Generic Data Path) est utilisé :
le contenu réel du volume est transféré vers le stockage objet via **Kopia**.

```
┌─────────────────────────────────────────────────────────────────┐
│                      Cluster Kubernetes                         │
│                                                                 │
│  namespace: velero                                              │
│  ┌─────────────────────┐   ┌──────────────────────────────┐    │
│  │  Deployment: velero │   │  DaemonSet: node-agent       │    │
│  │  (orchestrateur)    │   │  (1 pod par nœud)            │    │
│  │                     │   │  → exécute Kopia             │    │
│  │  - BackupController │   │  → monte les snapshots       │    │
│  │  - RestoreController│   │  → transfère vers S3/MinIO   │    │
│  │  - DataUpload ctrl  │   └──────────────────────────────┘    │
│  │  - DataDownload ctrl│                                        │
│  └─────────────────────┘                                        │
│                                                                 │
│  namespace: <app>                                               │
│  ┌──────────────────────────────────────────────┐              │
│  │  StatefulSet / Deployment                    │              │
│  │  └── PVC ──→ PV (géré par CSI driver)        │              │
│  └──────────────────────────────────────────────┘              │
│                                                                 │
│  cluster-scoped                                                 │
│  ┌──────────────────────────────────────────────┐              │
│  │  VolumeSnapshotClass                         │              │
│  │  label: velero.io/csi-volumesnapshot-         │              │
│  │         class: "true"                        │              │
│  │  driver: csi.vsphere.volume (ou ebs.csi...)  │              │
│  │  deletionPolicy: Retain                      │              │
│  └──────────────────────────────────────────────┘              │
└─────────────────────────────────────────────────────────────────┘
                    │ DataUpload (Kopia)          │ DataDownload
                    ▼                             ▼
┌─────────────────────────────────────────────────────────────────┐
│                   Stockage objet (S3 / MinIO)                   │
│                                                                 │
│  bucket: velero-backups                                         │
│  ├── backups/<nom>/                                             │
│  │   ├── velero-backup.json          ← métadonnées backup       │
│  │   ├── <nom>.tar.gz               ← ressources K8s           │
│  │   ├── <nom>-volumeinfo.json      ← mapping PVC→DataUpload   │
│  │   └── <nom>-itemoperations.json  ← suivi des opérations     │
│  └── kopia/<namespace>/             ← données des PVCs         │
│      └── <repository Kopia>         ← blocs dédupliqués        │
└─────────────────────────────────────────────────────────────────┘
```

### Flux VGDP — Backup (`snapshotMoveData: true`)

```
1. kubectl apply -f backup.yaml
        │
        ▼
2. Velero découvre les PVCs du namespace
        │
        ▼
3. Velero crée un objet VolumeSnapshot (CSI)
   → CSI driver (EBS / vSphere) crée un snapshot du disque
        │
        ▼
4. Velero crée un objet DataUpload
   → node-agent reçoit la tâche
        │
        ▼
5. node-agent crée un PVC temporaire depuis le VolumeSnapshotContent
   → monte le volume en lecture sur le nœud
        │
        ▼
6. Kopia (dans node-agent) transfère les données vers S3/MinIO
   → déduplication, compression, chiffrement côté client
        │
        ▼
7. DataUpload → Completed
   Le VolumeSnapshot temporaire est supprimé
        │
        ▼
8. Backup → Completed
```

### Flux VGDP — Restore

```
1. kubectl apply -f restore.yaml
        │
        ▼
2. Velero recrée les ressources K8s (namespace, StatefulSet, PVC, etc.)
   Les PVCs sont créés mais VIDES (sans données encore)
        │
        ▼
3. Velero crée un objet DataDownload par PVC
   → node-agent reçoit la tâche
        │
        ▼
4. Kopia (dans node-agent) télécharge les données depuis S3/MinIO
   → restitue les blocs dans le PVC recréé
        │
        ▼
5. DataDownload → Completed
        │
        ▼
6. Restore → Completed
   Les pods démarrent avec leurs données restaurées
```

### Pourquoi VGDP plutôt que file-system backup (ancienne approche)

| Critère | File-system backup (legacy) | VGDP (recommandé) |
|---------|----------------------------|-------------------|
| Mécanisme | Lecture via kubelet path + done file | CSI snapshot + DataUpload/DataDownload |
| Dépendance pod | Pod doit être Running pendant le backup | Snapshot indépendant du pod |
| Velero 1.16/1.17 | **CASSÉ** (done file jamais écrit → restore bloqué) | Fonctionne |
| Init container `restore-wait` | Requis | **Non requis** |
| Annotation pod | `backup.velero.io/backup-volumes` | **Non requise** |
| Backup manifest | `defaultVolumesToFsBackup: true` | `snapshotMoveData: true` |

---

## Prérequis communs (cluster)

Avant d'installer Velero, les éléments suivants doivent exister dans le cluster :

### 1. CSI driver avec support VolumeSnapshot

Le driver CSI doit être actif et supporter les VolumeSnapshots :

```bash
# Vérifier le CSI driver actif
kubectl get csidrivers

# EKS : ebs.csi.aws.com (installé via addon EKS)
# Tanzu/vSphere : csi.vsphere.volume (inclus dans TKG/TKGS)
```

### 2. CRDs external-snapshotter + snapshot-controller

```bash
kubectl get crd | grep snapshot
# volumesnapshots.snapshot.storage.k8s.io
# volumesnapshotcontents.snapshot.storage.k8s.io
# volumesnapshotclasses.snapshot.storage.k8s.io

kubectl get pods -n kube-system | grep snapshot-controller
```

Si absents, installer external-snapshotter v8.x :
```bash
kubectl apply -k github.com/kubernetes-csi/external-snapshotter/client/config/crd
kubectl apply -k github.com/kubernetes-csi/external-snapshotter/deploy/kubernetes/snapshot-controller
```

### 3. VolumeSnapshotClass labellisée pour Velero (1.17+)

```yaml
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshotClass
metadata:
  name: <csi-driver>-vsc
  labels:
    velero.io/csi-volumesnapshot-class: "true"   # ← OBLIGATOIRE pour VGDP
driver: csi.vsphere.volume                        # adapter selon le cluster
deletionPolicy: Retain                            # Retain = Velero gère la suppression
```

### 4. StorageClass utilisant le CSI driver

Les PVCs des applications doivent utiliser une StorageClass provisionnée par le CSI driver.

---

## Variante 1 — EKS + AWS S3 (mise au point)

```bash
cd install/eks/

# 1. Renseigner les identifiants IAM (epi-backup user — droits S3 uniquement)
vim credentials

# 2. Vérifier/adapter le bucket et la région dans values.yaml
#    bucket: velero-backups-epi  |  region: eu-west-1

# 3. Installer
chmod +x install.sh
./install.sh
```

### Infrastructure AWS requise (EKS)

| Ressource | Valeur |
|-----------|--------|
| Bucket S3 | `velero-backups-epi` |
| Région | `eu-west-1` |
| IAM user | `epi-backup` (S3 uniquement) |
| EBS CSI addon | Actif avec IRSA `AmazonEKS_EBS_CSI_DriverRole_epi` |
| VolumeSnapshotClass | `ebs-vsc` (driver: `ebs.csi.aws.com`) |
| StorageClass | `gp3-csi` (provisioner: `ebs.csi.aws.com`) |

---

## Variante 2 — MinIO + CA custom (Tanzu/vSphere)

```bash
cd install/minio/

# 1. Renseigner le mot de passe MinIO dans credentials
#    (aws_access_key_id = login MinIO, aws_secret_access_key = mot de passe)
vim credentials   # Remplacer CHANGE_ME

# 2. Vérifier ca.crt (chaîne complète déjà présente : EPI NC Issuing CA + GSES Intermediate + ISINFRA Root)

# 3. Installer
chmod +x install.sh
./install.sh
# → Encode la CA en base64 et l'injecte dans le BSL via --set
```

### Configuration MinIO

| Paramètre | Valeur |
|-----------|--------|
| URL | `https://labnousvrminio.d83.tes.local:9000` |
| Login | `velero-pra-user` |
| Bucket | `velero-backups` |
| TLS | CA chaîne 3 niveaux (ISINFRA Root → GSES Intermediate → EPI NC Issuing CA) |

---

## Vérification post-install

```bash
chmod +x verify/verify-setup.sh
./verify/verify-setup.sh
```

Contrôles effectués :
1. Deployment Velero prêt
2. DaemonSet node-agent prêt (tous les nœuds)
3. BackupStorageLocation `default` en état `Available`
4. Uploader type `kopia` configuré
5. Plugin `velero-plugin-for-aws` présent
6. Secret `velero-credentials` présent

---

## Tests applicatifs

### Test Redis

```bash
cd redis-test/

# Déployer avec StorageClass CSI
helm install redis-test ./chart/redis-test \
  --namespace redis-test --create-namespace \
  --set storageClass=gp3-csi        # adapter selon le cluster

# Insérer des données de test
./scripts/insert-data.sh

# Backup VGDP
kubectl create -f velero/backup.yaml
# Surveiller : backup → WaitingForPluginOperations → Completed
# (DataUpload créé automatiquement, Kopia transfère vers S3/MinIO)

# Simuler la perte
helm uninstall redis-test -n redis-test
kubectl delete pvc --all -n redis-test

# Restore VGDP
kubectl create -f velero/restore.yaml
# Surveiller : DataDownload → Completed, pods → Running

# Vérifier les données
./scripts/verify-data.sh
```

### Test Kafka (KRaft, sans Strimzi)

```bash
# Utiliser le chart de 02-kafka-backup-restore avec StorageClass CSI
helm install kafka-test /path/to/02-kafka-backup-restore/chart/kafka-test \
  --namespace kafka-test --create-namespace \
  --set storageClass=gp3-csi

cd kafka-test/
./scripts/insert-data.sh
kubectl create -f velero/backup.yaml
# Backup : 3 DataUploads en parallèle (~1 Go/PVC)
helm uninstall kafka-test -n kafka-test && kubectl delete pvc --all -n kafka-test
kubectl create -f velero/restore.yaml
./scripts/verify-data.sh
```

---

## Points de vigilance

### `WaitingForPluginOperations` est normal

Pendant un backup ou restore VGDP, l'objet passe par l'état `WaitingForPluginOperations`
pendant que les DataUpload/DataDownload s'exécutent. Ce n'est pas un blocage.
Durée typique : 20s (Redis ~200 bytes) à plusieurs minutes (Kafka ~1 Go × 3 PVCs).

### `upgradeCRDs: false` dans les values Helm

Le job de mise à jour des CRDs utilise l'image `bitnami/kubectl:1.32` qui n'existe pas
sur Docker Hub. Ce flag désactive ce job et évite un échec au déploiement.

### `volumeSnapshotLocation: []` dans les values Helm

Le chart Velero a une `VolumeSnapshotLocation` par défaut avec `provider: ""`.
Elle est explicitement vidée (`[]`) car VGDP utilise la VolumeSnapshotClass CSI,
pas le plugin AWS/vSphere natif. Conserver la valeur par défaut du chart provoquerait
une erreur de validation au déploiement.

### `features: EnableCSI` sous `configuration`

Ce flag doit être placé sous `configuration.features` (et non à la racine du fichier).
Sans lui, Velero ignore les VolumeSnapshotClass CSI et saute les PVCs silencieusement.

### CA cert pour MinIO

La CA est encodée en base64 et injectée dans le `BackupStorageLocation` via `--set`.
Elle ne doit pas être committée dans `values.yaml` (éviter les secrets en clair dans Git).
Le fichier `ca.crt` contient la chaîne complète (leaf → intermediate → root).

---

## Désinstallation

```bash
cd install/eks/   # ou install/minio/
./uninstall.sh
```

Les backups dans S3/MinIO ne sont **pas** supprimés.
