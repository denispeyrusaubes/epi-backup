#!/usr/bin/env bash
set -eo pipefail

# --- Configuration ---
NAMESPACE="${NAMESPACE:-kafka-test}"
RELEASE="${RELEASE:-kafka-test}"
POD_NAME="${RELEASE}-kafka-0"
TOPIC="velero-backup-test"
NB_MESSAGES=10

echo "=== Insertion de données de test dans Kafka ==="
echo "Namespace : ${NAMESPACE}"
echo "Pod       : ${POD_NAME}"
echo "Topic     : ${TOPIC}"
echo ""

# Créer le topic avec replication-factor 3 (un replica par broker)
echo "Création du topic '${TOPIC}'..."
kubectl exec -n "${NAMESPACE}" "${POD_NAME}" -- \
  /opt/kafka/bin/kafka-topics.sh \
    --create \
    --topic "${TOPIC}" \
    --partitions 3 \
    --replication-factor 3 \
    --bootstrap-server localhost:9092 \
    --if-not-exists

echo ""

# Afficher la description du topic
echo "Description du topic :"
kubectl exec -n "${NAMESPACE}" "${POD_NAME}" -- \
  /opt/kafka/bin/kafka-topics.sh \
    --describe \
    --topic "${TOPIC}" \
    --bootstrap-server localhost:9092

echo ""

# Produire des messages
echo "Production de ${NB_MESSAGES} messages..."
for i in $(seq 1 "${NB_MESSAGES}"); do
  message="message-${i}:donnee-test-$(date -u +%Y%m%d%H%M%S)-${i}"
  echo "${message}" | kubectl exec -i -n "${NAMESPACE}" "${POD_NAME}" -- \
    /opt/kafka/bin/kafka-console-producer.sh \
      --topic "${TOPIC}" \
      --bootstrap-server localhost:9092
  echo "  Produit : ${message}"
done

echo ""
echo "=== ${NB_MESSAGES} messages produits dans le topic '${TOPIC}' ==="
echo ""

# Vérification rapide
echo "Vérification rapide (lecture des messages) :"
kubectl exec -n "${NAMESPACE}" "${POD_NAME}" -- \
  /opt/kafka/bin/kafka-console-consumer.sh \
    --topic "${TOPIC}" \
    --from-beginning \
    --timeout-ms 5000 \
    --bootstrap-server localhost:9092 || true
