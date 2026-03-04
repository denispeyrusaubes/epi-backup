# Verification post-installation — Velero + Kopia + MinIO

Script de verification automatique apres installation de Velero.

---

## Usage

```bash
chmod +x verify-setup.sh
./verify-setup.sh
```

Variable d'environnement optionnelle :
```bash
VELERO_NAMESPACE=velero ./verify-setup.sh
```

---

## Checks effectues (6)

| # | Check | Attendu |
|---|-------|---------|
| 1 | Deployment `velero` | >= 1 replica prete |
| 2 | DaemonSet `node-agent` (Kopia) | Tous les noeuds prets |
| 3 | BackupStorageLocation `default` | Phase = `Available` |
| 4 | Uploader type `kopia` | Present dans les args du deployment |
| 5 | Plugin `velero-plugin-for-aws` | Present comme initContainer |
| 6 | Secret `velero-credentials` | Present dans le namespace |

---

## Resultat attendu

```
6 PASS / 0 FAIL
```

## Depannage en cas de FAIL

```bash
# Logs Velero
kubectl logs -n velero deployment/velero

# Detail du BSL
kubectl describe backupstoragelocation default -n velero

# Evenements recents
kubectl get events -n velero --sort-by='.lastTimestamp'
```
