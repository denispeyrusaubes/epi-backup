#!/usr/bin/env bash
# =============================================================================
# Installation de Velero avec Kopia + MinIO (Tanzu/vSphere) via Helm
# Mode VGDP : CSI VolumeSnapshot + DataUpload/DataDownload Kopia
#
# Configuration lue depuis config.env (voir config.env.example)
# =============================================================================
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- Charger la configuration ---
CONFIG_FILE="${CONFIG_FILE:-${SCRIPT_DIR}/config.env}"
if [ ! -f "${CONFIG_FILE}" ]; then
  echo "ERREUR : Fichier de configuration introuvable : ${CONFIG_FILE}" >&2
  echo "  Copier le template : cp config.env.example config.env" >&2
  exit 1
fi
# shellcheck source=config.env.example
source "${CONFIG_FILE}"

# --- Variables (avec valeurs par defaut) ---
VELERO_NAMESPACE="${VELERO_NAMESPACE:-velero}"
HELM_RELEASE="${HELM_RELEASE:-velero}"
HELM_REPO_URL="https://vmware-tanzu.github.io/helm-charts"
CHART_VERSION="${CHART_VERSION:-11.4.0}"
MINIO_URL="${MINIO_URL:?MINIO_URL est obligatoire dans config.env}"
MINIO_BUCKET="${MINIO_BUCKET:-velero-pra}"
MINIO_REGION="${MINIO_REGION:-minio}"
CREDENTIALS_FILE="${CREDENTIALS_FILE:-${SCRIPT_DIR}/credentials}"
CA_CERT_FILE="${CA_CERT_FILE:-${SCRIPT_DIR}/ca.crt}"
VALUES_TEMPLATE="${SCRIPT_DIR}/values.yaml"

# --- Couleurs ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# =============================================================================
# Prerequis
# =============================================================================
check_prerequisites() {
  info "Verification des prerequis..."
  for cmd in kubectl helm base64; do
    command -v "$cmd" &>/dev/null || error "Commande manquante : $cmd"
  done

  [ -f "${CREDENTIALS_FILE}" ] || error "Fichier credentials introuvable : ${CREDENTIALS_FILE}\n  Copier le template : cp credentials.example credentials"
  [ -f "${CA_CERT_FILE}" ]     || error "Fichier CA introuvable : ${CA_CERT_FILE}"
  [ -f "${VALUES_TEMPLATE}" ]  || error "Fichier values.yaml introuvable : ${VALUES_TEMPLATE}"

  # Verifier que le mot de passe a ete renseigne
  grep -q "CHANGE_ME" "${CREDENTIALS_FILE}" && \
    error "Mot de passe non renseigne dans ${CREDENTIALS_FILE} (remplacer CHANGE_ME)"

  kubectl cluster-info &>/dev/null || error "kubectl n'est pas connecte a un cluster"

  # Verifier que le CSI et la VolumeSnapshotClass sont prets (prerequis VGDP)
  info "Verification des prerequis VGDP (CSI VolumeSnapshotClass)..."
  VSC_COUNT=$(kubectl get volumesnapshotclass \
    -l velero.io/csi-volumesnapshot-class=true \
    -o jsonpath='{range .items[*]}{.metadata.name}{end}' \
    2>/dev/null | wc -w | tr -d ' ')
  if [ "${VSC_COUNT}" -eq 0 ]; then
    warn "Aucune VolumeSnapshotClass avec le label 'velero.io/csi-volumesnapshot-class: true' trouvee."
    warn "VGDP (snapshotMoveData) ne fonctionnera pas sans cette ressource."
    warn "Executer d'abord : cd ../prerequisites && ./setup-guest-snapshot.sh"
    read -r -p "Continuer quand meme ? (o/n) : " CONFIRM
    [ "${CONFIRM}" = "o" ] || { echo "Annule."; exit 0; }
  else
    info "VolumeSnapshotClass VGDP trouvee : OK"
  fi

  info "Prerequis OK"
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
  info "Creation du namespace ${VELERO_NAMESPACE}..."
  kubectl create namespace "${VELERO_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
}

# =============================================================================
# Secret credentials MinIO
# =============================================================================
create_credentials_secret() {
  info "Creation du secret velero-credentials (MinIO)..."
  kubectl create secret generic velero-credentials \
    --namespace "${VELERO_NAMESPACE}" \
    --from-file=cloud="${CREDENTIALS_FILE}" \
    --dry-run=client -o yaml | kubectl apply -f -
}

# =============================================================================
# Generation du values.yaml final
# =============================================================================
generate_values() {
  info "Generation du values.yaml avec les parametres de config.env..."
  local values_file="${SCRIPT_DIR}/values-generated.yaml"

  sed \
    -e "s|__MINIO_BUCKET__|${MINIO_BUCKET}|g" \
    -e "s|__MINIO_REGION__|${MINIO_REGION}|g" \
    -e "s|__MINIO_URL__|${MINIO_URL}|g" \
    "${VALUES_TEMPLATE}" > "${values_file}"

  echo "${values_file}"
}

# =============================================================================
# Installation Helm
# =============================================================================
install_velero() {
  # Generer le values.yaml final
  local generated_values
  generated_values=$(generate_values)

  # Lire le certificat CA directement depuis le fichier et l'encoder en base64
  info "Encodage du certificat CA depuis ${CA_CERT_FILE}..."
  local ca_cert_b64
  ca_cert_b64=$(base64 < "${CA_CERT_FILE}" | tr -d '\n')

  info "Installation de Velero via Helm (chart version ${CHART_VERSION})..."
  helm upgrade --install "${HELM_RELEASE}" vmware-tanzu/velero \
    --namespace "${VELERO_NAMESPACE}" \
    --version "${CHART_VERSION}" \
    --values "${generated_values}" \
    --set-string "configuration.backupStorageLocation[0].config.caCert=${ca_cert_b64}" \
    --wait \
    --timeout 5m

  # Nettoyage du fichier genere
  rm -f "${generated_values}"
}

# =============================================================================
# Verification post-install
# =============================================================================
verify_install() {
  info "Attente que Velero soit pret..."
  kubectl rollout status deployment/"${HELM_RELEASE}" -n "${VELERO_NAMESPACE}" --timeout=3m

  info "Attente que le node-agent DaemonSet soit pret..."
  kubectl rollout status daemonset/node-agent -n "${VELERO_NAMESPACE}" --timeout=3m

  info ""
  info "=== Etat post-installation ==="
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
  echo "  MinIO URL  : ${MINIO_URL}"
  echo "  Bucket     : ${MINIO_BUCKET}"
  echo "  Region     : ${MINIO_REGION}"
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
  info "Installation terminee avec succes."
  info "Verifier la connectivite MinIO avec : kubectl get backupstoragelocation -n ${VELERO_NAMESPACE}"
  info "Le statut doit etre 'Available' (peut prendre 30-60s)."
  info ""
  info "Lancer la verification complete :"
  info "  cd ../verify && ./verify-setup.sh"
}

main "$@"
