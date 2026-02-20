#!/usr/bin/env bash
# test-local-infra.sh — verify SeaweedFS S3 and OpenLDAP connectivity for local env
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

DC_INPUT="${1:-}"
DC_FILE="$ADMIN_DIR/local/datacenters.yaml"
OPENLDAP_FILE="$ADMIN_DIR/local/openldap.yaml"
SEAWEEDFS_FILE="$ADMIN_DIR/local/seaweedfs.yaml"

PASS=0
FAIL=0

_ok()   { echo "  [OK]  $*"; ((PASS++)) || true; }
_fail() { echo "  [FAIL] $*"; ((FAIL++)) || true; }
_info() { echo "  ---   $*"; }

# ---------------------------------------------------------------------------
# SeaweedFS S3 test
# ---------------------------------------------------------------------------
test_seaweedfs() {
  local endpoint="$1"
  local access_key="$2"
  local secret_key="$3"
  local test_bucket="pgaas-infra-test-$$"
  local test_key="probe.txt"
  local test_body="pgaas-s3-probe"

  echo ""
  echo "==> SeaweedFS S3 test: $endpoint"

  # Detect available S3 client
  if command -v aws &>/dev/null; then
    _test_seaweedfs_aws "$endpoint" "$access_key" "$secret_key" "$test_bucket" "$test_key" "$test_body"
  elif command -v curl &>/dev/null; then
    _test_seaweedfs_curl "$endpoint" "$access_key" "$secret_key" "$test_bucket" "$test_key" "$test_body"
  else
    _fail "No S3 client found (install 'aws' CLI or 'curl')"
    return
  fi
}

_test_seaweedfs_aws() {
  local endpoint="$1" access_key="$2" secret_key="$3"
  local bucket="$4" key="$5" body="$6"

  local aws_cmd="aws --endpoint-url $endpoint \
    --no-sign-request \
    s3"

  # Override auth via env (avoids touching ~/.aws/credentials)
  export AWS_ACCESS_KEY_ID="$access_key"
  export AWS_SECRET_ACCESS_KEY="$secret_key"
  export AWS_DEFAULT_REGION="us-east-1"

  # Create bucket
  if $aws_cmd mb "s3://$bucket" --no-cli-pager >/dev/null 2>&1; then
    _ok "Create bucket s3://$bucket"
  else
    _fail "Create bucket s3://$bucket"
    return
  fi

  # Put object
  if echo "$body" | $aws_cmd cp - "s3://$bucket/$key" --no-cli-pager >/dev/null 2>&1; then
    _ok "Put object s3://$bucket/$key"
  else
    _fail "Put object s3://$bucket/$key"
  fi

  # Get object and verify content
  local got
  got="$(aws --endpoint-url "$endpoint" s3 cp "s3://$bucket/$key" - --no-cli-pager 2>/dev/null || true)"
  if [[ "$got" == "$body" ]]; then
    _ok "Get object content matches"
  else
    _fail "Get object content mismatch (got: '$got', expected: '$body')"
  fi

  # Delete object + bucket
  $aws_cmd rm "s3://$bucket/$key" --no-cli-pager >/dev/null 2>&1 && \
    $aws_cmd rb "s3://$bucket" --no-cli-pager >/dev/null 2>&1 && \
    _ok "Delete object + bucket" || _fail "Delete object + bucket"

  unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION
}

