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

echo "==> About to DELETE cluster: $CLUSTER_NAME in namespace $NAMESPACE"
if [[ -n "${KUBE_CONTEXT:-}" ]]; then
  echo "    Kube context: $KUBE_CONTEXT"
fi
echo "    This will destroy all data in the cluster."
read -rp "    Type 'yes' to confirm: " CONFIRM

if [[ "$CONFIRM" != "yes" ]]; then
  echo "    Aborted."
  exit 1
fi

export INS ENV NAMESPACE CLUSTER_NAME
hfile -f "$PROJECT_ROOT/helmfile.yaml" -l "component=cluster" destroy

echo "==> Cluster $CLUSTER_NAME destroyed"
