#!/usr/bin/env bash
# =============================================================================
# Configuration VolumeSnapshot pour Tanzu guest cluster (CSI paravirtuel)
#
# En Tanzu guest, le CSI driver csi.vsphere.vmware.com propage les
# VolumeSnapshots vers le Supervisor Cluster. Il NE FAUT PAS creer de
# VolumeSnapshotClass custom — uniquement labelliser la classe pre-existante
# "volumesnapshotclass-delete" (creee automatiquement par le TKR).
#
# Ce script :
#   1. Verifie les prerequis (CRDs, snapshot-controller, CSI driver)
#   2. Verifie que volumesnapshotclass-delete existe
#   3. Labellise la VSC pour Velero (velero.io/csi-volumesnapshot-class=true)
#   4. Supprime toute VSC custom incompatible (vsphere-vsc)
#   5. Valide le resultat
#
# Prerequis infrastructure :
#   - vSphere >= 8.0 Update 2 (Supervisor avec snapshot CRDs)
#   - TKR >= v1.26.5
#   - Packages guest : cert-manager, vsphere-pv-csi-webhook
#
# Usage :
#   ./setup-guest-snapshot.sh
# =============================================================================
set -eo pipefail

# --- Configuration ---
EXPECTED_VSC="volumesnapshotclass-delete"
EXPECTED_DRIVER="csi.vsphere.vmware.com"
CUSTOM_VSC_TO_REMOVE="${CUSTOM_VSC_TO_REMOVE:-vsphere-vsc}"

# --- Couleurs ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
PASS=0; FAIL=0; WARN=0

pass()  { echo -e "  ${GREEN}[PASS]${NC} $*"; PASS=$((PASS + 1)); }
fail()  { echo -e "  ${RED}[FAIL]${NC} $*"; FAIL=$((FAIL + 1)); }
warn()  { echo -e "  ${YELLOW}[WARN]${NC} $*"; WARN=$((WARN + 1)); }
info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
section() { echo ""; echo -e "${YELLOW}--- $* ---${NC}"; }

echo ""
echo "============================================================"
echo " Configuration VolumeSnapshot — Tanzu guest cluster"
echo " CSI paravirtuel → Supervisor Cluster"
echo "============================================================"

# =============================================================================
section "1. Connectivite cluster"
# =============================================================================
kubectl cluster-info &>/dev/null \
  && pass "kubectl connecte au cluster" \
  || { fail "kubectl non connecte"; echo ""; exit 1; }

CTX=$(kubectl config current-context 2>/dev/null || echo "N/A")
echo "    Contexte actif : ${CTX}"

# =============================================================================
section "2. CSI driver paravirtuel"
# =============================================================================
if kubectl get csidriver "${EXPECTED_DRIVER}" &>/dev/null; then
  pass "CSI driver ${EXPECTED_DRIVER} present"
else
  fail "CSI driver ${EXPECTED_DRIVER} absent — ce script est prevu pour Tanzu guest"
  echo "    Pour un cluster vSphere classique (csi.vsphere.volume), adapter le driver."
  echo ""
  exit 1
fi

# =============================================================================
section "3. CRDs VolumeSnapshot"
# =============================================================================
for crd in \
  volumesnapshots.snapshot.storage.k8s.io \
  volumesnapshotcontents.snapshot.storage.k8s.io \
  volumesnapshotclasses.snapshot.storage.k8s.io; do
  kubectl get crd "$crd" &>/dev/null \
    && pass "CRD ${crd}" \
    || fail "CRD ${crd} absente — packages TKR manquants"
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
  echo "    → Verifier les packages TKR (vsphere-pv-csi-webhook)"
fi

# =============================================================================
section "5. VolumeSnapshotClass pre-existante"
# =============================================================================
if kubectl get volumesnapshotclass "${EXPECTED_VSC}" &>/dev/null; then
  VSC_DRIVER=$(kubectl get volumesnapshotclass "${EXPECTED_VSC}" \
    -o jsonpath='{.driver}')
  VSC_POLICY=$(kubectl get volumesnapshotclass "${EXPECTED_VSC}" \
    -o jsonpath='{.deletionPolicy}')

  if [ "${VSC_DRIVER}" = "${EXPECTED_DRIVER}" ]; then
    pass "${EXPECTED_VSC} : driver=${VSC_DRIVER}, deletionPolicy=${VSC_POLICY}"
  else
    fail "${EXPECTED_VSC} : driver inattendu ${VSC_DRIVER} (attendu: ${EXPECTED_DRIVER})"
  fi