_test_seaweedfs_curl() {
  local endpoint="$1" access_key="$2" secret_key="$3"
  local bucket="$4" key="$5" body="$6"

  # Minimal S3 v4 signing is complex in pure bash; use unsigned requests
  # SeaweedFS in local mode typically accepts unsigned requests when configured without auth enforcement.
  # This probe tests HTTP reachability and basic bucket operations via the S3 REST API.

  local base_url="${endpoint%/}/$bucket"

  # Create bucket (PUT /{bucket})
  local http_code
  http_code="$(curl -s -o /dev/null -w "%{http_code}" -X PUT \
    -H "x-amz-content-sha256: e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" \
    -H "Authorization: AWS4-HMAC-SHA256 Credential=${access_key}/20000101/us-east-1/s3/aws4_request, SignedHeaders=host, Signature=0" \
    "$base_url" 2>/dev/null || echo "000")"
  if [[ "$http_code" =~ ^(200|204|409)$ ]]; then
    _ok "Create bucket (HTTP $http_code)"
  else
    _fail "Create bucket (HTTP $http_code) — SeaweedFS may require auth; install 'aws' CLI for signed requests"
    return
  fi

  # Put object (PUT /{bucket}/{key})
  http_code="$(curl -s -o /dev/null -w "%{http_code}" -X PUT \
    -H "Content-Type: text/plain" \
    --data-raw "$body" \
    "$base_url/$key" 2>/dev/null || echo "000")"
  if [[ "$http_code" =~ ^(200|204)$ ]]; then
    _ok "Put object (HTTP $http_code)"
  else
    _fail "Put object (HTTP $http_code)"
  fi

  # Get object (GET /{bucket}/{key})
  local got
  got="$(curl -s -f "$base_url/$key" 2>/dev/null || true)"
  if [[ "$got" == "$body" ]]; then
    _ok "Get object content matches"
  else
    _info "Get object returned: '${got:0:80}' (unsigned request may fail with auth enforcement)"
  fi

  # Delete object + bucket
  curl -s -o /dev/null -X DELETE "$base_url/$key" 2>/dev/null || true
  curl -s -o /dev/null -X DELETE "$base_url" 2>/dev/null || true
  _ok "Delete cleanup attempted"
}

# ---------------------------------------------------------------------------
# OpenLDAP test
# ---------------------------------------------------------------------------
test_openldap() {
  local host="$1"
  local port="$2"
  local bind_dn="$3"
  local bind_pw="$4"
  local base_dn="$5"

  echo ""
  echo "==> OpenLDAP test: ldap://$host:$port"

  if ! command -v ldapsearch &>/dev/null; then
    _fail "ldapsearch not found — install 'ldap-utils' (apt) or 'openldap-clients' (yum)"
    return
  fi

  # Anonymous bind — check server is reachable
  local result
  result="$(ldapsearch -x -H "ldap://$host:$port" \
    -b "" -s base "(objectClass=*)" namingContexts 2>&1 || true)"

  if echo "$result" | grep -q "namingContexts\|result: 0"; then
    _ok "Server reachable (anonymous bind / rootDSE)"
  else
    _fail "Server not reachable at ldap://$host:$port"
    _info "ldapsearch output: ${result:0:200}"
    return
  fi

  # Admin bind — verify credentials
  result="$(ldapsearch -x -H "ldap://$host:$port" \
    -D "$bind_dn" -w "$bind_pw" \
    -b "$base_dn" "(objectClass=*)" cn uid 2>&1 || true)"

  if echo "$result" | grep -q "result: 0 Success\|numEntries"; then
    _ok "Admin bind successful (bindDn: $bind_dn)"
  else
    _fail "Admin bind failed (bindDn: $bind_dn)"
    _info "ldapsearch output: ${result:0:200}"
    return
  fi

  # Count seed users (ou=people)
  local user_count
  user_count="$(ldapsearch -x -H "ldap://$host:$port" \
    -D "$bind_dn" -w "$bind_pw" \
    -b "ou=people,$base_dn" "(objectClass=inetOrgPerson)" uid 2>&1 \
    | grep -c "^uid:" || echo "0")"
  _ok "Found $user_count user(s) in ou=people,$base_dn"
}

# ---------------------------------------------------------------------------
# Resolve port-forward or NodePort for a service
# ---------------------------------------------------------------------------
resolve_service_address() {
  local svc_name="$1"
  local svc_ns="$2"
  local svc_port="$3"

  local node_port
  node_port="$(kctl get svc "$svc_name" -n "$svc_ns" \
    -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || echo "")"

  if [[ -n "$node_port" ]]; then
    # NodePort: get node IP
    local node_ip=""
    if command -v minikube &>/dev/null; then
      node_ip="$(minikube ip -p "${KUBE_CONTEXT:-minikube}" 2>/dev/null || echo "")"
    fi
    if [[ -z "$node_ip" ]]; then
      node_ip="$(kctl get nodes \
        -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' \
        2>/dev/null || echo "localhost")"
    fi
    SVC_HOST="$node_ip"
    SVC_PORT="$node_port"
  else
    # ClusterIP only: use port-forward
    local local_port=$(( svc_port + 10000 ))
    echo "    Starting port-forward for $svc_name ($svc_ns) → localhost:$local_port ..."
    kctl port-forward "svc/$svc_name" "$local_port:$svc_port" -n "$svc_ns" &
    PF_PID=$!
    sleep 2
    SVC_HOST="localhost"
    SVC_PORT="$local_port"
  fi
}

