#!/usr/bin/env bash
# =============================================================================
# Installation de Velero avec Kopia + MinIO (Tanzu/vSphere) via Helm
# Mode VGDP : CSI VolumeSnapshot + DataUpload/DataDownload Kopia
# =============================================================================
set -eo pipefail

# --- Configuration ---
VELERO_NAMESPACE="${VELERO_NAMESPACE:-velero}"
HELM_RELEASE="${HELM_RELEASE:-velero}"
HELM_REPO_URL="https://vmware-tanzu.github.io/helm-charts"
CHART_VERSION="${CHART_VERSION:-11.4.0}"   # Velero 1.17.1 — VGDP (Generic Data Path)
CREDENTIALS_FILE="${CREDENTIALS_FILE:-$(dirname "$0")/credentials}"
CA_CERT_FILE="${CA_CERT_FILE:-$(dirname "$0")/ca.crt}"
VALUES_FILE="${VALUES_FILE:-$(dirname "$0")/values.yaml}"

# --- Couleurs ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# =============================================================================
# Prérequis
# =============================================================================
check_prerequisites() {
  info "Vérification des prérequis..."
  for cmd in kubectl helm base64; do
    command -v "$cmd" &>/dev/null || error "Commande manquante : $cmd"
  done

  [ -f "${CREDENTIALS_FILE}" ] || error "Fichier credentials introuvable : ${CREDENTIALS_FILE}"
  [ -f "${CA_CERT_FILE}" ]     || error "Fichier CA introuvable : ${CA_CERT_FILE}"
  [ -f "${VALUES_FILE}" ]      || error "Fichier values.yaml introuvable : ${VALUES_FILE}"

  # Vérifier que le mot de passe a été renseigné
  grep -q "CHANGE_ME" "${CREDENTIALS_FILE}" && \
    error "Mot de passe non renseigné dans ${CREDENTIALS_FILE} (remplacer CHANGE_ME)"

  kubectl cluster-info &>/dev/null || error "kubectl n'est pas connecté à un cluster"

  # Vérifier que le CSI et la VolumeSnapshotClass sont prêts (prérequis VGDP)
  info "Vérification des prérequis VGDP (CSI VolumeSnapshotClass)..."
  VSC_COUNT=$(kubectl get volumesnapshotclass \
    -o jsonpath='{.items[?(@.metadata.annotations.velero\.io/csi-volumesnapshot-class=="true")].metadata.name}' \
    2>/dev/null | wc -w | tr -d ' ')
  if [ "${VSC_COUNT}" -eq 0 ]; then
    warn "Aucune VolumeSnapshotClass avec l'annotation 'velero.io/csi-volumesnapshot-class: true' trouvée."
    warn "VGDP (snapshotMoveData) ne fonctionnera pas sans cette ressource."
    warn "Créer une VolumeSnapshotClass annotée pour le CSI driver du cluster (ex: csi.vsphere.volume)."
    read -r -p "Continuer quand même ? (oui/non) : " CONFIRM
    [ "${CONFIRM}" = "oui" ] || { echo "Annulé."; exit 0; }
  else
    info "VolumeSnapshotClass VGDP trouvée : OK"
  fi

  info "Prérequis OK"
}

# =============================================================================
# Repo Helm
# =============================================================================
add_helm_repo() {
  info "Ajout du repo Helm vmware-tanzu..."
  helm repo add vmware-tanzu "${HELM_REPO_URL}" --force-update
  helm repo update vmware-tanzu
}

# =============================================================================
# Namespace
# =============================================================================
create_namespace() {
  info "Création du namespace ${VELERO_NAMESPACE}..."
  kubectl create namespace "${VELERO_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
}

# =============================================================================
# Secret credentials MinIO
# =============================================================================
create_credentials_secret() {
  info "Création du secret velero-credentials (MinIO)..."
  kubectl create secret generic velero-credentials \
    --namespace "${VELERO_NAMESPACE}" \
    --from-file=cloud="${CREDENTIALS_FILE}" \
    --dry-run=client -o yaml | kubectl apply -f -
}

# =============================================================================
# CA cert — base64 encode pour injection dans le BSL config
# =============================================================================
encode_ca_cert() {
  info "Encodage du certificat CA (chaîne complète)..."
  base64 < "${CA_CERT_FILE}" | tr -d '\n'
}

# =============================================================================
# Installation Helm
# =============================================================================
install_velero() {
  local ca_cert_b64
  ca_cert_b64="$(encode_ca_cert)"

  info "Installation de Velero via Helm (chart version ${CHART_VERSION})..."
  helm upgrade --install "${HELM_RELEASE}" vmware-tanzu/velero \
    --namespace "${VELERO_NAMESPACE}" \
    --version "${CHART_VERSION}" \
    --values "${VALUES_FILE}" \
    --set "configuration.backupStorageLocation[0].config.caCert=${ca_cert_b64}" \
    --wait \
    --timeout 5m
}

# =============================================================================
# Vérification post-install
# =============================================================================
verify_install() {
  info "Attente que Velero soit prêt..."
  kubectl rollout status deployment/"${HELM_RELEASE}" -n "${VELERO_NAMESPACE}" --timeout=3m

  info "Attente que le node-agent DaemonSet soit prêt..."
  kubectl rollout status daemonset/node-agent -n "${VELERO_NAMESPACE}" --timeout=3m

  info ""
  info "=== État post-installation ==="
  kubectl get all -n "${VELERO_NAMESPACE}"

  info ""
  info "=== BackupStorageLocation ==="
  kubectl get backupstoragelocation -n "${VELERO_NAMESPACE}"

  info ""
  info "=== Feature flags Velero ==="
  kubectl get deployment "${HELM_RELEASE}" -n "${VELERO_NAMESPACE}" \
    -o jsonpath='{.spec.template.spec.containers[0].args}' | tr ',' '\n' | grep -i feature || true
}

# =============================================================================
# Main
# =============================================================================
main() {
  echo ""
  echo "=============================================="
  echo " Installation Velero + Kopia + MinIO (VGDP)"
  echo "=============================================="
  echo "  Namespace  : ${VELERO_NAMESPACE}"
  echo "  Release    : ${HELM_RELEASE}"
  echo "  Chart ver  : ${CHART_VERSION}"
  echo "  MinIO URL  : https://labnousvrminio.d83.tes.local:9000"
  echo "  CA cert    : ${CA_CERT_FILE}"
  echo "  Credentials: ${CREDENTIALS_FILE}"
  echo "=============================================="
  echo ""

  check_prerequisites
  add_helm_repo
  create_namespace
  create_credentials_secret
  install_velero
  verify_install

  echo ""
  info "Installation terminée avec succès."
  info "Vérifier la connectivité MinIO avec : kubectl get backupstoragelocation -n ${VELERO_NAMESPACE}"
  info "Le statut doit être 'Available' (peut prendre 30-60s)."
  info ""
  info "Lancer la vérification complète :"
  info "  ../../verify/verify-setup.sh"
}

main "$@"
