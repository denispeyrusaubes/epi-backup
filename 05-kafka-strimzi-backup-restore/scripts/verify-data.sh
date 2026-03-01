#!/usr/bin/env bash
set -eo pipefail

# --- Configuration ---
NAMESPACE="${NAMESPACE:-kafka}"
CLUSTER_NAME="${CLUSTER_NAME:-epi-kafka-cluster}"
POOL_NAME="${POOL_NAME:-combined}"
POD_NAME="${CLUSTER_NAME}-${POOL_NAME}-0"
BOOTSTRAP="${CLUSTER_NAME}-kafka-bootstrap:9093"
TOPIC="test-backup"
USER="test-user"
NB_MESSAGES=10

echo "=== Vérification des données Kafka après restore (Strimzi) ==="
echo "Namespace  : ${NAMESPACE}"
echo "Cluster    : ${CLUSTER_NAME}"
echo "Pod        : ${POD_NAME}"
echo "Bootstrap  : ${BOOTSTRAP}"
echo "Topic      : ${TOPIC}"
echo ""

# Récupérer le mot de passe SCRAM-SHA-512
echo "Récupération du mot de passe SCRAM du user '${USER}'..."
PASSWORD=$(kubectl get secret "${USER}" -n "${NAMESPACE}" -o jsonpath='{.data.password}' | base64 -d)
if [ -z "${PASSWORD}" ]; then
  echo "ERREUR : impossible de récupérer le mot de passe du user '${USER}'"
  exit 1
fi

# Créer le fichier de configuration client SASL dans le pod
kubectl exec -n "${NAMESPACE}" "${POD_NAME}" -- bash -c "cat > /tmp/client.properties << 'CLIENTEOF'
security.protocol=SASL_PLAINTEXT
sasl.mechanism=SCRAM-SHA-512
sasl.jaas.config=org.apache.kafka.common.security.scram.ScramLoginModule required username=\"${USER}\" password=\"${PASSWORD}\";
CLIENTEOF"

# Vérifier que le topic existe
echo "Vérification du topic '${TOPIC}'..."
if ! kubectl exec -n "${NAMESPACE}" "${POD_NAME}" -- /opt/kafka/bin/kafka-topics.sh \
  --bootstrap-server "${BOOTSTRAP}" \
  --command-config /tmp/client.properties \
  --describe --topic "${TOPIC}" 2>/dev/null; then
  echo "[FAIL] Le topic '${TOPIC}' n'existe pas."
  kubectl exec -n "${NAMESPACE}" "${POD_NAME}" -- rm -f /tmp/client.properties
  exit 1
fi
echo ""

# Consommer tous les messages depuis le début
echo "Consommation des messages depuis le début..."
MESSAGES=$(kubectl exec -n "${NAMESPACE}" "${POD_NAME}" -- /opt/kafka/bin/kafka-console-consumer.sh \
  --bootstrap-server "${BOOTSTRAP}" \
  --topic "${TOPIC}" \
  --from-beginning \
  --timeout-ms 15000 \
  --consumer.config /tmp/client.properties \
  --group "verify-group-$(date +%s)" 2>/dev/null || true)

# Nettoyage du fichier temporaire
kubectl exec -n "${NAMESPACE}" "${POD_NAME}" -- rm -f /tmp/client.properties

echo ""
echo "Messages reçus :"
echo "${MESSAGES}"
echo ""

# Vérifier chaque message attendu
PASS=0
FAIL=0

for i in $(seq 1 "${NB_MESSAGES}"); do
  expected="message-${i}"
  if echo "${MESSAGES}" | grep -qF "${expected}"; then
    echo "  [PASS] ${expected}"
    ((PASS++))
  else
    echo "  [FAIL] ${expected} : non trouvé"
    ((FAIL++))
  fi
done

echo ""
echo "=== Résultat : ${PASS} PASS / ${FAIL} FAIL ==="

if [ "${FAIL}" -gt 0 ]; then
  echo "ERREUR : certains messages n'ont pas été restaurés correctement."
  exit 1
else
  echo "SUCCES : tous les messages ont été restaurés correctement."
  exit 0
fi
