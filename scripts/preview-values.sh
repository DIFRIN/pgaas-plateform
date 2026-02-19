#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFS_DIR="$PROJECT_ROOT/confs"
GENERATED_DIR="$CONFS_DIR/_generated"

# Strip quotes from yq scalar output (handles yq versions that quote strings)
yq_raw() {
  yq "$@" | tr -d '"'
}

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

ERRORS=0
WARNINGS=0

pass() { echo -e "  ${GREEN}✓${NC} $1"; }
fail() { echo -e "  ${RED}✗${NC} $1"; ERRORS=$((ERRORS + 1)); }
warn() { echo -e "  ${YELLOW}!${NC} $1"; WARNINGS=$((WARNINGS + 1)); }
info() { echo -e "  ${CYAN}→${NC} $1"; }

# Check a yq expression against expected value
check_field() {
  local file="$1" expr="$2" expected="$3" label="$4"
  local actual
  actual="$(yq_raw "$expr" "$file" 2>/dev/null || echo "ERROR")"
  if [[ "$actual" == "$expected" ]]; then
    pass "$label = $actual"
  else
    fail "$label: expected '$expected', got '$actual'"
  fi
}

check_not_empty() {
  local file="$1" expr="$2" label="$3"
  local actual
  actual="$(yq_raw "$expr" "$file" 2>/dev/null || echo "")"
  if [[ -n "$actual" && "$actual" != "null" && "$actual" != "" ]]; then
    pass "$label = $actual"
  else
    fail "$label is empty or null"
  fi
}

check_absent() {
  local file="$1" expr="$2" label="$3"
  local actual
  actual="$(yq_raw "$expr" "$file" 2>/dev/null || echo "null")"
  if [[ "$actual" == "null" || -z "$actual" ]]; then
    pass "$label is absent (correct)"
  else
    fail "$label should be absent but found: $actual"
  fi
}

check_contains() {
  local file="$1" pattern="$2" label="$3"
  if grep -q "$pattern" "$file" 2>/dev/null; then
    pass "$label"
  else
    fail "$label (pattern '$pattern' not found)"
  fi
}

