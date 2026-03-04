# Deploiement Velero via ArgoCD

Deployer Velero avec Kopia + MinIO en utilisant ArgoCD comme outil de GitOps.

---

## Prerequis

1. **ArgoCD** installe et operationnel sur le cluster (ou cluster de management)
2. **Acces au repo Helm** : ArgoCD doit pouvoir acceder au repo `https://vmware-tanzu.github.io/helm-charts`
3. **Prerequis cluster** executes (voir `../prerequisites/`) :
   - VolumeSnapshotClass labellisee sur le guest cluster
   - VolumeSnapshotClass sur le Supervisor
4. **Ressources Kubernetes creees manuellement** avant le deploiement ArgoCD :
   - Namespace `velero`
   - Secret `velero-credentials` (identifiants MinIO)

### Creation des ressources prealables

```bash
# Namespace
kubectl create namespace velero

# Secret credentials MinIO
kubectl create secret generic velero-credentials \
  --namespace velero \
  --from-file=cloud=../install/credentials
```

---

## Deploiement

### Option 1 — Appliquer directement

```bash
kubectl apply -f velero-app.yaml
```

### Option 2 — Via ArgoCD CLI

```bash
argocd app create -f velero-app.yaml
argocd app sync velero
```

---

## Architecture

L'Application ArgoCD :
- Pointe vers le chart Helm `vmware-tanzu/velero` (version 11.4.0)
- Utilise les values definies en inline dans le manifest
- Cree automatiquement le namespace `velero` si absent
- Sync automatique avec auto-prune et self-heal

---

## Configuration

Les parametres MinIO sont definis directement dans le `velero-app.yaml`
sous la section `helm.valuesObject`. Adapter les valeurs suivantes :

| Parametre | Chemin dans valuesObject | Valeur a adapter |
|-----------|-------------------------|------------------|
| Bucket | `configuration.backupStorageLocation[0].bucket` | Nom du bucket MinIO |
| URL MinIO | `configuration.backupStorageLocation[0].config.s3Url` | URL complete avec port |
| Region | `configuration.backupStorageLocation[0].config.region` | `minio` (convention) |

**Note :** Le certificat CA (`caCert`) doit etre injecte separement via un patch
post-sync ou un Job ArgoCD, car il ne doit pas etre stocke en clair dans Git.

---

## Verification

```bash
# Via ArgoCD
argocd app get velero

# Via kubectl
cd ../verify
./verify-setup.sh
```
