#!/usr/bin/env bash
# =============================================================================
# Desinstallation de Velero
#
# Les backups dans MinIO ne sont PAS supprimes.
# =============================================================================
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Charger config.env si disponible
CONFIG_FILE="${CONFIG_FILE:-${SCRIPT_DIR}/config.env}"
if [ -f "${CONFIG_FILE}" ]; then
  # shellcheck source=config.env.example
  source "${CONFIG_FILE}"
fi

VELERO_NAMESPACE="${VELERO_NAMESPACE:-velero}"
HELM_RELEASE="${HELM_RELEASE:-velero}"

RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

warn "Cette operation va supprimer Velero et le namespace '${VELERO_NAMESPACE}'."
warn "Les backups dans MinIO ne seront PAS supprimes."
read -r -p "Confirmer ? (o/n) : " CONFIRM
[ "${CONFIRM}" = "o" ] || { echo "Annule."; exit 0; }

helm uninstall "${HELM_RELEASE}" --namespace "${VELERO_NAMESPACE}" 2>/dev/null || true

# Supprimer les CRDs Velero
kubectl get crds -o name | grep velero | xargs -r kubectl delete

kubectl delete namespace "${VELERO_NAMESPACE}" --ignore-not-found

echo "Desinstallation terminee."
