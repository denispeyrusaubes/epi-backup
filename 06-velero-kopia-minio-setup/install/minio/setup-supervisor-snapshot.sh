#!/usr/bin/env bash
# =============================================================================
# Configuration VolumeSnapshot sur le Supervisor Cluster
#
# Le CSI paravirtuel (csi.vsphere.vmware.com) du guest cluster propage les
# VolumeSnapshots vers le Supervisor. Si le Supervisor n'a pas de
# VolumeSnapshotClass, le champ volumeSnapshotClassName est vide → erreur :
#   "volumeSnapshotClassName must not be the empty string when set"
#
# Ce script (à exécuter avec un contexte kubectl Supervisor) :
#   1. Vérifie la connectivité au Supervisor
#   2. Vérifie les CRDs VolumeSnapshot
#   3. Vérifie le snapshot-controller
#   4. Crée/vérifie volumesnapshotclass-delete (si absente)
#   5. La marque comme classe par défaut
#
# Prérequis :
#   - Accès kubectl au Supervisor (kubectl vsphere login --server=<SV_VIP>)
#   - Droits admin sur le Supervisor
#
# Usage :
#   # 1. Se connecter au Supervisor
#   kubectl vsphere login --server=<SUPERVISOR_VIP> \
#     --vsphere-username=administrator@vsphere.local \
#     --tanzu-kubernetes-cluster-namespace=<SV_NAMESPACE>
#
#   # 2. Basculer sur le contexte Supervisor
#   kubectl config use-context <SUPERVISOR_VIP>
#
#   # 3. Exécuter ce script
#   ./setup-supervisor-snapshot.sh
#
#   # Optionnel : cibler un namespace TKG spécifique
#   SV_NAMESPACE=svc-tkg-domain-c1030 ./setup-supervisor-snapshot.sh
# =============================================================================
set -eo pipefail

# --- Configuration ---
SV_NAMESPACE="${SV_NAMESPACE:-}"
VSC_NAME="volumesnapshotclass-delete"
CSI_DRIVER="csi.vsphere.vmware.com"

# --- Couleurs ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
PASS=0; FAIL=0; WARN=0

pass()    { echo -e "  ${GREEN}[PASS]${NC} $*"; PASS=$((PASS + 1)); }
fail()    { echo -e "  ${RED}[FAIL]${NC} $*"; FAIL=$((FAIL + 1)); }
warn()    { echo -e "  ${YELLOW}[WARN]${NC} $*"; WARN=$((WARN + 1)); }
info()    { echo -e "${GREEN}[INFO]${NC} $*"; }
section() { echo ""; echo -e "${YELLOW}--- $* ---${NC}"; }

echo ""
echo "============================================================"
echo " Configuration VolumeSnapshot — Supervisor Cluster"
echo "============================================================"

# =============================================================================
section "1. Connectivité Supervisor"
# =============================================================================
kubectl cluster-info &>/dev/null \
  || { fail "kubectl non connecté"; echo ""; exit 1; }

CTX=$(kubectl config current-context 2>/dev/null || echo "N/A")
echo "    Contexte actif : ${CTX}"

