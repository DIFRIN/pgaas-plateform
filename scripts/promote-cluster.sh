#!/usr/bin/env bash
set -euo pipefail

# Promote a replica cluster to primary (runs against the replica DC's K8s cluster)
#
# In a multi-DC setup, primary and replica live on separate K8s clusters.
# The demotion token is generated on the demoted cluster (a different K8s cluster),
# so it must be passed as an argument — it cannot be read from the local cluster.
#
# Usage: promote-cluster.sh <INS> <ENV> [DC] [DEMOTION_TOKEN]
#   With DEMOTION_TOKEN: graceful promotion (clean switchover)
#   Without DEMOTION_TOKEN: disaster recovery force promote (interactive confirmation)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

setup "${1:-}" "${2:-}"

DC="${3:-}"
DEMOTION_TOKEN="${4:-}"

# Resolve DC from client config if not provided
if [[ -z "$DC" ]]; then
  DC="$(yq_raw ".clients.\"$INS\".datacenters[0]" "$ADMIN_ENV_DIR/clients.yaml")"
fi

DC_FILE="$ADMIN_ENV_DIR/datacenters.yaml"
resolve_kube_context "$DC" "$DC_FILE"

echo "==> Promoting cluster: $CLUSTER_NAME in namespace $NAMESPACE"
if [[ -n "${KUBE_CONTEXT:-}" ]]; then
  echo "    Kube context: $KUBE_CONTEXT"
fi

# Verify cluster exists and is a replica
REPLICA_ENABLED=$(kctl get cluster "$CLUSTER_NAME" -n "$NAMESPACE" \
  -o jsonpath='{.spec.replica.enabled}' 2>/dev/null || echo "false")

if [[ "$REPLICA_ENABLED" != "true" ]]; then
  echo "ERROR: Cluster $CLUSTER_NAME is not a replica cluster (replica.enabled != true)"
  exit 1
fi

# Check current primary to confirm this is not already the primary
CURRENT_PRIMARY=$(kctl get cluster "$CLUSTER_NAME" -n "$NAMESPACE" \
  -o jsonpath='{.spec.replica.primary}' 2>/dev/null || echo "")
if [[ "$CURRENT_PRIMARY" == "$CLUSTER_NAME" ]]; then
  echo "ERROR: Cluster $CLUSTER_NAME is already the primary (replica.primary points to itself)"
  exit 1
fi

if [[ -n "$DEMOTION_TOKEN" ]]; then
  echo "    Demotion token provided: ${DEMOTION_TOKEN:0:20}..."
  echo "    Proceeding with clean promotion (graceful switchover)."
  echo ""

  # Patch to promote: set replica.primary to self + pass demotion token
  kctl patch cluster "$CLUSTER_NAME" -n "$NAMESPACE" --type merge -p '{
    "spec": {
      "replica": {
        "enabled": true,
        "promotionToken": "'"$DEMOTION_TOKEN"'",
        "primary": "'"$CLUSTER_NAME"'"
      }
    }
  }'
else
  echo "    WARNING: No demotion token provided."
  echo "    This indicates a disaster recovery scenario where the old primary is unavailable."
  echo ""
  read -rp "    Force promote without demotion token? (yes/no): " CONFIRM
  if [[ "$CONFIRM" != "yes" ]]; then
    echo "    Aborted."
    exit 1
  fi

  # Force promote without token (DR scenario)
  kctl patch cluster "$CLUSTER_NAME" -n "$NAMESPACE" --type merge -p '{
    "spec": {
      "replica": {
        "enabled": true,
        "primary": "'"$CLUSTER_NAME"'"
      }
    }
  }'
fi

echo ""
echo "==> Cluster $CLUSTER_NAME promotion initiated"
echo "    Monitor with: make status INS=$INS ENV=$ENV DC=$DC"

# --- DNS alias update ---
# After promotion, update the primary DNS alias to point to this DC's RW service.
# The generated values file contains the computed DNS FQDNs.
GENERATED_VALUES="$GENERATED_DIR/${INS}-${ENV}/values.yaml"
if [[ -f "$GENERATED_VALUES" ]]; then
  DNS_PRIMARY_FQDN="$(yq_raw '.dns.primaryFqdn // ""' "$GENERATED_VALUES")"
  DC_DNS_SUFFIX="$(yq_raw '.datacenter.dnsSuffix // ""' "$GENERATED_VALUES")"

  if [[ -n "$DNS_PRIMARY_FQDN" && -n "$DC_DNS_SUFFIX" ]]; then
    # Target: the RW service FQDN on this (now primary) DC
    TARGET_FQDN="${CLUSTER_NAME}-rw.${NAMESPACE}.${DC_DNS_SUFFIX}"
    echo ""
    echo "==> Updating primary DNS alias"
    echo "    $DNS_PRIMARY_FQDN  →  $TARGET_FQDN"
    "$SCRIPTS_DIR/update-dns.sh" "$DNS_PRIMARY_FQDN" "$TARGET_FQDN" "${KUBE_CONTEXT:-}" || \
      echo "    WARNING: DNS update failed — update $DNS_PRIMARY_FQDN manually"
  else
    echo ""
    echo "    No DNS config in generated values — skipping primary alias update"
    echo "    (Run 'make generate INS=$INS ENV=$ENV DC=$DC' to regenerate values with DNS config)"
  fi
else
  echo ""
  echo "    Generated values not found ($GENERATED_VALUES)"
  echo "    Run 'make generate INS=$INS ENV=$ENV DC=$DC' first to enable DNS alias update"
fi
