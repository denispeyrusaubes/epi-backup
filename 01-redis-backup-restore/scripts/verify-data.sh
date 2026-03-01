#!/usr/bin/env bash
set -eo pipefail

# --- Configuration ---
NAMESPACE="${NAMESPACE:-redis-test}"
RELEASE="${RELEASE:-redis-test}"
POD_NAME="${RELEASE}-redis-0"

echo "=== Vérification des données Redis après restore ==="
echo "Namespace : ${NAMESPACE}"
echo "Pod       : ${POD_NAME}"
echo ""

# Données attendues (clé=valeur)
EXPECTED=(
  "test:key1=valeur_un"
  "test:key2=valeur_deux"
  "test:key3=valeur_trois"
  "test:compteur=42"
)

PASS=0
FAIL=0

for entry in "${EXPECTED[@]}"; do
  key="${entry%%=*}"
  expected="${entry#*=}"
  actual=$(kubectl exec -n "${NAMESPACE}" "${POD_NAME}" -- redis-cli GET "${key}" 2>/dev/null || echo "ERREUR")

  if [ "${actual}" = "${expected}" ]; then
    echo "  [PASS] ${key} = ${actual}"
    ((PASS++))
  else
    echo "  [FAIL] ${key} : attendu '${expected}', obtenu '${actual}'"
    ((FAIL++))
  fi
done

# Vérifier que la clé backup-date existe
backup_date=$(kubectl exec -n "${NAMESPACE}" "${POD_NAME}" -- redis-cli GET "test:backup-date" 2>/dev/null || echo "")
if [ -n "${backup_date}" ]; then
  echo "  [PASS] test:backup-date = ${backup_date}"
  ((PASS++))
else
  echo "  [FAIL] test:backup-date : clé absente"
  ((FAIL++))
fi

echo ""
echo "=== Résultat : ${PASS} PASS / ${FAIL} FAIL ==="

if [ "${FAIL}" -gt 0 ]; then
  echo "ERREUR : certaines données n'ont pas été restaurées correctement."
  exit 1
else
  echo "SUCCES : toutes les données ont été restaurées correctement."
  exit 0
fi
