#!/usr/bin/env bash
# =============================================================================
# Vérification post-installation de Velero + Kopia + MinIO
# =============================================================================
set -eo pipefail

VELERO_NAMESPACE="${VELERO_NAMESPACE:-velero}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
PASS=0; FAIL=0

pass() { echo -e "  ${GREEN}[PASS]${NC} $*"; PASS=$((PASS + 1)); }
fail() { echo -e "  ${RED}[FAIL]${NC} $*"; FAIL=$((FAIL + 1)); }
info() { echo -e "${YELLOW}---${NC} $*"; }

echo ""
echo "=============================================="
echo " Vérification de l'installation Velero"
echo "=============================================="
echo ""

# --- 1. Deployment Velero ---
info "1. Deployment Velero"
VELERO_READY=$(kubectl get deployment velero -n "${VELERO_NAMESPACE}" \
  -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
if [ "${VELERO_READY}" -ge 1 ] 2>/dev/null; then
  pass "Deployment velero : ${VELERO_READY} replica(s) prête(s)"
else
  fail "Deployment velero non prêt (readyReplicas=${VELERO_READY})"
fi

# --- 2. DaemonSet node-agent ---
info "2. DaemonSet node-agent (Kopia)"
NODE_DESIRED=$(kubectl get daemonset node-agent -n "${VELERO_NAMESPACE}" \
  -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || echo "0")
NODE_READY=$(kubectl get daemonset node-agent -n "${VELERO_NAMESPACE}" \
  -o jsonpath='{.status.numberReady}' 2>/dev/null || echo "0")
if [ "${NODE_DESIRED}" -gt 0 ] && [ "${NODE_READY}" = "${NODE_DESIRED}" ]; then
  pass "DaemonSet node-agent : ${NODE_READY}/${NODE_DESIRED} nœuds prêts"
else
  fail "DaemonSet node-agent : ${NODE_READY}/${NODE_DESIRED} nœuds prêts"
fi

# --- 3. BackupStorageLocation ---
info "3. BackupStorageLocation (MinIO)"
BSL_PHASE=$(kubectl get backupstoragelocation default -n "${VELERO_NAMESPACE}" \
  -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")
if [ "${BSL_PHASE}" = "Available" ]; then
  pass "BackupStorageLocation 'default' : Available"
else
  fail "BackupStorageLocation 'default' : ${BSL_PHASE} (attendu: Available)"
  echo ""
  echo "       Détails BSL :"
  kubectl describe backupstoragelocation default -n "${VELERO_NAMESPACE}" 2>/dev/null \
    | grep -A5 "Status:" || true
fi

# --- 4. Uploader type Kopia ---
info "4. Configuration Kopia"
UPLOADER=$(kubectl get deployment velero -n "${VELERO_NAMESPACE}" \
  -o jsonpath='{.spec.template.spec.containers[0].args}' 2>/dev/null | tr ',' '\n' | grep uploader-type || echo "")
if echo "${UPLOADER}" | grep -q "kopia"; then
  pass "Uploader type : kopia"
else
  fail "Uploader type Kopia non détecté dans les args du deployment"
fi

# --- 5. Plugin AWS présent ---
info "5. Plugin AWS (S3/MinIO)"
PLUGIN_INIT=$(kubectl get deployment velero -n "${VELERO_NAMESPACE}" \
  -o jsonpath='{.spec.template.spec.initContainers[*].name}' 2>/dev/null || echo "")
if echo "${PLUGIN_INIT}" | grep -q "velero-plugin-for-aws"; then
  pass "initContainer velero-plugin-for-aws présent"
else
  fail "initContainer velero-plugin-for-aws absent"
fi

# --- 6. Secret credentials ---
info "6. Secret credentials MinIO"
SECRET_EXISTS=$(kubectl get secret velero-credentials -n "${VELERO_NAMESPACE}" \
  --ignore-not-found -o name 2>/dev/null || echo "")
if [ -n "${SECRET_EXISTS}" ]; then
  pass "Secret velero-credentials présent"
else
  fail "Secret velero-credentials absent"
fi

# --- Résumé ---
echo ""
echo "=============================================="
echo " Résultat : ${PASS} PASS / ${FAIL} FAIL"
echo "=============================================="

if [ "${FAIL}" -gt 0 ]; then
  echo ""
  echo "Commandes utiles pour investiguer :"
  echo "  kubectl logs -n ${VELERO_NAMESPACE} deployment/velero"
  echo "  kubectl describe backupstoragelocation default -n ${VELERO_NAMESPACE}"
  echo "  kubectl get events -n ${VELERO_NAMESPACE} --sort-by='.lastTimestamp'"
  exit 1
else
  echo ""
  echo "Velero est opérationnel. Vous pouvez lancer le test Redis :"
  echo "  cd ../redis-test && helm install redis-test ./chart/redis-test"
  exit 0
fi
