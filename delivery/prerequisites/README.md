# Prerequis cluster — Velero VGDP (Tanzu/vSphere)

Avant d'installer Velero, les elements suivants doivent etre presents et configures
sur le cluster Tanzu guest **et** sur le Supervisor Cluster.

---

## Prerequis infrastructure vSphere

| Composant | Version minimale |
|-----------|-----------------|
| vSphere | >= 8.0 Update 2 |
| TKR (Tanzu Kubernetes Release) | >= v1.26.5 |
| Packages guest requis | cert-manager, vsphere-pv-csi-webhook |

---

## 1. CSI driver paravirtuel

Le Tanzu guest cluster utilise le CSI driver paravirtuel `csi.vsphere.vmware.com` :

```bash
kubectl get csidrivers
# attendu : csi.vsphere.vmware.com
```

Ce driver est inclus automatiquement dans les clusters TKG/TKGS.

## 2. CRDs VolumeSnapshot

Les trois CRDs VolumeSnapshot doivent etre presentes :

```bash
kubectl get crd | grep snapshot
# volumesnapshots.snapshot.storage.k8s.io
# volumesnapshotcontents.snapshot.storage.k8s.io
# volumesnapshotclasses.snapshot.storage.k8s.io
```

Sur Tanzu guest, elles sont incluses via les packages TKR. Si absentes :
```bash
SNAPSHOTTER_VERSION=v8.2.0
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/${SNAPSHOTTER_VERSION}/client/config/crd/snapshot.storage.k8s.io_volumesnapshotclasses.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/${SNAPSHOTTER_VERSION}/client/config/crd/snapshot.storage.k8s.io_volumesnapshotcontents.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/${SNAPSHOTTER_VERSION}/client/config/crd/snapshot.storage.k8s.io_volumesnapshots.yaml
```

## 3. Snapshot-controller

```bash
kubectl get pods -A | grep snapshot-controller
# attendu : 1/1 Running
```

Inclus sur Tanzu guest via le package `vsphere-pv-csi-webhook`.

## 4. VolumeSnapshotClass cote guest cluster

Le TKR cree automatiquement la VolumeSnapshotClass `volumesnapshotclass-delete`.
Il faut la **labelliser** pour Velero (Velero 1.17+ exige un label, pas une annotation) :

```bash
./setup-guest-snapshot.sh
```

Le script :
- Verifie les prerequis (CRDs, snapshot-controller, CSI driver)
- Labellise `volumesnapshotclass-delete` avec `velero.io/csi-volumesnapshot-class: "true"`
- Supprime les VolumeSnapshotClass custom incompatibles (ex: `vsphere-vsc`)

**IMPORTANT : Ne PAS creer de VolumeSnapshotClass custom en Tanzu guest.**
Le Supervisor ne supporte pas `deletionPolicy: Retain` sur les classes propagees.
La classe `volumesnapshotclass-delete` (avec `deletionPolicy: Delete`) est la seule
supportee. En mode VGDP, cela ne pose pas de probleme car les snapshots sont transients
(supprimes apres le transfert Kopia).

## 5. VolumeSnapshotClass cote Supervisor

Le Supervisor doit egalement disposer d'une VolumeSnapshotClass. Sans elle, le champ
`volumeSnapshotClassName` est vide et provoque l'erreur :
```
volumeSnapshotClassName must not be the empty string when set
```

```bash
# Se connecter au Supervisor
kubectl vsphere login --server=<SUPERVISOR_VIP> \
  --vsphere-username=administrator@vsphere.local \
  --tanzu-kubernetes-cluster-namespace=<SV_NAMESPACE>

# Basculer sur le contexte Supervisor
kubectl config use-context <SUPERVISOR_VIP>

# Executer le script
./setup-supervisor-snapshot.sh
```

Le script cree/verifie `volumesnapshotclass-delete` sur le Supervisor
et la marque comme classe par defaut (annotation `snapshot.storage.kubernetes.io/is-default-class`).

## 6. Verification

Apres avoir execute les deux scripts, verifier l'etat :

```bash
# Sur le guest cluster
kubectl get volumesnapshotclass -o custom-columns=\
'NAME:.metadata.name,DRIVER:.driver,DELETION_POLICY:.deletionPolicy,VELERO_LABEL:.metadata.labels.velero\.io/csi-volumesnapshot-class'

# Resultat attendu :
# NAME                          DRIVER                      DELETION_POLICY   VELERO_LABEL
# volumesnapshotclass-delete    csi.vsphere.vmware.com      Delete            true
```

---

## Scripts fournis

| Script | Contexte kubectl | Action |
|--------|-----------------|--------|
| `setup-guest-snapshot.sh` | Guest cluster | Labellise la VSC pour Velero |
| `setup-supervisor-snapshot.sh` | Supervisor | Cree/verifie la VSC sur le Supervisor |
