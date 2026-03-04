#!/usr/bin/env bash
set -eo pipefail

# --- Configuration ---
NAMESPACE="${NAMESPACE:-kafka-test}"
RELEASE="${RELEASE:-kafka-test}"
POD_NAME="${RELEASE}-kafka-0"
TOPIC="velero-backup-test"
EXPECTED_MESSAGES=10

echo "=== Vérification des données Kafka après restore ==="
echo "Namespace : ${NAMESPACE}"
echo "Pod       : ${POD_NAME}"
echo "Topic     : ${TOPIC}"
echo ""

# Vérifier que le topic existe
echo "Vérification de l'existence du topic..."
TOPICS=$(kubectl exec -n "${NAMESPACE}" "${POD_NAME}" -- \
  /opt/kafka/bin/kafka-topics.sh \
    --list \
    --bootstrap-server localhost:9092)

if echo "${TOPICS}" | grep -q "^${TOPIC}$"; then
  echo "  [PASS] Le topic '${TOPIC}' existe"
else
  echo "  [FAIL] Le topic '${TOPIC}' n'existe pas"
  exit 1
fi

echo ""

# Afficher la description du topic
echo "Description du topic après restore :"
kubectl exec -n "${NAMESPACE}" "${POD_NAME}" -- \
  /opt/kafka/bin/kafka-topics.sh \
    --describe \
    --topic "${TOPIC}" \
    --bootstrap-server localhost:9092

echo ""

# Consommer les messages et compter
echo "Lecture des messages depuis le début..."
MESSAGES=$(kubectl exec -n "${NAMESPACE}" "${POD_NAME}" -- \
  /opt/kafka/bin/kafka-console-consumer.sh \
    --topic "${TOPIC}" \
    --from-beginning \
    --timeout-ms 10000 \
    --bootstrap-server localhost:9092 2>/dev/null || true)

NB_RECEIVED=$(echo "${MESSAGES}" | grep -c "message-" || true)

echo ""
echo "Messages reçus :"
echo "${MESSAGES}" | head -20
echo ""

if [ "${NB_RECEIVED}" -ge "${EXPECTED_MESSAGES}" ]; then
  echo "  [PASS] ${NB_RECEIVED}/${EXPECTED_MESSAGES} messages retrouvés"
else
  echo "  [FAIL] Seulement ${NB_RECEIVED}/${EXPECTED_MESSAGES} messages retrouvés"
  exit 1
fi

# Vérifier la cohérence des messages
PASS=0
FAIL=0
for i in $(seq 1 "${EXPECTED_MESSAGES}"); do
  if echo "${MESSAGES}" | grep -q "message-${i}:"; then
    echo "  [PASS] message-${i} présent"
    PASS=$((PASS + 1))
  else
    echo "  [FAIL] message-${i} absent"
    FAIL=$((FAIL + 1))
  fi
done

echo ""
echo "=== Résultat : ${PASS} PASS / ${FAIL} FAIL ==="

if [ "${FAIL}" -gt 0 ]; then
  echo "ERREUR : certains messages n'ont pas été restaurés."
  exit 1
else
  echo "SUCCES : tous les messages ont été restaurés correctement."
  exit 0
fi
