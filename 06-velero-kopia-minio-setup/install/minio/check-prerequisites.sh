#!/usr/bin/env bash
# =============================================================================
# Vérification des prérequis cluster pour Velero VGDP (Tanzu/vSphere + MinIO)
# =============================================================================
set -eo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
PASS=0; FAIL=0; WARN=0

pass() { echo -e "  ${GREEN}[PASS]${NC} $*"; PASS=$((PASS + 1)); }
fail() { echo -e "  ${RED}[FAIL]${NC} $*"; FAIL=$((FAIL + 1)); }
warn() { echo -e "  ${YELLOW}[WARN]${NC} $*"; WARN=$((WARN + 1)); }
section() { echo ""; echo -e "${YELLOW}--- $* ---${NC}"; }

echo ""
echo "=============================================="
echo " Vérification prérequis Velero VGDP"
echo " Tanzu/vSphere + MinIO"
echo "=============================================="

# =============================================================================
section "1. Outils locaux"
# =============================================================================
for cmd in kubectl helm base64; do
  command -v "$cmd" &>/dev/null \
    && pass "$cmd disponible ($(command -v "$cmd"))" \
    || fail "$cmd introuvable dans le PATH"
done

kubectl cluster-info &>/dev/null \
  && pass "kubectl connecté au cluster" \
  || fail "kubectl non connecté — vérifier le contexte"

CTX=$(kubectl config current-context 2>/dev/null || echo "N/A")
echo "    Contexte actif : ${CTX}"

# =============================================================================
section "2. CSI driver vSphere"
# =============================================================================
if kubectl get csidriver csi.vsphere.volume &>/dev/null; then
  pass "CSI driver csi.vsphere.volume enregistré"
else
  fail "CSI driver csi.vsphere.volume absent"
  echo "    → Vérifier que le vSphere CSI driver est installé sur le cluster Tanzu"
fi

# =============================================================================
section "3. CRDs VolumeSnapshot (external-snapshotter)"
# =============================================================================
for crd in \
  volumesnapshots.snapshot.storage.k8s.io \
  volumesnapshotcontents.snapshot.storage.k8s.io \
  volumesnapshotclasses.snapshot.storage.k8s.io; do
  kubectl get crd "$crd" &>/dev/null \
    && pass "CRD $crd" \
    || fail "CRD $crd absente → installer external-snapshotter v8.x"
done

# =============================================================================
section "4. Snapshot-controller"
# =============================================================================
SC_PODS=$(kubectl get pods -A \
  --field-selector=status.phase=Running \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
  | grep -c "snapshot-controller" || true)

if [ "${SC_PODS}" -gt 0 ]; then
  pass "snapshot-controller Running (${SC_PODS} pod(s))"
else
  fail "snapshot-controller absent ou non Running"
  echo "    → Installer external-snapshotter (snapshot-controller)"
fi

# =============================================================================
section "5. VolumeSnapshotClass annotée pour Velero"
# =============================================================================
VSC_LIST=$(kubectl get volumesnapshotclass \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.annotations.velero\.io/csi-volumesnapshot-class}{"\t"}{.deletionPolicy}{"\n"}{end}' \
  2>/dev/null || echo "")

VSC_OK=""
while IFS=$'\t' read -r name annotated policy; do
  [ -z "$name" ] && continue
  if [ "$annotated" = "true" ]; then
    if [ "$policy" = "Retain" ]; then
      pass "VolumeSnapshotClass '${name}' : annotée + deletionPolicy=Retain"
      VSC_OK="${name}"
    else
      warn "VolumeSnapshotClass '${name}' : annotée mais deletionPolicy=${policy} (Retain recommandé)"
      VSC_OK="${name}"
    fi
  fi
done <<< "${VSC_LIST}"

if [ -z "${VSC_OK}" ]; then
  fail "Aucune VolumeSnapshotClass avec annotation 'velero.io/csi-volumesnapshot-class: true'"
  echo "    → Créer une VolumeSnapshotClass pour csi.vsphere.volume avec cette annotation"
fi

# =============================================================================
section "6. StorageClass utilisant le CSI driver"
# =============================================================================
CSI_SC=$(kubectl get storageclass \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.provisioner}{"\n"}{end}' \
  2>/dev/null \
  | grep "vsphere\|csi" || true)