# Détecter les namespaces TKG sur le Supervisor
SV_NS_LIST=$(kubectl get namespaces -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' \
  2>/dev/null | grep -E '^svc-tkg-|^ns-tkg-' || true)

if [ -n "${SV_NS_LIST}" ]; then
  pass "Namespaces TKG détectés sur le Supervisor :"
  echo "${SV_NS_LIST}" | while read -r ns; do echo "      - ${ns}"; done
else
  warn "Aucun namespace svc-tkg-*/ns-tkg-* trouvé"
  echo "    Vérifier que le contexte kubectl pointe bien vers le Supervisor"
  echo "    et non vers un guest cluster."
fi

# =============================================================================
section "2. CRDs VolumeSnapshot sur le Supervisor"
# =============================================================================
ALL_CRDS_OK=true
for crd in \
  volumesnapshots.snapshot.storage.k8s.io \
  volumesnapshotcontents.snapshot.storage.k8s.io \
  volumesnapshotclasses.snapshot.storage.k8s.io; do
  if kubectl get crd "$crd" &>/dev/null; then
    pass "CRD ${crd}"
  else
    fail "CRD ${crd} absente"
    ALL_CRDS_OK=false
  fi
done

if [ "${ALL_CRDS_OK}" = "false" ]; then
  echo ""
  echo "    Les CRDs VolumeSnapshot sont absentes du Supervisor."
  echo "    Prérequis : vSphere >= 8.0 Update 2"
  echo "    Si vSphere < 8.0u2, les snapshots CSI ne sont pas supportés"
  echo "    sur le Supervisor / guest clusters TKG."
  echo ""
  exit 1
fi

# =============================================================================
section "3. Snapshot-controller sur le Supervisor"
# =============================================================================
SC_PODS=$(kubectl get pods -A \
  --field-selector=status.phase=Running \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
  | grep -c "snapshot-controller" || true)

if [ "${SC_PODS}" -gt 0 ]; then
  pass "snapshot-controller Running (${SC_PODS} pod(s))"
else
  warn "snapshot-controller non détecté (peut être nommé différemment sur le Supervisor)"
fi

# =============================================================================
section "4. VolumeSnapshotClass '${VSC_NAME}'"
# =============================================================================
if kubectl get volumesnapshotclass "${VSC_NAME}" &>/dev/null; then
  VSC_DRIVER=$(kubectl get volumesnapshotclass "${VSC_NAME}" \
    -o jsonpath='{.driver}')
  VSC_POLICY=$(kubectl get volumesnapshotclass "${VSC_NAME}" \
    -o jsonpath='{.deletionPolicy}')
  pass "${VSC_NAME} existe (driver=${VSC_DRIVER}, deletionPolicy=${VSC_POLICY})"
else
  warn "${VSC_NAME} absente — création..."
  kubectl apply -f - <<EOF
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshotClass
metadata:
  name: ${VSC_NAME}
  annotations:
    snapshot.storage.kubernetes.io/is-default-class: "true"
driver: ${CSI_DRIVER}
deletionPolicy: Delete
EOF
  pass "${VSC_NAME} créée"
fi

# =============================================================================
section "5. Annotation default-class"
# =============================================================================
DEFAULT_ANNOTATION=$(kubectl get volumesnapshotclass "${VSC_NAME}" \
  -o jsonpath='{.metadata.annotations.snapshot\.storage\.kubernetes\.io/is-default-class}' \
  2>/dev/null || true)

if [ "${DEFAULT_ANNOTATION}" = "true" ]; then
  pass "${VSC_NAME} marquée comme classe par défaut"
else
  info "Marquage de ${VSC_NAME} comme classe par défaut..."
  kubectl annotate volumesnapshotclass "${VSC_NAME}" \
    snapshot.storage.kubernetes.io/is-default-class=true --overwrite
  pass "Annotation default-class ajoutée"
fi

# =============================================================================
section "6. État final — VolumeSnapshotClasses sur le Supervisor"
# =============================================================================
echo ""
kubectl get volumesnapshotclass -o custom-columns=\
'NAME:.metadata.name,DRIVER:.driver,DELETION_POLICY:.deletionPolicy,DEFAULT:.metadata.annotations.snapshot\.storage\.kubernetes\.io/is-default-class'

# =============================================================================
# Vérification optionnelle dans le namespace TKG
# =============================================================================
if [ -n "${SV_NAMESPACE}" ]; then
  section "7. Vérification namespace ${SV_NAMESPACE}"

  if kubectl get namespace "${SV_NAMESPACE}" &>/dev/null; then
    pass "Namespace ${SV_NAMESPACE} existe"

    # Vérifier s'il y a des VolumeSnapshots en erreur
    VS_COUNT=$(kubectl get volumesnapshots -n "${SV_NAMESPACE}" \
      --no-headers 2>/dev/null | wc -l | tr -d ' ')
    if [ "${VS_COUNT}" -gt 0 ]; then
      info "VolumeSnapshots existants dans ${SV_NAMESPACE} :"
      kubectl get volumesnapshots -n "${SV_NAMESPACE}" \
        -o custom-columns='NAME:.metadata.name,READY:.status.readyToUse,AGE:.metadata.creationTimestamp'
    else
      info "Aucun VolumeSnapshot dans ${SV_NAMESPACE} (normal avant le premier backup)"
    fi
  else
    warn "Namespace ${SV_NAMESPACE} introuvable"
  fi
fi

# =============================================================================
echo ""
echo "============================================================"
echo -e " Résultat : ${GREEN}${PASS} PASS${NC} / ${YELLOW}${WARN} WARN${NC} / ${RED}${FAIL} FAIL${NC}"
echo "============================================================"
echo ""

if [ "${FAIL}" -gt 0 ]; then
  echo -e "${RED}Des erreurs subsistent.${NC}"
  exit 1
fi

echo -e "${GREEN}Supervisor prêt pour les VolumeSnapshots CSI.${NC}"
echo ""
echo "Prochaines étapes :"
echo "  1. Revenir sur le contexte du guest cluster"
echo "  2. Exécuter ./setup-tanzu-snapshot.sh (labelliser la VSC côté guest)"
echo "  3. Relancer le backup Velero"
echo ""
