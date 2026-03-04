#!/usr/bin/env bash
# =============================================================================
# Mise à jour du BackupStorageLocation Velero — CA cert depuis ConfigMap
#
# Ce script :
#   1. Crée/met à jour la ConfigMap velero-ca-cert depuis ca.crt
#   2. Lit le certificat depuis la ConfigMap (source de vérité)
#   3. Patche le BSL pour injecter le caCert (base64)
#   4. Attend que le BSL redevienne Available
#
# Usage :
#   ./update-bsl.sh                     # utilise les valeurs par défaut
#   CA_CERT_FILE=/path/to/ca.crt ./update-bsl.sh
#   BSL_NAME=secondary ./update-bsl.sh  # BSL autre que "default"
#
# Note : pour que le changement survive à un futur helm upgrade,
#        relancer install.sh (qui lit aussi la ConfigMap).
# =============================================================================
set -eo pipefail

# --- Configuration ---
VELERO_NAMESPACE="${VELERO_NAMESPACE:-velero}"
BSL_NAME="${BSL_NAME:-default}"
CA_CERT_FILE="${CA_CERT_FILE:-$(dirname "$0")/ca.crt}"
CONFIGMAP_NAME="${CONFIGMAP_NAME:-velero-ca-cert}"

# --- Couleurs ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $*" >&2; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*" >&2; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# =============================================================================
# Prérequis
# =============================================================================
check_prerequisites() {
  for cmd in kubectl base64; do
    command -v "$cmd" &>/dev/null || error "Commande manquante : $cmd"
  done

  [ -f "${CA_CERT_FILE}" ] || error "Fichier CA introuvable : ${CA_CERT_FILE}"

  kubectl cluster-info &>/dev/null || error "kubectl n'est pas connecté à un cluster"

  kubectl get backupstoragelocation "${BSL_NAME}" -n "${VELERO_NAMESPACE}" &>/dev/null \
    || error "BSL '${BSL_NAME}' introuvable dans le namespace '${VELERO_NAMESPACE}'"
}

# =============================================================================
# Créer / mettre à jour la ConfigMap avec le certificat CA (PEM brut)
# =============================================================================
update_ca_configmap() {
  info "Mise à jour de la ConfigMap ${CONFIGMAP_NAME} depuis ${CA_CERT_FILE}..."
  kubectl create configmap "${CONFIGMAP_NAME}" \
    --namespace "${VELERO_NAMESPACE}" \
    --from-file=ca-bundle.crt="${CA_CERT_FILE}" \
    --dry-run=client -o yaml | kubectl apply -f -
}

# =============================================================================
# Patcher le BSL avec le caCert lu depuis la ConfigMap
#
# Le champ spec.objectStorage.caCert est de type []byte :
# Kubernetes attend une valeur base64 dans le JSON/YAML.
# =============================================================================
patch_bsl() {
  info "Lecture du certificat depuis la ConfigMap ${CONFIGMAP_NAME}..."
  local ca_pem ca_b64
  ca_pem=$(kubectl get configmap "${CONFIGMAP_NAME}" \
    -n "${VELERO_NAMESPACE}" \
    -o go-template='{{index .data "ca-bundle.crt"}}')

  [ -n "${ca_pem}" ] || error "La ConfigMap ${CONFIGMAP_NAME} ne contient pas la clé ca-bundle.crt"

  # Encoder le PEM en base64 (format attendu par le champ caCert []byte)
  ca_b64=$(printf '%s' "${ca_pem}" | base64 | tr -d '\n')

  info "Patch du BSL '${BSL_NAME}' avec le certificat CA..."
  kubectl patch backupstoragelocation "${BSL_NAME}" \
    --namespace "${VELERO_NAMESPACE}" \
    --type merge \
    -p "{\"spec\":{\"objectStorage\":{\"caCert\":\"${ca_b64}\"}}}"
}

# =============================================================================
# Attendre que le BSL redevienne Available
# =============================================================================
wait_bsl_available() {
  info "Attente de la validation du BSL '${BSL_NAME}' (max 90s)..."
  local attempt=0 max_attempts=18 phase=""
  while [ "${attempt}" -lt "${max_attempts}" ]; do
    phase=$(kubectl get backupstoragelocation "${BSL_NAME}" \
      -n "${VELERO_NAMESPACE}" \
      -o jsonpath='{.status.phase}' 2>/dev/null || true)
    if [ "${phase}" = "Available" ]; then
      info "BSL '${BSL_NAME}' : Available"
      return 0
    fi
    attempt=$((attempt + 1))
    sleep 5
  done
  warn "BSL '${BSL_NAME}' non Available après 90s (phase actuelle : ${phase:-inconnue})"
  warn "Vérifier : kubectl describe bsl ${BSL_NAME} -n ${VELERO_NAMESPACE}"
  return 1
}

# =============================================================================
# Main
# =============================================================================
main() {
  echo "" >&2
  echo "==============================================" >&2
  echo " Mise à jour BSL Velero — CA cert via ConfigMap" >&2
  echo "==============================================" >&2
  echo "  Namespace  : ${VELERO_NAMESPACE}" >&2
  echo "  BSL        : ${BSL_NAME}" >&2
  echo "  ConfigMap  : ${CONFIGMAP_NAME}" >&2
  echo "  CA cert    : ${CA_CERT_FILE}" >&2
  echo "==============================================" >&2
  echo "" >&2

  check_prerequisites
  update_ca_configmap
  patch_bsl
  wait_bsl_available

  echo "" >&2
  info "Mise à jour terminée."
  info "État actuel du BSL :"
  kubectl get backupstoragelocation "${BSL_NAME}" -n "${VELERO_NAMESPACE}"
}

main "$@"
