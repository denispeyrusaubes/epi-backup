#!/usr/bin/env bash
set -eo pipefail

STRIMZI_VERSION="${STRIMZI_VERSION:-0.47.0}"
NAMESPACE="strimzi"

echo "=== Installation de l'opérateur Strimzi v${STRIMZI_VERSION} ==="
echo ""

# Ajouter le repo Helm Strimzi
echo "Ajout du repo Helm Strimzi..."
helm repo add strimzi https://strimzi.io/charts/ 2>/dev/null || true
helm repo update strimzi

echo ""
echo "Installation de l'opérateur dans le namespace '${NAMESPACE}'..."
helm install strimzi-operator strimzi/strimzi-kafka-operator \
  --namespace "${NAMESPACE}" \
  --create-namespace \
  --version "${STRIMZI_VERSION}" \
  --set watchNamespaces="{${NAMESPACE},kafka}" \
  --wait \
  --timeout 120s

echo ""
echo "=== Vérification ==="
kubectl get pods -n "${NAMESPACE}"

echo ""
echo "=== Strimzi v${STRIMZI_VERSION} installé avec succès ==="
