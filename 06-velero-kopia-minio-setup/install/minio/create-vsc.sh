#!/usr/bin/env bash
# =============================================================================
# Création de la VolumeSnapshotClass annotée pour Velero VGDP
# Détecte automatiquement le driver CSI vSphere (Tanzu guest ou classique)
# =============================================================================
set -eo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

VSC_NAME="${VSC_NAME:-vsphere-vsc}"

# =============================================================================
# Détection du driver CSI vSphere
# =============================================================================
detect_csi_driver() {
  # Tanzu guest cluster (VMware paravirtual CSI)
  if kubectl get csidriver csi.vsphere.vmware.com &>/dev/null; then
    echo "csi.vsphere.vmware.com"
    return
  fi
  # vSphere CSI classique (on-premise, non-Tanzu)
  if kubectl get csidriver csi.vsphere.volume &>/dev/null; then
    echo "csi.vsphere.volume"
    return
  fi
  echo ""
}

# =============================================================================
# Main
# =============================================================================
echo ""
echo "=============================================="
echo " Création VolumeSnapshotClass pour Velero VGDP"
echo "=============================================="

# Détecter le driver
CSI_DRIVER=$(detect_csi_driver)
if [ -z "${CSI_DRIVER}" ]; then
  error "Aucun driver CSI vSphere trouvé (csi.vsphere.vmware.com ou csi.vsphere.volume)"
fi
info "Driver CSI détecté : ${CSI_DRIVER}"

# Vérifier si une VSC annotée existe déjà
EXISTING=$(kubectl get volumesnapshotclass \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.annotations.velero\.io/csi-volumesnapshot-class}{"\n"}{end}' \
  2>/dev/null | grep -E $'\ttrue$' | awk '{print $1}' || true)

if [ -n "${EXISTING}" ]; then
  warn "Une VolumeSnapshotClass annotée existe déjà : ${EXISTING}"
  warn "Continuer créera ${VSC_NAME} en supplément."
  read -r -p "Continuer quand même ? (oui/non) : " CONFIRM
  [ "${CONFIRM}" = "oui" ] || { echo "Annulé."; exit 0; }
fi

# Créer la VolumeSnapshotClass
info "Création de la VolumeSnapshotClass '${VSC_NAME}'..."
kubectl apply -f - <<EOF
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshotClass
metadata:
  name: ${VSC_NAME}
  annotations:
    velero.io/csi-volumesnapshot-class: "true"
driver: ${CSI_DRIVER}
deletionPolicy: Retain
EOF

# Vérification
echo ""
info "=== VolumeSnapshotClasses ==="
kubectl get volumesnapshotclass

echo ""
info "VolumeSnapshotClass '${VSC_NAME}' créée avec succès."
info "Vous pouvez maintenant lancer : ./install.sh"
