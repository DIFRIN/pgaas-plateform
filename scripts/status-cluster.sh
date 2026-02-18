#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

setup "${1:-}" "${2:-}"
DC="${3:-}"

# Resolve DC from client config if not provided
if [[ -z "$DC" ]]; then
  DC="$(yq ".clients.\"$INS\".datacenters[0]" "$ADMIN_ENV_DIR/clients.yaml")"
fi

DC_FILE="$ADMIN_ENV_DIR/datacenters.yaml"
resolve_kube_context "$DC" "$DC_FILE"

echo "==> Status for cluster: $CLUSTER_NAME in namespace $NAMESPACE"
if [[ -n "${KUBE_CONTEXT:-}" ]]; then
  echo "    Kube context: $KUBE_CONTEXT"
fi
echo ""

echo "--- CNPG Cluster ---"
kctl get cluster "$CLUSTER_NAME" -n "$NAMESPACE" -o wide 2>/dev/null || echo "  Cluster not found"
echo ""

echo "--- Pods ---"
kctl get pods -n "$NAMESPACE" -l "cnpg.io/cluster=$CLUSTER_NAME" -o wide 2>/dev/null || echo "  No pods found"
echo ""

echo "--- Databases ---"
kctl get databases -n "$NAMESPACE" -l "pgaas.io/ins=$INS" 2>/dev/null || echo "  No database CRDs found"
echo ""

echo "--- Scheduled Backups ---"
kctl get scheduledbackups -n "$NAMESPACE" 2>/dev/null || echo "  No scheduled backups found"
echo ""

echo "--- Recent Backups ---"
kctl get backups -n "$NAMESPACE" --sort-by='.metadata.creationTimestamp' 2>/dev/null | tail -5 || echo "  No backups found"
echo ""

echo "--- Certificates ---"
kctl get certificates -n "$NAMESPACE" 2>/dev/null || echo "  No certificates found"
echo ""

if [[ "$(kctl get cluster "$CLUSTER_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.replica.enabled}' 2>/dev/null)" == "true" ]]; then
  echo "--- Replication Status ---"
  kctl get cluster "$CLUSTER_NAME" -n "$NAMESPACE" -o jsonpath='{.status.replicaCluster}' 2>/dev/null | yq -P
  echo ""
fi
