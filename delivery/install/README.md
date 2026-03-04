# Installation Velero + Kopia VGDP — Tanzu/vSphere + MinIO

Guide d'installation pas a pas.

---

## Fichiers du repertoire

| Fichier | Role |
|---------|------|
| `install.sh` | Script d'installation principal |
| `uninstall.sh` | Script de desinstallation |
| `values.yaml` | Configuration Helm Velero (parametree) |
| `config.env.example` | Template de configuration (copier en `config.env`) |
| `credentials.example` | Template identifiants MinIO (copier en `credentials`) |
| `ca.crt` | Chaine CA complete pour valider le TLS MinIO |

---

## Configuration requise

### Etape 1 — Creer `config.env`

```bash
cp config.env.example config.env
vim config.env
```

Adapter les variables selon l'environnement :

| Variable | Description |
|----------|-------------|
| `MINIO_URL` | URL MinIO (ex: `https://minio.example.com:9000`) |
| `MINIO_BUCKET` | Nom du bucket S3 |
| `MINIO_REGION` | Region S3 (convention MinIO : `minio`) |
| `VELERO_NAMESPACE` | Namespace Kubernetes (defaut : `velero`) |
| `CHART_VERSION` | Version du chart Helm (defaut : `11.4.0`) |

### Etape 2 — Creer le fichier `credentials`

```bash
cp credentials.example credentials
vim credentials
# Remplacer CHANGE_ME par le mot de passe MinIO
```

Format AWS SDK :
```
[default]
aws_access_key_id=velero-pra-user
aws_secret_access_key=<mot-de-passe>
```

### Etape 3 — Verifier `ca.crt`

Le fichier `ca.crt` doit contenir la chaine CA complete du serveur MinIO
(issuing CA → intermediate CA → root CA). Remplacer si necessaire.

---

## Installation

```bash
chmod +x install.sh
./install.sh
```

Le script effectue dans l'ordre :
1. Charge la configuration depuis `config.env`
2. Verifie les prerequis (kubectl, helm, fichiers)
3. Verifie que `CHANGE_ME` a ete remplace dans `credentials`
4. Verifie la presence d'une VolumeSnapshotClass labellisee
5. Ajoute le repo Helm `vmware-tanzu`
6. Cree le namespace Velero
7. Cree le secret `velero-credentials` (identifiants MinIO)
8. Genere le `values.yaml` final avec les parametres de `config.env`
9. Encode `ca.crt` en base64 et lance `helm upgrade --install` avec injection du caCert
10. Attend que le Deployment et le DaemonSet `node-agent` soient prets
11. Affiche l'etat final

**Resultat attendu :**
```
=== BackupStorageLocation ===
NAME      PHASE       LAST VALIDATED   AGE   DEFAULT
default   Available   30s              60s   true
```

---

## Mise a jour du certificat CA

Si le certificat CA change (renouvellement, rotation) :

```bash
# Remplacer ca.crt avec le nouveau certificat
# Puis relancer l'installation (helm upgrade --install) :
./install.sh
```

---

## Mise a jour Velero (helm upgrade)

Relancer `install.sh` — le script utilise `helm upgrade --install` :

```bash
./install.sh
```

---

## Desinstallation

```bash
chmod +x uninstall.sh
./uninstall.sh
```

Les backups stockes dans MinIO ne sont **pas** supprimes.

---

## Depannage

### BSL non Available

```bash
kubectl describe backupstoragelocation default -n velero
kubectl logs deployment/velero -n velero | grep -i "bsl\|storage\|error"
```

Causes frequentes : URL MinIO incorrecte, CA manquante, bucket inexistant,
identifiants incorrects.

### DataUpload bloque en `Accepted`

```bash
kubectl logs daemonset/node-agent -n velero | grep -i "error\|upload"
kubectl get datauploads -n velero -o yaml
```

Cause frequente : VolumeSnapshotClass manquante ou sans le label
`velero.io/csi-volumesnapshot-class: "true"` (Velero 1.17+ exige un label).

### PVC non sauvegarde (skippe silencieusement)

```bash
kubectl logs deployment/velero -n velero | grep "skipped\|snapshot\|no applicable"
```

Cause frequente : `features: EnableCSI` absent dans `values.yaml`.
