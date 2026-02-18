#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

setup "${1:-}" "${2:-}"
DC="${3:-}"

# Resolve DC from client config if not provided
if [[ -z "$DC" ]]; then
  DC="$(yq ".clients.\"$INS\".datacenters[0]" "$ADMIN_ENV_DIR/datacenters.yaml" 2>/dev/null || true)"
  if [[ -z "$DC" || "$DC" == "null" ]]; then
    DC="$(yq ".clients.\"$INS\".datacenters[0]" "$ADMIN_ENV_DIR/clients.yaml")"
  fi
fi

DC_FILE="$ADMIN_ENV_DIR/datacenters.yaml"
resolve_kube_context "$DC" "$DC_FILE"

echo "==> Creating cluster: $CLUSTER_NAME in namespace $NAMESPACE"
if [[ -n "${KUBE_CONTEXT:-}" ]]; then
  echo "    Kube context: $KUBE_CONTEXT"
fi

"$SCRIPTS_DIR/generate-values.sh" "$INS" "$ENV" "$DC"

if kctl get namespace "$NAMESPACE" &>/dev/null; then
  echo "    Namespace $NAMESPACE already exists"
else
  echo "    Creating namespace $NAMESPACE"
  kctl create namespace "$NAMESPACE"
fi

# Copy root CA public cert to cluster namespace
echo "    Distributing root CA to namespace $NAMESPACE"
kctl get secret pgaas-root-ca-secret -n cert-manager \
  -o jsonpath='{.data.ca\.crt}' | base64 -d > /tmp/pgaas-ca.crt
kctl create secret generic pgaas-root-ca \
  --from-file=ca.crt=/tmp/pgaas-ca.crt \
  -n "$NAMESPACE" --dry-run=client -o yaml | kctl apply -f -
rm -f /tmp/pgaas-ca.crt

export INS ENV NAMESPACE CLUSTER_NAME
hfile -f "$PROJECT_ROOT/helmfile.yaml" -l "component=cluster" apply

echo "==> Cluster $CLUSTER_NAME deployed successfully"