if [ -n "${CSI_SC}" ]; then
  while IFS=$'\t' read -r sc_name sc_prov; do
    [ -z "$sc_name" ] && continue
    pass "StorageClass '${sc_name}' (provisioner: ${sc_prov})"
  done <<< "${CSI_SC}"
else
  warn "Aucune StorageClass avec provisioner vSphere CSI trouvée"
  echo "    → Les PVCs des applications doivent utiliser une StorageClass CSI pour VGDP"
fi

# =============================================================================
section "7. Fichiers de configuration locaux"
# =============================================================================
SCRIPT_DIR="$(dirname "$0")"

for f in credentials ca.crt values.yaml install.sh; do
  if [ -f "${SCRIPT_DIR}/${f}" ]; then
    pass "Fichier présent : ${f}"
  else
    fail "Fichier manquant : ${f}"
  fi
done

# Vérifier que CHANGE_ME a été remplacé
if grep -q "CHANGE_ME" "${SCRIPT_DIR}/credentials" 2>/dev/null; then
  fail "credentials : CHANGE_ME non remplacé — renseigner le mot de passe MinIO"
else
  pass "credentials : mot de passe renseigné"
fi

# Vérifier que ca.crt est un vrai PEM (pas le placeholder)
if grep -q "FAKE\|EXAMPLE\|placeholder" "${SCRIPT_DIR}/ca.crt" 2>/dev/null; then
  fail "ca.crt : contient encore un certificat factice"
else
  CERT_COUNT=$(grep -c "BEGIN CERTIFICATE" "${SCRIPT_DIR}/ca.crt" 2>/dev/null || echo 0)
  pass "ca.crt : ${CERT_COUNT} certificat(s) PEM présent(s)"
fi

# Vérifier la connectivité MinIO
section "8. Connectivité MinIO"
MINIO_URL=$(grep "s3Url:" "${SCRIPT_DIR}/values.yaml" 2>/dev/null \
  | awk '{print $2}' | tr -d '"' | head -1)

if [ -n "${MINIO_URL}" ]; then
  echo "    URL configurée : ${MINIO_URL}"
  MINIO_HOST=$(echo "${MINIO_URL}" | sed 's|https\?://||' | cut -d: -f1)
  MINIO_PORT=$(echo "${MINIO_URL}" | sed 's|https\?://||' | cut -d: -f2 | cut -d/ -f1)
  MINIO_PORT="${MINIO_PORT:-443}"

  if command -v openssl &>/dev/null; then
    if echo "" | openssl s_client \
        -connect "${MINIO_HOST}:${MINIO_PORT}" \
        -CAfile "${SCRIPT_DIR}/ca.crt" \
        -quiet 2>/dev/null | grep -q "Verify return code: 0"; then
      pass "TLS MinIO validé avec la CA fournie"
    else
      # Test sans vérification CA pour distinguer réseau vs certificat
      if timeout 5 bash -c "echo >/dev/tcp/${MINIO_HOST}/${MINIO_PORT}" 2>/dev/null; then
        warn "MinIO joignable mais TLS non validé par la CA (vérifier ca.crt)"
      else
        warn "MinIO ${MINIO_HOST}:${MINIO_PORT} non joignable depuis ce poste"
        echo "    → Normal si MinIO n'est accessible que depuis le cluster"
      fi
    fi
  else
    warn "openssl non disponible — test TLS ignoré"
  fi
else
  fail "s3Url non trouvée dans values.yaml"
fi

# =============================================================================
echo ""
echo "=============================================="
echo " Résultat : ${PASS} PASS / ${WARN} WARN / ${FAIL} FAIL"
echo "=============================================="
echo ""

if [ "${FAIL}" -gt 0 ]; then
  echo -e "${RED}Prérequis manquants — corriger avant de lancer install.sh${NC}"
  exit 1
elif [ "${WARN}" -gt 0 ]; then
  echo -e "${YELLOW}Avertissements à examiner — installation possible mais à valider${NC}"
  exit 0
else
  echo -e "${GREEN}Tous les prérequis sont satisfaits — prêt pour install.sh${NC}"
  exit 0
fi
