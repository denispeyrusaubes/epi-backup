#!/usr/bin/env bash
# =============================================================================
# check-velero-snapshot-prereqs.sh
#
# Valide tous les prérequis pour utiliser Velero + Kopia en mode
# CSI Snapshot Data Movement sur un Guest Cluster Tanzu.
#
# Usage : ./check-velero-snapshot-prereqs.sh
# =============================================================================

set -euo pipefail

# --- Couleurs & symboles ----------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

PASS="${GREEN}✔ PASS${NC}"
FAIL="${RED}✘ FAIL${NC}"
WARN="${YELLOW}⚠ WARN${NC}"

total=0
passed=0
failed=0
warnings=0

check_pass()  { ((total++)); ((passed++));   echo -e "  ${PASS}  $1"; }
check_fail()  { ((total++)); ((failed++));   echo -e "  ${FAIL}  $1"; }
check_warn()  { ((total++)); ((warnings++)); echo -e "  ${WARN}  $1"; }

separator() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD} $1${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# --- Vérification kubectl ----------------------------------------------------
if ! command -v kubectl &>/dev/null; then
    echo -e "${FAIL} kubectl n'est pas installé ou pas dans le PATH. Abandon."
    exit 1
fi

if ! kubectl cluster-info &>/dev/null; then
    echo -e "${FAIL} Impossible de contacter le cluster Kubernetes. Vérifie ton kubeconfig."
    exit 1
fi

CLUSTER_CONTEXT=$(kubectl config current-context 2>/dev/null || echo "inconnu")
echo ""
echo -e "${BOLD}Cluster contexte : ${CYAN}${CLUSTER_CONTEXT}${NC}"
echo -e "${BOLD}Date              : $(date)${NC}"

# =============================================================================
# 1. CRDs VolumeSnapshot
# =============================================================================
separator "1. CRDs VolumeSnapshot (snapshot.storage.k8s.io)"

EXPECTED_CRDS=(
    "volumesnapshots.snapshot.storage.k8s.io"
    "volumesnapshotcontents.snapshot.storage.k8s.io"
    "volumesnapshotclasses.snapshot.storage.k8s.io"
)

EXISTING_CRDS=$(kubectl get crd -o name 2>/dev/null || echo "")

for crd in "${EXPECTED_CRDS[@]}"; do
    if echo "${EXISTING_CRDS}" | grep -q "${crd}"; then
        # Vérifier la version API
        API_VERSION=$(kubectl get crd "${crd}" -o jsonpath='{.spec.versions[*].name}' 2>/dev/null)
        if echo "${API_VERSION}" | grep -q "v1"; then
            check_pass "${crd}  (API: ${API_VERSION})"
        else
            check_warn "${crd} présent mais en ${API_VERSION} (v1 recommandé)"
        fi
    else
        check_fail "${crd} — CRD manquant"
    fi
done

# =============================================================================
# 2. Snapshot Controller
# =============================================================================
separator "2. Snapshot Controller"

SNAPSHOT_PODS=$(kubectl get pods -A -l app=snapshot-controller \
    --no-headers 2>/dev/null || true)

if [[ -z "${SNAPSHOT_PODS}" ]]; then
    # Fallback : chercher par nom
    SNAPSHOT_PODS=$(kubectl get pods -A --no-headers 2>/dev/null \
        | grep -i "snapshot-controller" || true)
fi

if [[ -n "${SNAPSHOT_PODS}" ]]; then
    RUNNING_COUNT=$(echo "${SNAPSHOT_PODS}" | grep -c "Running" || true)
    TOTAL_COUNT=$(echo "${SNAPSHOT_PODS}" | wc -l | tr -d ' ')
    if [[ "${RUNNING_COUNT}" -eq "${TOTAL_COUNT}" ]]; then
        check_pass "Snapshot controller : ${RUNNING_COUNT}/${TOTAL_COUNT} pod(s) Running"
    else
        check_fail "Snapshot controller : seulement ${RUNNING_COUNT}/${TOTAL_COUNT} pod(s) Running"
    fi
    echo "${SNAPSHOT_PODS}" | awk '{printf "         %-50s %-12s %s\n", $2, $1, $4}'
else
    check_fail "Aucun pod snapshot-controller trouvé"
fi

# =============================================================================
# 3. vSphere CSI Driver
# =============================================================================
separator "3. vSphere CSI Driver"

CSI_DRIVER=$(kubectl get csidrivers -o name 2>/dev/null | grep -i vsphere || true)

if [[ -n "${CSI_DRIVER}" ]]; then
    DRIVER_NAME=$(echo "${CSI_DRIVER}" | sed 's|csidriver.storage.k8s.io/||')
    check_pass "CSI Driver enregistré : ${DRIVER_NAME}"
else
    check_fail "Aucun CSI driver vSphere trouvé (csi.vsphere.vmware.com)"
fi

# Vérifier les pods CSI
CSI_NS="vmware-system-csi"
CSI_PODS=$(kubectl get pods -n "${CSI_NS}" --no-headers 2>/dev/null || true)

if [[ -n "${CSI_PODS}" ]]; then
    CSI_RUNNING=$(echo "${CSI_PODS}" | grep -c "Running" || true)
    CSI_TOTAL=$(echo "${CSI_PODS}" | wc -l | tr -d ' ')
    if [[ "${CSI_RUNNING}" -eq "${CSI_TOTAL}" ]]; then
        check_pass "Pods CSI (ns: ${CSI_NS}) : ${CSI_RUNNING}/${CSI_TOTAL} Running"
    else
        check_fail "Pods CSI (ns: ${CSI_NS}) : ${CSI_RUNNING}/${CSI_TOTAL} Running"
    fi
else
    check_warn "Namespace ${CSI_NS} introuvable — les pods CSI sont peut-être dans un autre namespace"
fi

# =============================================================================
# 4. VolumeSnapshotClass
# =============================================================================
separator "4. VolumeSnapshotClass"

VSC_LIST=$(kubectl get volumesnapshotclass --no-headers 2>/dev/null || true)

if [[ -n "${VSC_LIST}" ]]; then
    VSPHERE_VSC=$(echo "${VSC_LIST}" | grep -i "vsphere" || true)
    if [[ -n "${VSPHERE_VSC}" ]]; then
        VSC_NAME=$(echo "${VSPHERE_VSC}" | awk '{print $1}' | head -1)
        VSC_POLICY=$(kubectl get volumesnapshotclass "${VSC_NAME}" \
            -o jsonpath='{.deletionPolicy}' 2>/dev/null || echo "N/A")
        check_pass "VolumeSnapshotClass '${VSC_NAME}' (deletionPolicy: ${VSC_POLICY})"
    else
        check_warn "VolumeSnapshotClass(es) trouvée(s) mais aucune pour le driver vSphere :"
        echo "${VSC_LIST}" | awk '{printf "         %s (driver: %s)\n", $1, $2}'
    fi
else
    check_fail "Aucune VolumeSnapshotClass trouvée — à créer manuellement"
fi

# =============================================================================
# 5. StorageClass avec provisioner vSphere CSI
# =============================================================================
separator "5. StorageClass (provisioner vSphere CSI)"

SC_LIST=$(kubectl get storageclass --no-headers 2>/dev/null || true)

if [[ -n "${SC_LIST}" ]]; then
    FOUND_VSPHERE_SC=false
    while IFS= read -r line; do
        SC_NAME=$(echo "${line}" | awk '{print $1}')
        SC_PROV=$(kubectl get storageclass "${SC_NAME}" \
            -o jsonpath='{.provisioner}' 2>/dev/null)
        SC_DEFAULT=""
        if echo "${line}" | grep -q "(default)"; then
            SC_DEFAULT=" [default]"
        fi
        if echo "${SC_PROV}" | grep -qi "vsphere"; then
            check_pass "StorageClass '${SC_NAME}' — provisioner: ${SC_PROV}${SC_DEFAULT}"
            FOUND_VSPHERE_SC=true
        fi
    done <<< "${SC_LIST}"
    if [[ "${FOUND_VSPHERE_SC}" == false ]]; then
        check_fail "Aucune StorageClass avec provisioner vSphere CSI"
    fi
else
    check_fail "Aucune StorageClass trouvée"
fi

# =============================================================================
# 6. Velero + Plugin CSI
# =============================================================================
separator "6. Velero"

VELERO_NS="velero"
VELERO_PODS=$(kubectl get pods -n "${VELERO_NS}" --no-headers 2>/dev/null || true)

if [[ -n "${VELERO_PODS}" ]]; then
    VELERO_SERVER=$(echo "${VELERO_PODS}" | grep -E "^velero-" | grep -v node-agent || true)
    if [[ -n "${VELERO_SERVER}" ]]; then
        VELERO_STATUS=$(echo "${VELERO_SERVER}" | awk '{print $3}' | head -1)
        if [[ "${VELERO_STATUS}" == "Running" ]]; then
            check_pass "Velero server : Running"
        else
            check_fail "Velero server : ${VELERO_STATUS}"
        fi
    else
        check_fail "Pod Velero server introuvable dans le namespace ${VELERO_NS}"
    fi
else
    check_fail "Aucun pod dans le namespace ${VELERO_NS} — Velero n'est pas installé"
fi

# Plugin CSI
if command -v velero &>/dev/null; then
    PLUGINS=$(velero plugin get 2>/dev/null || true)
    if echo "${PLUGINS}" | grep -qi "csi"; then
        check_pass "Plugin CSI Velero détecté"
    else
        check_warn "Plugin CSI non visible via 'velero plugin get' — vérifie l'initContainer du deploy"
    fi
else
    # Fallback : vérifier dans le deployment
    CSI_PLUGIN=$(kubectl get deployment velero -n "${VELERO_NS}" \
        -o jsonpath='{.spec.template.spec.initContainers[*].image}' 2>/dev/null || true)
    if echo "${CSI_PLUGIN}" | grep -qi "csi"; then
        check_pass "Plugin CSI détecté dans le deployment Velero (initContainer)"
    else
        check_warn "CLI velero absente et plugin CSI non détecté dans le deployment"
    fi
fi

# =============================================================================
# 7. Node-Agent DaemonSet
# =============================================================================
separator "7. Node-Agent (Data Mover)"

NODE_AGENT_DS=$(kubectl get daemonset -n "${VELERO_NS}" --no-headers 2>/dev/null \
    | grep -i "node-agent" || true)

if [[ -n "${NODE_AGENT_DS}" ]]; then
    DESIRED=$(echo "${NODE_AGENT_DS}" | awk '{print $2}')
    READY=$(echo "${NODE_AGENT_DS}" | awk '{print $4}')
    if [[ "${DESIRED}" -eq "${READY}" && "${READY}" -gt 0 ]]; then
        check_pass "DaemonSet node-agent : ${READY}/${DESIRED} pods Ready"
    else
        check_fail "DaemonSet node-agent : ${READY}/${DESIRED} pods Ready"
    fi
else
    check_fail "DaemonSet node-agent introuvable — Velero installé sans --use-node-agent ?"
fi

# =============================================================================
# 8. BackupStorageLocation
# =============================================================================
separator "8. BackupStorageLocation"

if command -v velero &>/dev/null; then
    BSL_OUTPUT=$(velero backup-location get 2>/dev/null || true)
    if echo "${BSL_OUTPUT}" | grep -qi "Available"; then
        BSL_NAME=$(echo "${BSL_OUTPUT}" | grep -i "available" | awk '{print $1}' | head -1)
        check_pass "BSL '${BSL_NAME}' : Available"
    elif echo "${BSL_OUTPUT}" | grep -qi "Unavailable"; then
        BSL_NAME=$(echo "${BSL_OUTPUT}" | grep -i "unavailable" | awk '{print $1}' | head -1)
        check_fail "BSL '${BSL_NAME}' : Unavailable — vérifie les credentials / accès bucket"
    else
        check_warn "Impossible de déterminer le statut du BSL"
    fi
else
    BSL_RESOURCES=$(kubectl get backupstoragelocations -n "${VELERO_NS}" --no-headers 2>/dev/null || true)
    if [[ -n "${BSL_RESOURCES}" ]]; then
        BSL_PHASE=$(echo "${BSL_RESOURCES}" | awk '{print $1, $3}' | head -1)
        if echo "${BSL_PHASE}" | grep -qi "available"; then
            check_pass "BSL détecté (via kubectl) : ${BSL_PHASE}"
        else
            check_fail "BSL détecté mais status : ${BSL_PHASE}"
        fi
    else
        check_fail "Aucun BackupStorageLocation trouvé"
    fi
fi

# =============================================================================
# 9. Feature flags Velero (snapshotMoveData)
# =============================================================================
separator "9. Configuration Velero (optionnel)"

VELERO_ARGS=$(kubectl get deployment velero -n "${VELERO_NS}" \
    -o jsonpath='{.spec.template.spec.containers[0].args}' 2>/dev/null || true)

if echo "${VELERO_ARGS}" | grep -q "snapshot-move-data"; then
    check_pass "Flag --snapshot-move-data détecté dans les args du deployment"
else
    check_warn "--snapshot-move-data non détecté dans le deployment — à passer au niveau du Backup CR"
fi

# Vérifier le defaultSnapshotMoveData dans le serveur
DEFAULT_SMD=$(kubectl get deployment velero -n "${VELERO_NS}" \
    -o jsonpath='{.spec.template.spec.containers[0].args}' 2>/dev/null \
    | tr ',' '\n' | grep -i "default-snapshot-move-data" || true)

if [[ -n "${DEFAULT_SMD}" ]]; then
    check_pass "default-snapshot-move-data configuré : ${DEFAULT_SMD}"
else
    check_warn "default-snapshot-move-data non défini — tu devras ajouter snapshotMoveData: true dans chaque Backup"
fi

# =============================================================================
# Résumé
# =============================================================================
echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD} RÉSUMÉ${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  Total checks : ${total}"
echo -e "  ${GREEN}✔ Passed${NC}   : ${passed}"
echo -e "  ${RED}✘ Failed${NC}   : ${failed}"
echo -e "  ${YELLOW}⚠ Warnings${NC} : ${warnings}"
echo ""

if [[ "${failed}" -eq 0 && "${warnings}" -eq 0 ]]; then
    echo -e "  ${GREEN}${BOLD}🎉 Tout est bon ! Tu peux lancer un backup avec snapshotMoveData: true${NC}"
elif [[ "${failed}" -eq 0 ]]; then
    echo -e "  ${YELLOW}${BOLD}⚠  Quelques warnings à vérifier, mais pas de blocage critique.${NC}"
else
    echo -e "  ${RED}${BOLD}✘  ${failed} check(s) en échec — à corriger avant de tester le backup.${NC}"
fi

echo ""
exit "${failed}"