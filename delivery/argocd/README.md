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

### Certificat CA (caCert)

Le certificat CA est injecte a **deux endroits** dans le BSL, pour deux composants differents :

| Champ BSL | Utilise par | Injection |
|-----------|-----------|-----------|
| `spec.config.caCert` | Plugin AWS (validation BSL → Available) | Via `velero-app.yaml` (Helm values) |
| `spec.objectStorage.caCert` | Kopia / node-agent (DataUpload/Download) | Via `kubectl patch` apres sync |

**Etape 1 — config.caCert dans le manifest :**

Generer la valeur base64 et remplacer `__CA_CERT_B64__` dans `velero-app.yaml` :
```bash
base64 < ../install/ca.crt | tr -d '\n'
```

**Etape 2 — objectStorage.caCert apres le premier sync :**

Le chart Helm ne supporte pas ce champ directement. L'injecter via patch :
```bash
CA_B64=$(base64 < ../install/ca.crt | tr -d '\n')
kubectl patch bsl default -n velero --type merge \
  -p "{\"spec\":{\"objectStorage\":{\"caCert\":\"${CA_B64}\"}}}"
```

L'Application ArgoCD est configuree avec `ignoreDifferences` + `RespectIgnoreDifferences`
pour que selfHeal ne reverte pas ce patch.

**Note :** un certificat CA n'est pas un secret — il peut etre stocke dans Git.

---

## Deploiement via ApplicationSet

Dans un contexte ou les applications du cluster sont gerees via un **ApplicationSet**,
Velero peut etre integre comme element de la liste. Exemple base sur le modele
`noprod-cluster-core-apps` :

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: noprod-cluster-core-apps
  namespace: argocd
spec:
  generators:
    - list:
        elements:

          - name: velero
            namespace: velero
            chartRepo: https://vmware-tanzu.github.io/helm-charts
            chartName: velero
            chartVersion: 11.4.0

          - name: velero-ui
            namespace: velero-ui
            chartRepo: https://helm.otwld.com/
            chartName: velero-ui
            chartVersion: 0.14.0

  template:
    metadata:
      name: '{{name}}-core'
    spec:
      project: noprod-core
      sources:
        # 1 : Chart Helm
        - repoURL: '{{chartRepo}}'
          targetRevision: '{{chartVersion}}'
          chart: '{{chartName}}'
          helm:
            valueFiles:
              - $values/values/{{name}}/values.yml

        # 2 : Fichier values depuis le repo Git
        - repoURL: https://bitbucket.org/engiepacifiqueinformatique/tanzu-clusters-core-apps.git
          targetRevision: onprem-noprod
          ref: values

        # 3 : Ressources additionnelles (manifests bruts)
        - repoURL: https://bitbucket.org/engiepacifiqueinformatique/tanzu-clusters-core-apps.git
          targetRevision: onprem-noprod
          path: values/{{name}}/resources

        # 4 : ExternalSecrets
        - repoURL: https://bitbucket.org/engiepacifiqueinformatique/tanzu-clusters-core-apps.git
          targetRevision: onprem-noprod
          path: values/{{name}}/external-secrets

      destination:
        server: https://10.130.206.201:6443
        namespace: '{{namespace}}'
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - CreateNamespace=true
          - ApplyOutOfSyncOnly=true
          - ServerSideApply=true
```

**Points cles :**
- Les **values Helm** sont stockees dans le repo Git sous `values/velero/values.yml`
- Les **ressources additionnelles** (ex: BSL patch, secrets) vont dans `values/velero/resources/`
- Les **ExternalSecrets** pour les credentials MinIO dans `values/velero/external-secrets/`
- Le `velero-credentials` secret peut etre gere via ExternalSecrets plutot que cree manuellement
- La version du chart (`11.4.0`) est centralisee dans l'element de la liste

---

## Verification

```bash
# Via ArgoCD
argocd app get velero

# Via kubectl
cd ../verify
./verify-setup.sh
```
