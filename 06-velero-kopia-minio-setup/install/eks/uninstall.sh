#!/usr/bin/env bash
# =============================================================================
# Désinstallation de Velero (EKS)
# =============================================================================
set -eo pipefail

VELERO_NAMESPACE="${VELERO_NAMESPACE:-velero}"
HELM_RELEASE="${HELM_RELEASE:-velero}"

YELLOW='\033[1;33m'; NC='\033[0m'
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }

warn "Cette opération va supprimer Velero et le namespace '${VELERO_NAMESPACE}'."
warn "Les backups dans S3 ne seront PAS supprimés."
read -r -p "Confirmer ? (oui/non) : " CONFIRM
[ "${CONFIRM}" = "oui" ] || { echo "Annulé."; exit 0; }

helm uninstall "${HELM_RELEASE}" --namespace "${VELERO_NAMESPACE}" 2>/dev/null || true

# Supprimer les CRDs Velero
kubectl get crds -o name | grep velero | xargs -r kubectl delete

kubectl delete namespace "${VELERO_NAMESPACE}" --ignore-not-found

echo "Désinstallation terminée."