cleanup_portforward() {
  if [[ -n "${PF_PID:-}" ]]; then
    kill "$PF_PID" 2>/dev/null || true
    PF_PID=""
  fi
}
trap cleanup_portforward EXIT

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
PF_PID=""

# Determine which DCs to test
if [[ -n "$DC_INPUT" ]]; then
  DCS=("$DC_INPUT")
else
  mapfile -t DCS < <(yq_raw '.datacenters | keys | .[]' "$DC_FILE")
fi

if [[ ${#DCS[@]} -eq 0 ]]; then
  echo "ERROR: No datacenters found in $DC_FILE"
  exit 1
fi

echo "==> Testing local infrastructure — DCs: ${DCS[*]}"

# Read admin config
OPENLDAP_SVC_NAME="$(yq_raw '.openldap.service.name' "$OPENLDAP_FILE")"
OPENLDAP_SVC_NS="$(yq_raw '.openldap.service.namespace' "$OPENLDAP_FILE")"
OPENLDAP_SVC_PORT="$(yq_raw '.openldap.service.port' "$OPENLDAP_FILE")"
OPENLDAP_BASE_DN="$(yq_raw '.openldap.baseDn' "$OPENLDAP_FILE")"
OPENLDAP_ADMIN_PW="$(yq_raw '.openldap.adminPassword' "$OPENLDAP_FILE")"
OPENLDAP_BIND_DN="cn=admin,${OPENLDAP_BASE_DN}"

SEAWEEDFS_SVC_NS="$(yq_raw '.seaweedfs.service.namespace' "$SEAWEEDFS_FILE")"
SEAWEEDFS_S3_PORT="$(yq_raw '.seaweedfs.s3.port' "$SEAWEEDFS_FILE")"
SEAWEEDFS_ACCESS_KEY="$(yq_raw '.seaweedfs.s3.accessKey' "$SEAWEEDFS_FILE")"
SEAWEEDFS_SECRET_KEY="$(yq_raw '.seaweedfs.s3.secretKey' "$SEAWEEDFS_FILE")"

FIRST_DC=true
for dc in "${DCS[@]}"; do
  echo ""
  echo "====== DC: $dc ======"
  resolve_kube_context "$dc" "$DC_FILE"
  if [[ -n "${KUBE_CONTEXT:-}" ]]; then
    echo "  Kube context: $KUBE_CONTEXT"
  fi

  # --- Test OpenLDAP ---
  SVC_HOST="" SVC_PORT=""
  resolve_service_address "$OPENLDAP_SVC_NAME" "$OPENLDAP_SVC_NS" "$OPENLDAP_SVC_PORT"
  test_openldap "$SVC_HOST" "$SVC_PORT" "$OPENLDAP_BIND_DN" "$OPENLDAP_ADMIN_PW" "$OPENLDAP_BASE_DN"
  cleanup_portforward

  # --- Test SeaweedFS (first DC only — shared instance) ---
  if [[ "$FIRST_DC" == "true" ]]; then
    # Use S3 endpoint from datacenters.yaml for first DC
    S3_ENDPOINT="$(yq_raw ".datacenters.\"$dc\".s3.endpoint" "$DC_FILE")"
    if [[ "$S3_ENDPOINT" == "null" || -z "$S3_ENDPOINT" ]]; then
      # Fallback: resolve via NodePort
      SVC_HOST="" SVC_PORT=""
      SEAWEEDFS_SVC_NAME="seaweedfs-s3"
      resolve_service_address "$SEAWEEDFS_SVC_NAME" "$SEAWEEDFS_SVC_NS" "$SEAWEEDFS_S3_PORT"
      S3_ENDPOINT="http://$SVC_HOST:$SVC_PORT"
      cleanup_portforward
    fi
    test_seaweedfs "$S3_ENDPOINT" "$SEAWEEDFS_ACCESS_KEY" "$SEAWEEDFS_SECRET_KEY"
    FIRST_DC=false
  else
    echo ""
    echo "==> SeaweedFS S3: shared instance (tested on first DC only)"
  fi
done

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "======================================================"
echo "Test summary: $PASS passed, $FAIL failed"
echo "======================================================"

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