# --- Run preview for a given INS/ENV/DC ---
preview_scenario() {
  local ins="$1" env="$2" dc="${3:-}"
  local label="$ins/$env"
  [[ -n "$dc" ]] && label="$ins/$env/$dc"

  echo ""
  echo -e "${CYAN}━━━ Scenario: $label ━━━${NC}"

  # Check prerequisites
  local user_dir="$CONFS_DIR/users/$ins/$env"
  if [[ ! -f "$user_dir/databases.yaml" ]]; then
    warn "Skipping: $user_dir/databases.yaml not found"
    return
  fi

  # Generate values
  echo "  Generating values..."
  if ! "$SCRIPT_DIR/generate-values.sh" "$ins" "$env" "$dc" > /dev/null 2>&1; then
    fail "generate-values.sh failed for $label"
    return
  fi

  local values="$GENERATED_DIR/${ins}-${env}/values.yaml"
  if [[ ! -f "$values" ]]; then
    fail "Generated values file not found: $values"
    return
  fi

  info "Generated: $values"
  echo ""

  # --- Common checks ---
  echo "  [Naming]"
  check_field "$values" '.clusterName' "${env}-${ins}" "clusterName"
  check_field "$values" '.namespace' "${ins}-${env}" "namespace"
  check_field "$values" '.ins' "$ins" "ins"
  check_field "$values" '.env' "$env" "env"

  echo "  [Storage profile]"
  check_not_empty "$values" '.postgresql.storage.size' "postgresql.storage.size"
  check_not_empty "$values" '.postgresql.resources.requests.memory' "postgresql.resources.requests.memory"
  check_absent "$values" '.storageProfiles' "storageProfiles (should be removed)"

  echo "  [S3]"
  check_not_empty "$values" '.s3.endpoint' "s3.endpoint"
  check_not_empty "$values" '.s3.bucket' "s3.bucket"
  check_not_empty "$values" '.s3.destinationPath' "s3.destinationPath"

  # Check destination path format: INS-ENV-DC-backup
  local dest_path
  dest_path="$(yq_raw '.s3.destinationPath' "$values")"
  local current_dc
  current_dc="$(yq_raw '.datacenter.name' "$values")"
  local expected_path_pattern="${ins}-${env}-${current_dc}-backup"
  if echo "$dest_path" | grep -q "$expected_path_pattern"; then
    pass "Destination path contains '$expected_path_pattern'"
  else
    fail "Destination path '$dest_path' should contain '$expected_path_pattern'"
  fi

  echo "  [S3 credentials]"
  local creds_secret
  creds_secret="$(yq_raw '.s3.credentials.secretName // ""' "$values")"
  local creds_access
  creds_access="$(yq_raw '.s3.credentials.accessKey // ""' "$values")"
  if [[ -n "$creds_secret" && "$creds_secret" != "null" ]]; then
    pass "S3 credentials via Vault secret: $creds_secret"
  elif [[ -n "$creds_access" && "$creds_access" != "null" ]]; then
    pass "S3 credentials via inline keys (local mode)"
  else
    fail "No S3 credentials found (neither secretName nor accessKey)"
  fi

  echo "  [Databases & auth]"
  local db_count
  db_count="$(yq_raw '.databases | length' "$values")"
  if [[ "$db_count" -gt 0 ]]; then
    pass "databases: $db_count database(s) defined"
  else
    fail "No databases defined"
  fi

  # Check no passwordSecret anywhere in databases
  local pw_count
  pw_count="$(yq_raw '[.databases[].roles[]? | select(.passwordSecret)] | length' "$values" 2>/dev/null || echo "0")"
  if [[ "$pw_count" == "0" ]]; then
    pass "No passwordSecret in database roles (cert-only)"
  else
    fail "Found $pw_count role(s) with passwordSecret (should be cert-only)"
  fi

  echo "  [pgAdmin]"
  check_not_empty "$values" '.pgadminUser.name' "pgadminUser.name"
  check_absent "$values" '.pgadminUser.password' "pgadminUser.password"
  check_field "$values" '.pgadmin4.tls.enabled' "true" "pgadmin4.tls.enabled"
  check_not_empty "$values" '.pgadmin4.tls.secretName' "pgadmin4.tls.secretName"
  check_not_empty "$values" '.pgadmin4.tls.issuerName' "pgadmin4.tls.issuerName"
  check_not_empty "$values" '.pgadmin4.tls.issuerKind' "pgadmin4.tls.issuerKind"
  local tls_dns_count
  tls_dns_count="$(yq_raw '.pgadmin4.tls.dnsNames | length' "$values" 2>/dev/null || echo "0")"
  if [[ "$tls_dns_count" -gt 0 ]]; then
    pass "pgadmin4.tls.dnsNames: $tls_dns_count entries"
  else
    fail "pgadmin4.tls.dnsNames is empty"
  fi
  check_field "$values" '.pgadmin4.cnpg.caSecret' "pgaas-root-ca" "pgadmin4.cnpg.caSecret"

  echo "  [pgAdmin LDAP]"
  check_field "$values" '.pgadmin4.ldap.enabled' "true" "pgadmin4.ldap.enabled"
  check_not_empty "$values" '.pgadmin4.ldap.serverUri' "pgadmin4.ldap.serverUri"
  check_not_empty "$values" '.pgadmin4.ldap.baseDn' "pgadmin4.ldap.baseDn"
  check_not_empty "$values" '.pgadmin4.ldap.bindUser' "pgadmin4.ldap.bindUser"
  check_not_empty "$values" '.pgadmin4.ldap.bindPasswordSecret' "pgadmin4.ldap.bindPasswordSecret"

  echo "  [pgAdmin password secret]"
  local pw_create
  pw_create="$(yq_raw '.pgadmin4.defaultPasswordCreate // "true"' "$values")"
  if [[ "$env" == "local" ]]; then
    if [[ "$pw_create" == "true" ]]; then
      pass "defaultPasswordCreate = true (local env)"
    else
      fail "defaultPasswordCreate should be true for local env"
    fi
  else
    if [[ "$pw_create" == "false" ]]; then
      pass "defaultPasswordCreate = false (non-local env)"
    else
      fail "defaultPasswordCreate should be false for non-local env"
    fi
  fi

  echo "  [Roles with database access]"
  local roles_with_dbs
  roles_with_dbs="$(yq_raw '[.roles[] | select(.databases)] | length' "$values" 2>/dev/null || echo "0")"
  if [[ "$roles_with_dbs" -gt 0 ]]; then
    pass "roles with .databases: $roles_with_dbs role(s)"
  else
    info "No roles with explicit .databases (owners have implicit access)"
  fi

  echo "  [Primary/Replica]"
  local is_primary
  is_primary="$(yq_raw '.isPrimary' "$values")"
  info "isPrimary = $is_primary"

  echo "  [Replication]"
  local repl_enabled
  repl_enabled="$(yq_raw '.replication.enabled' "$values")"
  info "replication.enabled = $repl_enabled"

  if [[ "$repl_enabled" == "true" ]]; then
    check_not_empty "$values" '.replication.primaryDatacenter' "replication.primaryDatacenter"

    local primary_dc
    primary_dc="$(yq_raw '.replication.primaryDatacenter' "$values")"
    local cluster_name
    cluster_name="$(yq_raw '.clusterName' "$values")"

    # Check external clusters exist
    local ext_count
    ext_count="$(yq_raw '.externalClusters | length' "$values" 2>/dev/null || echo "0")"
    if [[ "$ext_count" -gt 0 ]]; then
      pass "externalClusters: $ext_count defined"

      # Check external cluster names follow pattern: CLUSTER_NAME-DC
      local ext_names
      ext_names="$(yq_raw '.externalClusters[].name' "$values")"
      while IFS= read -r name; do
        if echo "$name" | grep -q "^${cluster_name}-"; then
          pass "External cluster '$name' follows naming pattern"
        else
          fail "External cluster '$name' does not follow '${cluster_name}-{dc}' pattern"
        fi
      done <<< "$ext_names"

      # Check replica paths include DC mention
      local ext_paths
      ext_paths="$(yq_raw '.externalClusters[].barmanObjectStore.destinationPath' "$values")"
      while IFS= read -r path; do
        if echo "$path" | grep -q "${ins}-${env}-.*-replica"; then
          pass "Replica path '$path' contains DC mention"
        else
          fail "Replica path '$path' should contain '{INS}-{ENV}-{DC}-replica'"
        fi
      done <<< "$ext_paths"
    else
      warn "No externalClusters defined for replicated cluster"
    fi
  fi

  # --- Helm template dry-run ---
  echo "  [Helm template]"
  local template_output
  if template_output="$(helm template pgaas-core "$PROJECT_ROOT/core" -f "$values" 2>&1)"; then
    pass "Helm template renders successfully"

    # Verify pg_hba rules in rendered output
    if echo "$template_output" | grep -q "hostssl.*cert map=pgaas"; then
      pass "pg_hba contains per-database cert rules"
    else
      fail "pg_hba missing per-database cert rules"
    fi

    # Verify pg_ident map
    if echo "$template_output" | grep -q "pgaas .* .*"; then
      pass "pg_ident contains pgaas map entries"
    else
      fail "pg_ident missing pgaas map entries"
    fi

    # Check no passwordSecret in rendered output (for managed roles)
    if echo "$template_output" | grep -q "passwordSecret"; then
      fail "Rendered template still contains passwordSecret"
    else
      pass "No passwordSecret in rendered template"
    fi

    # Check replica.primary uses external cluster name (not bare DC)
    if [[ "$repl_enabled" == "true" ]]; then
      local rendered_primary
      rendered_primary="$(echo "$template_output" | grep -A1 'replica:' | grep 'primary:' | awk '{print $2}' || echo "")"
      if [[ -n "$rendered_primary" ]]; then
        local expected_primary="${cluster_name}-${primary_dc}"
        if [[ "$rendered_primary" == "$expected_primary" ]]; then
          pass "replica.primary = '$rendered_primary' (matches external cluster name)"
        else
          fail "replica.primary = '$rendered_primary', expected '$expected_primary'"
        fi
      fi
    fi

    # Check primaryUpdateStrategy
    if echo "$template_output" | grep -q "primaryUpdateStrategy"; then
      pass "primaryUpdateStrategy is set"
    else
      warn "primaryUpdateStrategy not found in rendered template"
    fi

    # Verify no namespace CA Certificate or Issuer in output
    if echo "$template_output" | grep -q "isCA: true"; then
      fail "Rendered template still contains namespace CA (isCA: true)"
    else
      pass "No namespace CA in rendered template"
    fi

    # Verify all leaf certs use ClusterIssuer
    if echo "$template_output" | grep -q "kind: ClusterIssuer"; then
      pass "Leaf certs use ClusterIssuer"
    else
      fail "Leaf certs should reference ClusterIssuer"
    fi

    # Verify CNPG uses pgaas-root-ca for CA secrets
    if echo "$template_output" | grep -q "serverCASecret: pgaas-root-ca"; then
      pass "serverCASecret = pgaas-root-ca"
    else
      fail "serverCASecret should be pgaas-root-ca"
    fi

    # Verify DC domain suffix SANs in server cert
    local dc_dns_suffix
    dc_dns_suffix="$(yq_raw '.datacenter.dnsSuffix' "$values")"
    local cluster_name_val
    cluster_name_val="$(yq_raw '.clusterName' "$values")"
    local ns_val
    ns_val="$(yq_raw '.namespace' "$values")"
    if echo "$template_output" | grep -q "${cluster_name_val}-rw.${ns_val}.${dc_dns_suffix}"; then
      pass "Server cert has DC domain suffix SANs"
    else
      fail "Server cert missing DC domain suffix SANs"
    fi

    # Verify pgAdmin server cert exists
    if echo "$template_output" | grep -q "${cluster_name_val}-pgadmin-server-tls"; then
      pass "pgAdmin server TLS certificate exists"
    else
      fail "pgAdmin server TLS certificate not found"
    fi

    # Verify pgAdmin cert is created by subchart (Certificate resource with subchart dnsNames)
    if echo "$template_output" | grep -q "pgadmin-${cluster_name_val}.${ns_val}.svc.cluster.local"; then
      pass "pgAdmin cert has subchart dnsNames"
    else
      fail "pgAdmin cert missing subchart dnsNames"
    fi

    # Verify roles with .databases have pg_hba rules
    local roles_db_yaml
    roles_db_yaml="$(yq_raw '.roles[] | select(.databases) | .name' "$values" 2>/dev/null || echo "")"
    if [[ -n "$roles_db_yaml" ]]; then
      while IFS= read -r role_name; do
        [[ -z "$role_name" ]] && continue
        if echo "$template_output" | grep -q "hostssl .* ${role_name} all cert map=pgaas"; then
          pass "pg_hba has rules for role '$role_name'"
        else
          fail "pg_hba missing rules for role '$role_name' (has .databases)"
        fi
        if echo "$template_output" | grep -q "pgaas ${role_name} ${role_name}"; then
          pass "pg_ident has mapping for role '$role_name'"
        else
          fail "pg_ident missing mapping for role '$role_name'"
        fi
        if echo "$template_output" | grep -q "${role_name}-client-tls"; then
          pass "Client cert exists for role '$role_name'"
        else
          fail "Client cert missing for role '$role_name'"
        fi
      done <<< "$roles_db_yaml"
    fi

    # Verify LDAP bind password volume mount
    if echo "$template_output" | grep -q "ldap-bind-password"; then
      pass "LDAP bind password volume mounted in pgAdmin"
    else
      fail "LDAP bind password volume not mounted in pgAdmin"
    fi

    # Verify pgAdmin default password secret (conditional)
    if [[ "$env" == "local" ]]; then
      if echo "$template_output" | grep -q "pgadmin-default-password"; then
        pass "pgAdmin default password secret exists (local)"
      else
        fail "pgAdmin default password secret missing (local)"
      fi
    else
      # Non-local: secret should NOT be created
      if echo "$template_output" | grep -q "kind: Secret" && echo "$template_output" | grep -q "pgadmin-default-password"; then
        fail "pgAdmin default password secret should not be created in non-local env"
      else
        pass "pgAdmin default password secret not created (non-local)"
      fi
    fi

    # Verify pgAdmin deployment uses HTTPS
    if echo "$template_output" | grep -q "PGADMIN_ENABLE_TLS"; then
      pass "pgAdmin deployment enables TLS"
    else
      fail "pgAdmin deployment missing PGADMIN_ENABLE_TLS"
    fi
    if echo "$template_output" | grep -q "containerPort: 443"; then
      pass "pgAdmin deployment uses port 443"
    else
      fail "pgAdmin deployment should use port 443"
    fi

    # Verify NetworkPolicy
    echo "  [NetworkPolicy]"
    local team_env_val
    team_env_val="$(yq_raw '.teamEnv' "$values")"
    if [[ "$team_env_val" == "local" ]]; then
      if echo "$template_output" | grep -q "kind: NetworkPolicy"; then
        fail "NetworkPolicy should not be created for local env"
      else
        pass "No NetworkPolicy for local env (correct)"
      fi
    else
      if echo "$template_output" | grep -q "kind: NetworkPolicy"; then
        pass "NetworkPolicy present for $team_env_val env"
      else
        fail "NetworkPolicy missing for $team_env_val env"
      fi
    fi

    # Verify RBAC
    echo "  [RBAC]"
    if [[ "$team_env_val" == "local" ]]; then
      if echo "$template_output" | grep -q "kind: Role"; then
        fail "RBAC Role should not be created for local env"
      else
        pass "No RBAC for local env (correct)"
      fi
    else
      if echo "$template_output" | grep -q "kind: Role"; then
        pass "RBAC Role present for $team_env_val env"
      else
        fail "RBAC Role missing for $team_env_val env"
      fi
      if echo "$template_output" | grep -q "pgaas-admin-binding"; then
        pass "Admin RoleBinding present"
      else
        fail "Admin RoleBinding missing"
      fi

      # Check client binding: present for hp/perf, absent for pprod/prod
      local has_client_binding="false"
      if echo "$template_output" | grep -q "pgaas-client-binding"; then
        has_client_binding="true"
      fi
      case "$team_env_val" in
        hp|perf)
          if [[ "$has_client_binding" == "true" ]]; then
            pass "Client RoleBinding present for $team_env_val (self-service)"
          else
            fail "Client RoleBinding missing for $team_env_val (should be self-service)"
          fi
          ;;
        pprod|prod)
          if [[ "$has_client_binding" == "false" ]]; then
            pass "No client RoleBinding for $team_env_val (admin-only, correct)"
          else
            fail "Client RoleBinding should not exist for $team_env_val (admin-only)"
          fi
          ;;
      esac
    fi

    # Verify all databases via Database CRD
    local crd_db_count
    crd_db_count="$(echo "$template_output" | grep -c "kind: Database" || echo "0")"
    if [[ "$is_primary" == "true" ]]; then
      if [[ "$crd_db_count" -gt 0 ]]; then
        pass "Database CRDs present ($crd_db_count) on primary"
      else
        fail "No Database CRDs found on primary"
      fi
      # Verify managed roles present on primary
      if echo "$template_output" | grep -q "managed:"; then
        pass "Managed roles present on primary"
      else
        warn "No managed roles section on primary"
      fi
      # Primary should NOT have explicit bootstrap (CNPG defaults to initdb)
      if echo "$template_output" | grep -q "bootstrap:"; then
        fail "Primary should not have explicit bootstrap section"
      else
        pass "No explicit bootstrap on primary (CNPG defaults to initdb)"
      fi
    else
      if [[ "$crd_db_count" -eq 0 ]]; then
        pass "No Database CRDs on replica (correct)"
      else
        fail "Replica should not have Database CRDs"
      fi
      # Verify no managed roles on replica
      if echo "$template_output" | grep -q "managed:"; then
        fail "Replica should not have managed roles"
      else
        pass "No managed roles on replica (correct)"
      fi
      # Verify bootstrap uses recovery
      if echo "$template_output" | grep -q "recovery:"; then
        pass "Replica uses recovery bootstrap"
      else
        fail "Replica should use recovery bootstrap"
      fi
    fi
  else
    fail "Helm template failed:"
    echo "$template_output" | head -20
  fi

  echo ""
  info "--- Generated values dump ---"
  yq '.' "$values"
}

