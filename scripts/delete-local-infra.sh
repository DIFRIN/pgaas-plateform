#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

DC_INPUT="${1:-}"
DC_FILE="$ADMIN_DIR/local/datacenters.yaml"

echo "==> Deleting local infrastructure (SeaweedFS + OpenLDAP + cert-manager CA)"

# Determine which DCs to process
if [[ -n "$DC_INPUT" ]]; then
  DCS=("$DC_INPUT")
else
  mapfile -t DCS < <(yq_raw '.datacenters | keys | .[]' "$DC_FILE")
fi

if [[ ${#DCS[@]} -eq 0 ]]; then
  echo "ERROR: No datacenters found in $DC_FILE"
  exit 1
fi

echo "    Datacenters: ${DCS[*]}"
read -rp "    Type 'yes' to confirm: " CONFIRM

if [[ "$CONFIRM" != "yes" ]]; then
  echo "    Aborted."
  exit 1
fi

export INS=_unused ENV=_unused NAMESPACE=_unused CLUSTER_NAME=_unused

FIRST_DC=true
for dc in "${DCS[@]}"; do
  echo ""
  echo "--- Processing DC: $dc ---"
  resolve_kube_context "$dc" "$DC_FILE"

  if [[ -n "${KUBE_CONTEXT:-}" ]]; then
    echo "    Kube context: $KUBE_CONTEXT"
  fi

  # Destroy SeaweedFS only on the first DC (shared)
  if [[ "$FIRST_DC" == "true" ]]; then
    echo "    Destroying SeaweedFS..."
    hfile -f "$PROJECT_ROOT/helmfile.yaml" -l "component=local-infra" -l "service=seaweedfs" destroy || true
    FIRST_DC=false
  fi

  # Destroy OpenLDAP
  echo "    Destroying OpenLDAP..."
  hfile -f "$PROJECT_ROOT/helmfile.yaml" -l "component=local-infra" -l "service=openldap" destroy || true

  # Delete cert-manager CA manifest resources
  echo "    Deleting cert-manager CA resources..."
  kctl delete -f "$PROJECT_ROOT/manifests/cert-manager-ca.yaml" --ignore-not-found
done

echo ""
echo "==> Local infrastructure destroyed"
