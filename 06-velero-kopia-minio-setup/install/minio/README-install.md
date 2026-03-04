# Installation Velero + Kopia VGDP — Tanzu/vSphere + MinIO

Guide d'installation pas à pas pour l'environnement client.

---

## Fichiers du répertoire

| Fichier | Rôle |
|---------|------|
| `install.sh` | Script d'installation principal |
| `uninstall.sh` | Script de désinstallation |
| `create-vsc.sh` | Création de la VolumeSnapshotClass Velero (détection auto du driver CSI) |
| `check-prerequisites.sh` | Vérification des prérequis cluster |
| `values.yaml` | Configuration Helm Velero |
| `credentials.example` | Modèle d'identifiants MinIO (copier en `credentials` et renseigner) |
| `ca.crt` | Chaîne CA complète pour valider le TLS MinIO |
| `README.md` | Architecture générale Velero + Kopia VGDP |
| `README-install.md` | Ce fichier — procédure d'installation |

---

## Prérequis cluster (à vérifier avant installation)

Un script vérifie automatiquement tous les prérequis :

```bash
chmod +x check-prerequisites.sh
./check-prerequisites.sh
```

Résultat attendu : `X PASS / 0 WARN / 0 FAIL`

Les sections suivantes détaillent chaque contrôle effectué par le script.

### 1. CSI driver vSphere actif

Deux variantes possibles selon le type de cluster :

| Variante | Driver CSI |
|----------|-----------|
| Tanzu guest cluster (VMware paravirtual) | `csi.vsphere.vmware.com` |
| vSphere CSI classique (on-premise) | `csi.vsphere.volume` |

```bash
kubectl get csidrivers | grep vsphere
# attendu : l'un des deux drivers ci-dessus
```

### 2. CRDs VolumeSnapshot + snapshot-controller

```bash
kubectl get crd | grep snapshot
# attendu :
#   volumesnapshots.snapshot.storage.k8s.io
#   volumesnapshotcontents.snapshot.storage.k8s.io
#   volumesnapshotclasses.snapshot.storage.k8s.io

kubectl get pods -A | grep snapshot-controller
# attendu : 1/1 Running
```

Sur Tanzu guest, ces composants sont inclus — pas d'installation nécessaire.

Si absents (cluster non-Tanzu), installer external-snapshotter :
```bash
SNAPSHOTTER_VERSION=v8.2.0
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/${SNAPSHOTTER_VERSION}/client/config/crd/snapshot.storage.k8s.io_volumesnapshotclasses.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/${SNAPSHOTTER_VERSION}/client/config/crd/snapshot.storage.k8s.io_volumesnapshotcontents.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/${SNAPSHOTTER_VERSION}/client/config/crd/snapshot.storage.k8s.io_volumesnapshots.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/${SNAPSHOTTER_VERSION}/deploy/kubernetes/snapshot-controller/rbac-snapshot-controller.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/${SNAPSHOTTER_VERSION}/deploy/kubernetes/snapshot-controller/setup-snapshot-controller.yaml
```

### 3. VolumeSnapshotClass annotée pour Velero

Le script `create-vsc.sh` détecte automatiquement le driver CSI et crée la VolumeSnapshotClass :

```bash
chmod +x create-vsc.sh
./create-vsc.sh
```

Ou manuellement (adapter le `driver` au cluster) :
```yaml
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshotClass
metadata:
  name: vsphere-vsc
  annotations:
    velero.io/csi-volumesnapshot-class: "true"
driver: csi.vsphere.vmware.com   # ou csi.vsphere.volume selon le cluster
deletionPolicy: Retain
```

### 4. StorageClass CSI pour les applications

Les PVCs des applications à sauvegarder doivent utiliser une StorageClass
provisionnée par le driver CSI vSphere :
```bash
kubectl get storageclass | grep vsphere
```

---

## Configuration avant installation

### Étape 1 — Créer le fichier credentials

Copier le modèle et renseigner le mot de passe réel :

```bash
cp credentials.example credentials
# Puis éditer credentials et remplacer CHANGE_ME par le mot de passe MinIO
```

