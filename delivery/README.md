# Velero + Kopia VGDP — Tanzu/vSphere + MinIO

Livrable d'installation de **Velero 1.17.1** avec **Kopia** en mode **VGDP** (Velero Generic Data Path)
sur un cluster **Tanzu guest** (vSphere), avec **MinIO** comme stockage objet S3-compatible.

---

## Architecture

### Concept general

Velero orchestre la sauvegarde et la restauration des ressources Kubernetes.
Pour les **Persistent Volumes**, le mode **VGDP** (Generic Data Path) est utilise :
le contenu reel du volume est transfere vers le stockage objet via **Kopia**.

```
┌─────────────────────────────────────────────────────────────────┐
│                      Cluster Kubernetes                         │
│                                                                 │
│  namespace: velero                                              │
│  ┌─────────────────────┐   ┌──────────────────────────────┐    │
│  │  Deployment: velero │   │  DaemonSet: node-agent       │    │
│  │  (orchestrateur)    │   │  (1 pod par noeud)           │    │
│  │                     │   │  → execute Kopia             │    │
│  │  - BackupController │   │  → monte les snapshots       │    │
│  │  - RestoreController│   │  → transfere vers MinIO      │    │
│  │  - DataUpload ctrl  │   └──────────────────────────────┘    │
│  │  - DataDownload ctrl│                                        │
│  └─────────────────────┘                                        │
│                                                                 │
│  namespace: <app>                                               │
│  ┌──────────────────────────────────────────────┐              │
│  │  StatefulSet / Deployment                    │              │
│  │  └── PVC ──→ PV (gere par CSI driver)        │              │
│  └──────────────────────────────────────────────┘              │
│                                                                 │
│  cluster-scoped                                                 │
│  ┌──────────────────────────────────────────────┐              │
│  │  VolumeSnapshotClass                         │              │
│  │  label: velero.io/csi-volumesnapshot-         │              │
│  │         class: "true"                        │              │
│  │  driver: csi.vsphere.vmware.com              │              │
│  │  deletionPolicy: Delete                      │              │
│  └──────────────────────────────────────────────┘              │
└─────────────────────────────────────────────────────────────────┘
                    │ DataUpload (Kopia)          │ DataDownload
                    ▼                             ▼
┌─────────────────────────────────────────────────────────────────┐
│                     Stockage objet (MinIO)                      │
│                                                                 │
│  bucket: velero-pra                                             │
│  ├── backups/<nom>/                                             │
│  │   ├── velero-backup.json          ← metadonnees backup       │
│  │   ├── <nom>.tar.gz               ← ressources K8s           │
│  │   ├── <nom>-volumeinfo.json      ← mapping PVC→DataUpload   │
│  │   └── <nom>-itemoperations.json  ← suivi des operations     │
│  └── kopia/<namespace>/             ← donnees des PVCs         │
│      └── <repository Kopia>         ← blocs dedupliques        │
└─────────────────────────────────────────────────────────────────┘
```

### Role de Kopia dans les node-agents

Kopia est le **data mover** execute dans chaque pod du DaemonSet `node-agent` :

- **Deduplication** : les blocs identiques ne sont transmis qu'une fois
- **Compression** : reduction du volume transfere (zstd par defaut)
- **Chiffrement** : donnees chiffrees cote client avant envoi vers MinIO
- **Transfert incremental** : seuls les blocs modifies sont envoyes lors des backups suivants

### Strategie CSI snapshot (Tanzu guest)

En environnement Tanzu guest, le CSI driver **paravirtuel** (`csi.vsphere.vmware.com`)
propage les VolumeSnapshots vers le **Supervisor Cluster**. La strategie retenue :

1. Utiliser la VolumeSnapshotClass pre-existante `volumesnapshotclass-delete` (creee par le TKR)
2. La labelliser pour Velero : `velero.io/csi-volumesnapshot-class: "true"`
3. **Ne PAS creer de VolumeSnapshotClass custom** en Tanzu guest (non supporte par le Supervisor)
4. Verifier que le Supervisor dispose egalement de sa VolumeSnapshotClass

---

## Flux backup (`snapshotMoveData: true`)

```
1. kubectl apply -f backup.yaml
        │
        ▼
2. Velero decouvre les PVCs du namespace
        │
        ▼
3. Velero cree un objet VolumeSnapshot (CSI)
   → CSI driver vSphere cree un snapshot du disque
        │
        ▼
4. Velero cree un objet DataUpload
   → node-agent recoit la tache
        │
        ▼
5. node-agent cree un PVC temporaire depuis le VolumeSnapshotContent
   → monte le volume en lecture sur le noeud
        │
        ▼
6. Kopia (dans node-agent) transfere les donnees vers MinIO
   → deduplication, compression, chiffrement cote client
        │
        ▼
7. DataUpload → Completed
   Le VolumeSnapshot temporaire est supprime
        │
        ▼
8. Backup → Completed
```

## Flux restore

```
1. kubectl apply -f restore.yaml
        │
        ▼
2. Velero recree les ressources K8s (namespace, StatefulSet, PVC, etc.)
   Les PVCs sont crees mais VIDES (sans donnees encore)
        │
        ▼
3. Velero cree un objet DataDownload par PVC
   → node-agent recoit la tache
        │
        ▼
4. Kopia (dans node-agent) telecharge les donnees depuis MinIO
   → restitue les blocs dans le PVC recree
        │
        ▼
5. DataDownload → Completed
        │
        ▼
6. Restore → Completed
   Les pods demarrent avec leurs donnees restaurees
```

---

## Pourquoi VGDP plutot que file-system backup

| Critere | File-system backup (legacy) | VGDP (recommande) |
|---------|----------------------------|-------------------|
| Mecanisme | Lecture via kubelet path + done file | CSI snapshot + DataUpload/DataDownload |
| Dependance pod | Pod doit etre Running pendant le backup | Snapshot independant du pod |
| Velero 1.16/1.17 | **CASSE** (done file jamais ecrit → restore bloque) | Fonctionne |
| Init container `restore-wait` | Requis | **Non requis** |
| Annotation pod | `backup.velero.io/backup-volumes` | **Non requise** |
| Backup manifest | `defaultVolumesToFsBackup: true` | `snapshotMoveData: true` |

---

## Contenu du livrable

| Repertoire | Description |
|------------|-------------|
| `prerequisites/` | Prerequis cluster (guest + Supervisor) et scripts de configuration VolumeSnapshot |
| `install/` | Scripts d'installation, desinstallation, configuration Helm et templates |
| `verify/` | Verification post-installation (6 checks) |
| `argocd/` | Deploiement via ArgoCD (Application Helm) |

Chaque repertoire contient son propre `README.md` avec les instructions detaillees.
