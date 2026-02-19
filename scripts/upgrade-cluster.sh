#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

setup "${1:-}" "${2:-}"
DC="${3:-}"

# Resolve DC from client config if not provided
if [[ -z "$DC" ]]; then
  DC="$(yq_raw ".clients.\"$INS\".datacenters[0]" "$ADMIN_ENV_DIR/clients.yaml")"
fi

DC_FILE="$ADMIN_ENV_DIR/datacenters.yaml"
resolve_kube_context "$DC" "$DC_FILE"

echo "==> Upgrading cluster INS=$INS ENV=$ENV (CLUSTER_NAME=$CLUSTER_NAME)"
if [[ -n "${KUBE_CONTEXT:-}" ]]; then
  echo "    Kube context: $KUBE_CONTEXT"
fi

# Step 1: Regenerate values (picks up new image tag from admin postgresql.yaml)
echo "    Regenerating values..."
"$SCRIPTS_DIR/generate-values.sh" "$INS" "$ENV" "$DC"

# Step 2: Apply via helmfile — CNPG handles rolling update automatically
echo "    Applying changes via helmfile..."
export INS ENV NAMESPACE CLUSTER_NAME

hfile -f "$PROJECT_ROOT/helmfile.yaml" \
  -l "component=cluster" \
  -l "ins=$INS" \
  -l "env=$ENV" \
  apply

# Step 3: Monitor rollout status
echo "    Monitoring rolling update..."
echo ""
kctl -n "$NAMESPACE" get cluster "$CLUSTER_NAME" -o wide 2>/dev/null || true
echo ""
kctl -n "$NAMESPACE" get pods -l "cnpg.io/cluster=$CLUSTER_NAME" -o wide 2>/dev/null || true

echo ""
echo "==> Upgrade initiated for $CLUSTER_NAME"
echo "    CNPG will perform a rolling update (replicas first, then switchover primary)."
echo "    Monitor with: make status INS=$INS ENV=$ENV DC=$DC"
