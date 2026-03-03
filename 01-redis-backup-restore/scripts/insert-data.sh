#!/usr/bin/env bash
set -eo pipefail

# --- Configuration ---
NAMESPACE="${NAMESPACE:-redis-test}"
RELEASE="${RELEASE:-redis-test}"
POD_NAME="${RELEASE}-redis-0"

echo "=== Insertion de données de test dans Redis ==="
echo "Namespace : ${NAMESPACE}"
echo "Pod       : ${POD_NAME}"
echo ""

# Données de test (clé=valeur)
BACKUP_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
KEYS=(
  "test:key1=valeur_un"
  "test:key2=valeur_deux"
  "test:key3=valeur_trois"
  "test:compteur=42"
  "test:backup-date=${BACKUP_DATE}"
)

COUNT=0
for entry in "${KEYS[@]}"; do
  key="${entry%%=*}"
  value="${entry#*=}"
  kubectl exec -n "${NAMESPACE}" "${POD_NAME}" -- redis-cli SET "${key}" "${value}"
  echo "  SET ${key} = ${value}"
  COUNT=$((COUNT + 1))
done

echo ""
echo "=== ${COUNT} clés insérées avec succès ==="

# Forcer l'écriture sur disque (indispensable pour que le snapshot PV contienne les données)
echo ""
echo "Forçage de l'écriture sur disque (BGSAVE)..."
kubectl exec -n "${NAMESPACE}" "${POD_NAME}" -- redis-cli BGSAVE
sleep 3
echo "Dernier save : $(kubectl exec -n "${NAMESPACE}" "${POD_NAME}" -- redis-cli LASTSAVE)"

echo ""
echo "Vérification rapide :"
kubectl exec -n "${NAMESPACE}" "${POD_NAME}" -- redis-cli KEYS "test:*"
