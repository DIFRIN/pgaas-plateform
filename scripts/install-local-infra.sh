#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

DC_INPUT="${1:-}"
DC_FILE="$ADMIN_DIR/local/datacenters.yaml"

echo "==> Installing local infrastructure (cert-manager CA + OpenLDAP + SeaweedFS)"

# Determine which DCs to process
if [[ -n "$DC_INPUT" ]]; then
  DCS=("$DC_INPUT")
else
  # Read all DCs from local datacenters.yaml
  mapfile -t DCS < <(yq_raw '.datacenters | keys | .[]' "$DC_FILE")
fi

if [[ ${#DCS[@]} -eq 0 ]]; then
  echo "ERROR: No datacenters found in $DC_FILE"
  exit 1
fi

echo "    Datacenters: ${DCS[*]}"

# Generate local-infra values from admin/user config
# Use first available client with local env to trigger infra generation
FIRST_CLIENT=""
for client_dir in "$USERS_DIR"/*/local; do
  if [[ -d "$client_dir" ]]; then
    FIRST_CLIENT="$(basename "$(dirname "$client_dir")")"
    break
  fi
done

if [[ -z "$FIRST_CLIENT" ]]; then
  echo "WARNING: No client with local env found. Using chart defaults."
else
  echo "    Generating local-infra values using client '$FIRST_CLIENT'..."
  "$SCRIPTS_DIR/generate-values.sh" "$FIRST_CLIENT" local "${DCS[0]}"
fi

FIRST_DC=true
for dc in "${DCS[@]}"; do
  echo ""
  echo "--- Processing DC: $dc ---"
  resolve_kube_context "$dc" "$DC_FILE"

  if [[ -n "${KUBE_CONTEXT:-}" ]]; then
    echo "    Kube context: $KUBE_CONTEXT"
  fi

  # Apply local storage class (skip if minikube — it has its own default)
  if command -v minikube &>/dev/null && minikube status -p "${KUBE_CONTEXT:-minikube}" &>/dev/null 2>&1; then
    echo "    Minikube detected, skipping local storage class"
  else
    echo "    Applying local storage class..."
    kctl apply -f "$PROJECT_ROOT/manifests/local-storage-class.yaml"
  fi

  # Apply cert-manager CA manifest
  echo "    Applying cert-manager CA manifest..."
  kctl apply -f "$PROJECT_ROOT/manifests/cert-manager-ca.yaml"

  # Wait for root CA certificate to be ready
  echo "    Waiting for root CA certificate..."
  kctl -n cert-manager wait --for=condition=Ready certificate/pgaas-root-ca --timeout=60s 2>/dev/null || true

  # Deploy OpenLDAP via helmfile
  echo "    Deploying OpenLDAP..."
  export INS=_unused ENV=_unused NAMESPACE=_unused CLUSTER_NAME=_unused
  hfile -f "$PROJECT_ROOT/helmfile.yaml" -l "component=local-infra" -l "service=openldap" apply

  # Deploy SeaweedFS only on the first DC (shared S3 storage)
  if [[ "$FIRST_DC" == "true" ]]; then
    echo "    Deploying SeaweedFS (shared, on first DC only)..."
    hfile -f "$PROJECT_ROOT/helmfile.yaml" -l "component=local-infra" -l "service=seaweedfs" apply
    FIRST_DC=false
  fi
done

# Print SeaweedFS access info for the first DC
FIRST_DC_NAME="${DCS[0]}"
resolve_kube_context "$FIRST_DC_NAME" "$DC_FILE"
SEAWEEDFS_NODEPORT=$(kctl get svc seaweedfs-s3 -n local-infra -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || echo "N/A")

if command -v minikube &>/dev/null; then
  FIRST_DC_CTX="$(yq_raw ".datacenters.\"$FIRST_DC_NAME\".kubeContext // \"minikube\"" "$DC_FILE")"
  CLUSTER_IP=$(minikube ip -p "$FIRST_DC_CTX" 2>/dev/null || echo "N/A")
else
  CLUSTER_IP="$(kctl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || echo "N/A")"
fi

echo ""
echo "==> Local infrastructure deployed"
echo ""
if [[ "$SEAWEEDFS_NODEPORT" != "N/A" && "$CLUSTER_IP" != "N/A" ]]; then
  echo "    SeaweedFS available at: http://${CLUSTER_IP}:${SEAWEEDFS_NODEPORT}"
  echo ""
  echo "    Update confs/admin/local/datacenters.yaml s3.endpoint with this URL"
  echo "    for all datacenters (both DCs share the same SeaweedFS instance)."
fi
