#!/usr/bin/env bash
set -euo pipefail

# Demote the current primary cluster (runs against the primary DC's K8s cluster)
#
# In a multi-DC setup, primary and replica live on separate K8s clusters.
# This script patches the primary cluster to demote it and generates a demotion token.
# The token is then used by promote-cluster.sh on the replica DC.
#
# Usage: demote-cluster.sh <INS> <ENV> [DC] <NEW_PRIMARY_CLUSTER>
#   NEW_PRIMARY = name of the external cluster entry that will become primary
#                 (e.g., prod-ic1-dc2)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

setup "${1:-}" "${2:-}"

DC="${3:-}"
NEW_PRIMARY="${4:-}"

# Resolve DC from client config if not provided
if [[ -z "$DC" ]]; then
  DC="$(yq_raw ".clients.\"$INS\".datacenters[0]" "$ADMIN_ENV_DIR/clients.yaml")"
fi

if [[ -z "$NEW_PRIMARY" ]]; then
  echo "Usage: $0 <INS> <ENV> [DC] <NEW_PRIMARY_CLUSTER>"
  echo "  DC          - Datacenter (e.g., local1, dc1). Defaults to client's first DC."
  echo "  NEW_PRIMARY - External cluster name that will become the new primary"
  echo "  Example: $0 ic1 prod dc1 prod-ic1-dc2"
  exit 1
fi

DC_FILE="$ADMIN_ENV_DIR/datacenters.yaml"
resolve_kube_context "$DC" "$DC_FILE"

echo "==> Demoting cluster: $CLUSTER_NAME in namespace $NAMESPACE"
if [[ -n "${KUBE_CONTEXT:-}" ]]; then
  echo "    Kube context: $KUBE_CONTEXT"
fi
echo "    New primary will be: $NEW_PRIMARY"

# Verify this cluster exists and is replication-enabled
REPLICA_SPEC=$(kctl get cluster "$CLUSTER_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.replica}' 2>/dev/null || echo "")
if [[ -z "$REPLICA_SPEC" ]]; then
  echo "ERROR: Cluster $CLUSTER_NAME has no replica spec — replication may not be enabled"
  exit 1
fi

# Verify the current cluster is the primary (replica.primary points to itself or is empty)
CURRENT_PRIMARY=$(kctl get cluster "$CLUSTER_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.replica.primary}' 2>/dev/null || echo "")
if [[ -n "$CURRENT_PRIMARY" && "$CURRENT_PRIMARY" != "$CLUSTER_NAME" ]]; then
  echo "ERROR: Cluster $CLUSTER_NAME is not the current primary (primary=$CURRENT_PRIMARY)"
  exit 1
fi

echo "    WARNING: This will demote $CLUSTER_NAME and make it a replica."
read -rp "    Continue? (yes/no): " CONFIRM
if [[ "$CONFIRM" != "yes" ]]; then
  echo "    Aborted."
  exit 1
fi

# Patch to set the new primary (triggers demotion)
# Per CNPG docs: set replica.primary to the external cluster name
echo "    Patching cluster for demotion..."
kctl patch cluster "$CLUSTER_NAME" -n "$NAMESPACE" --type merge -p '{
  "spec": {
    "replica": {
      "enabled": true,
      "primary": "'"$NEW_PRIMARY"'"
    }
  }
}'

echo "    Waiting for demotion token..."
for i in $(seq 1 30); do
  DEMOTION_TOKEN=$(kctl get cluster "$CLUSTER_NAME" -n "$NAMESPACE" \
    -o jsonpath='{.status.demotionToken}' 2>/dev/null || echo "")
  if [[ -n "$DEMOTION_TOKEN" ]]; then
    break
  fi
  sleep 2
done

if [[ -n "$DEMOTION_TOKEN" ]]; then
  echo ""
  echo "==> Demotion successful!"
  echo "    Demotion token: $DEMOTION_TOKEN"
  echo ""
  echo "    Next step: on the replica DC's K8s cluster, run:"
  echo "      make promote INS=$INS ENV=$ENV DC=<replica-dc> DEMOTION_TOKEN=$DEMOTION_TOKEN"
else
  echo ""
  echo "==> Demotion initiated but token not yet available."
  echo "    Check status with: make status INS=$INS ENV=$ENV DC=$DC"
  echo "    Once the token appears, proceed with promotion on the replica DC."
fi