else
  fail "${EXPECTED_VSC} absente"
  echo "    Cette VolumeSnapshotClass est normalement creee par le TKR."
  echo "    Prerequis : vSphere >= 8.0u2, TKR >= v1.26.5"
  echo "    Packages requis : cert-manager, vsphere-pv-csi-webhook"
fi

# --- Arreter si des prerequis manquent ---
if [ "${FAIL}" -gt 0 ]; then
  echo ""
  echo "============================================================"
  echo -e "${RED} ${FAIL} prerequis manquant(s) — corriger avant de continuer${NC}"
  echo "============================================================"
  exit 1
fi

# =============================================================================
section "6. Labellisation de ${EXPECTED_VSC} pour Velero"
# =============================================================================
CURRENT_LABEL=$(kubectl get volumesnapshotclass "${EXPECTED_VSC}" \
  -o jsonpath='{.metadata.labels.velero\.io/csi-volumesnapshot-class}' 2>/dev/null || true)

if [ "${CURRENT_LABEL}" = "true" ]; then
  pass "Label velero.io/csi-volumesnapshot-class=true deja present"
else
  info "Ajout du label velero.io/csi-volumesnapshot-class=true..."
  kubectl label volumesnapshotclass "${EXPECTED_VSC}" \
    velero.io/csi-volumesnapshot-class=true --overwrite
  pass "Label ajoute sur ${EXPECTED_VSC}"
fi

# =============================================================================
section "7. Verification des VSC custom potentiellement incompatibles"
# =============================================================================
if kubectl get volumesnapshotclass "${CUSTOM_VSC_TO_REMOVE}" &>/dev/null 2>&1; then
  warn "VolumeSnapshotClass custom '${CUSTOM_VSC_TO_REMOVE}' detectee"
  echo "    En Tanzu guest, les VSC custom avec deletionPolicy=Retain"
  echo "    ne sont pas supportees par le Supervisor et peuvent provoquer"
  echo "    des erreurs lors des snapshots."
  echo ""
  read -r -p "    Voulez-vous supprimer '${CUSTOM_VSC_TO_REMOVE}' ? (o/n) : " CONFIRM
  if [ "${CONFIRM}" = "o" ]; then
    kubectl delete volumesnapshotclass "${CUSTOM_VSC_TO_REMOVE}"
    pass "'${CUSTOM_VSC_TO_REMOVE}' supprimee"
  else
    warn "'${CUSTOM_VSC_TO_REMOVE}' conservee — verifier manuellement si elle pose probleme"
  fi
else
  pass "Aucune VSC custom '${CUSTOM_VSC_TO_REMOVE}' detectee"
fi

# =============================================================================
section "8. Etat final"
# =============================================================================
echo ""
info "VolumeSnapshotClasses actuelles :"
kubectl get volumesnapshotclass -o custom-columns=\
'NAME:.metadata.name,DRIVER:.driver,DELETION_POLICY:.deletionPolicy,VELERO_LABEL:.metadata.labels.velero\.io/csi-volumesnapshot-class'
echo ""

# =============================================================================
echo ""
echo "============================================================"
echo -e " Resultat : ${GREEN}${PASS} PASS${NC} / ${YELLOW}${WARN} WARN${NC} / ${RED}${FAIL} FAIL${NC}"
echo "============================================================"
echo ""

if [ "${FAIL}" -gt 0 ]; then
  echo -e "${RED}Des erreurs subsistent — corriger avant d'utiliser Velero${NC}"
  exit 1
fi

echo -e "${GREEN}Configuration VolumeSnapshot prete pour Velero VGDP.${NC}"
echo ""
echo "Rappels :"
echo "  - deletionPolicy=Delete est normal en VGDP (snapshot transient)"
echo "  - Le Supervisor ne supporte PAS deletionPolicy=Retain"
echo "  - Ne PAS creer de VolumeSnapshotClass custom en Tanzu guest"
echo ""
