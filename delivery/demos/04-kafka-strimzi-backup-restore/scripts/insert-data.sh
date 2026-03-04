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

echo "=== Insertion de données dans Kafka (Strimzi) ==="
echo "Namespace  : ${NAMESPACE}"
echo "Cluster    : ${CLUSTER_NAME}"
echo "Pod        : ${POD_NAME}"
echo "Bootstrap  : ${BOOTSTRAP}"
echo "Topic      : ${TOPIC}"
echo ""

# Récupérer le mot de passe SCRAM-SHA-512 depuis le secret créé par Strimzi
echo "Récupération du mot de passe SCRAM du user '${USER}'..."
PASSWORD=$(kubectl get secret "${USER}" -n "${NAMESPACE}" -o jsonpath='{.data.password}' | base64 -d)
if [ -z "${PASSWORD}" ]; then
  echo "ERREUR : impossible de récupérer le mot de passe du user '${USER}'"
  exit 1
fi
echo "Mot de passe récupéré."

# Créer le fichier de configuration client SASL dans le pod
echo "Configuration du client SASL..."
kubectl exec -n "${NAMESPACE}" "${POD_NAME}" -- bash -c "cat > /tmp/client.properties << 'CLIENTEOF'
security.protocol=SASL_PLAINTEXT
sasl.mechanism=SCRAM-SHA-512
sasl.jaas.config=org.apache.kafka.common.security.scram.ScramLoginModule required username=\"${USER}\" password=\"${PASSWORD}\";
CLIENTEOF"

# Attendre que le topic soit prêt
echo ""
echo "Vérification du topic '${TOPIC}'..."
for i in $(seq 1 30); do
  if kubectl exec -n "${NAMESPACE}" "${POD_NAME}" -- /opt/kafka/bin/kafka-topics.sh \
    --bootstrap-server "${BOOTSTRAP}" \
    --command-config /tmp/client.properties \
    --describe --topic "${TOPIC}" &>/dev/null; then
    echo "Topic '${TOPIC}' prêt."
    break
  fi
  if [ "$i" -eq 30 ]; then
    echo "ERREUR : le topic '${TOPIC}' n'est pas disponible après 30 tentatives."
    exit 1
  fi
  echo "  Attente du topic... (${i}/30)"
  sleep 5
done

# Produire les messages
echo ""
echo "Production de ${NB_MESSAGES} messages..."
for i in $(seq 1 "${NB_MESSAGES}"); do
  echo "message-${i}" | kubectl exec -i -n "${NAMESPACE}" "${POD_NAME}" -- \
    /opt/kafka/bin/kafka-console-producer.sh \
    --bootstrap-server "${BOOTSTRAP}" \
    --topic "${TOPIC}" \
    --producer.config /tmp/client.properties
  echo "  Produit : message-${i}"
done

echo ""
echo "=== ${NB_MESSAGES} messages produits avec succès sur '${TOPIC}' ==="

# Vérification rapide
echo ""
echo "Vérification rapide (consommation depuis le début) :"
kubectl exec -n "${NAMESPACE}" "${POD_NAME}" -- /opt/kafka/bin/kafka-console-consumer.sh \
  --bootstrap-server "${BOOTSTRAP}" \
  --topic "${TOPIC}" \
  --from-beginning \
  --timeout-ms 10000 \
  --consumer.config /tmp/client.properties \
  --group test-group 2>/dev/null || true

# Nettoyage du fichier temporaire
kubectl exec -n "${NAMESPACE}" "${POD_NAME}" -- rm -f /tmp/client.properties