# === MAIN ===
echo -e "${CYAN}╔════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║     PGaaS - Preview Generated Values   ║${NC}"
echo -e "${CYAN}╚════════════════════════════════════════╝${NC}"

if [[ $# -ge 2 ]]; then
  # Single scenario mode: preview-values.sh INS ENV [DC]
  preview_scenario "$1" "$2" "${3:-}"
else
  # Auto-discover mode: run all available scenarios
  echo ""
  echo "Auto-discovering scenarios from confs/users/..."

  # Find all user env directories with databases.yaml
  while IFS= read -r db_file; do
    rel="${db_file#$CONFS_DIR/users/}"
    ins="$(echo "$rel" | cut -d'/' -f1)"
    env="$(echo "$rel" | cut -d'/' -f2)"
    preview_scenario "$ins" "$env"
  done < <(find "$CONFS_DIR/users" -name "databases.yaml" -type f 2>/dev/null | sort)

  # For prod/pprod with replication, also test with explicit DCs
  for env in prod pprod; do
    clients_file="$CONFS_DIR/admin/$env/clients.yaml"
    [[ -f "$clients_file" ]] || continue

    while IFS= read -r ins; do
      [[ -z "$ins" ]] && continue
      user_dir="$CONFS_DIR/users/$ins/$env"
      [[ -f "$user_dir/databases.yaml" ]] || continue

      dcs="$(yq_raw ".clients.\"$ins\".datacenters[]" "$clients_file" 2>/dev/null)"
      while IFS= read -r dc; do
        [[ -z "$dc" ]] && continue
        preview_scenario "$ins" "$env" "$dc"
      done <<< "$dcs"
    done < <(yq_raw '.clients | keys | .[]' "$clients_file" 2>/dev/null)
  done
fi

# Summary
echo ""
echo -e "${CYAN}━━━ Summary ━━━${NC}"
if [[ $ERRORS -eq 0 ]]; then
  echo -e "${GREEN}All checks passed!${NC} (${WARNINGS} warning(s))"
else
  echo -e "${RED}${ERRORS} check(s) failed${NC}, ${WARNINGS} warning(s)"
  exit 1
fi