```
[default]
aws_access_key_id=velero-pra-user
aws_secret_access_key=<mot-de-passe>
```

> Le fichier `ca.crt` contient déjà la chaîne CA de l'environnement
> (EPI NC Issuing CA → GSES Intermediate CA → ISINFRA Root CA).

### Étape 2 — Vérifier `values.yaml`

Points à contrôler :

| Paramètre | Valeur attendue | Localisation |
|-----------|----------------|--------------|
| `configuration.backupStorageLocation[0].bucket` | `velero-backups` | `values.yaml` |
| `configuration.backupStorageLocation[0].config.s3Url` | `https://labnousvrminio.d83.tes.local:9000` | `values.yaml` |
| `configuration.features` | `EnableCSI` | `values.yaml` |
| `configuration.volumeSnapshotLocation` | `[]` | `values.yaml` |

---

## Installation

```bash
chmod +x install.sh
./install.sh
```

Le script effectue dans l'ordre :
1. Vérifie les prérequis (kubectl, helm, base64, fichiers)
2. Vérifie que `CHANGE_ME` a été remplacé dans credentials
3. Vérifie la présence d'une VolumeSnapshotClass annotée
4. Ajoute le repo Helm vmware-tanzu
5. Crée le namespace `velero`
6. Crée le secret `velero-credentials` (identifiants MinIO)
7. Encode la CA en base64 et lance `helm upgrade --install`
8. Attend que le Deployment et le DaemonSet node-agent soient prêts
9. Affiche l'état final et le statut du BackupStorageLocation

**Résultat attendu :**
```
=== BackupStorageLocation ===
NAME      PHASE       LAST VALIDATED   AGE   DEFAULT
default   Available   30s              60s   true
```

---

## Vérification complète

```bash
../../verify/verify-setup.sh
```

Résultat attendu : `6 PASS / 0 FAIL`

---

## Lancer un backup VGDP

Le backup utilise `snapshotMoveData: true` — le contenu des PVCs est transféré
vers MinIO via Kopia (CSI snapshot → DataUpload → Kopia).

Exemple avec Redis :
```bash
# Déployer l'application avec une StorageClass CSI
helm install redis-test ../../redis-test/chart/redis-test \
  --namespace redis-test --create-namespace \
  --set storageClass=<storageclass-vsphere>

# Insérer des données
bash ../../redis-test/scripts/insert-data.sh

# Créer le backup
kubectl create -f ../../redis-test/velero/backup.yaml

# Surveiller (WaitingForPluginOperations = normal pendant le DataUpload)
kubectl get backup redis-kopia-backup -n velero -w
kubectl get datauploads -n velero -w
```

---

## Désinstallation

```bash
chmod +x uninstall.sh
./uninstall.sh
```

Les backups stockés dans MinIO ne sont **pas** supprimés.

---

## Dépannage

### BSL non Available

```bash
kubectl describe backupstoragelocation default -n velero
kubectl logs deployment/velero -n velero | grep -i "bsl\|storage\|error"
```

Causes fréquentes : URL MinIO incorrecte, CA manquante ou incomplète, bucket inexistant,
identifiants incorrects.

### DataUpload bloqué en `Accepted`

```bash
kubectl logs daemonset/node-agent -n velero | grep -i "error\|upload"
kubectl get datauploads -n velero -o yaml
```

Cause fréquente : VolumeSnapshotClass manquante ou non annotée
(`velero.io/csi-volumesnapshot-class: "true"`).

### PVC non sauvegardé (skippé silencieusement)

```bash
kubectl logs deployment/velero -n velero | grep "skipped\|snapshot\|no applicable"
```

Cause fréquente : `features: EnableCSI` absent ou mal placé dans `values.yaml`
(doit être sous `configuration.features`, pas à la racine).

### Backup `Failed` — "backup already exists in object storage"

Le backup existe déjà dans MinIO. Supprimer l'objet Backup Kubernetes :
```bash
kubectl delete backup <nom> -n velero
```
Si le backup persiste (re-synchro BSL), supprimer depuis MinIO avec le client mc :
```bash
mc rm --recursive --force minio/velero-backups/backups/<nom>/
```
