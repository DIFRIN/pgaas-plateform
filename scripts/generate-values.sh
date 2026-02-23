#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/merge.sh"

setup "${1:-}" "${2:-}"

# Optional DC argument (3rd param); resolved later from client config if not provided
DC_INPUT="${3:-}"

OUTPUT_DIR="$GENERATED_DIR/${INS}-${ENV}"

echo "==> Generating values for INS=$INS ENV=$ENV"
echo "    Admin dir:  $ADMIN_ENV_DIR"
echo "    User dir:   $USER_ENV_DIR"
echo "    Output:     $OUTPUT_DIR"

# --- Step 1: Start with user databases.yaml as base (low priority) ---
USER_DB_FILE="$USER_ENV_DIR/databases.yaml"
if [[ ! -f "$USER_DB_FILE" ]]; then
  echo "ERROR: User databases file not found: $USER_DB_FILE"
  exit 1
fi

# Validate: user databases.yaml may only contain allowed top-level keys
ALLOWED_USER_KEYS="postgresql plugins databases roles"
USER_KEYS="$(yq_raw 'keys | .[]' "$USER_DB_FILE")"
while IFS= read -r key; do
  [[ -z "$key" ]] && continue
  if ! echo "$ALLOWED_USER_KEYS" | grep -qw "$key"; then
    echo "ERROR: Disallowed key '$key' in $USER_DB_FILE"
    echo "       User databases.yaml may only contain: $ALLOWED_USER_KEYS"
    echo "       Admin-level values (backup, imageCatalog, s3, replication, etc.) belong in admin config files."
    exit 1
  fi
done <<< "$USER_KEYS"

MERGED="$(cat "$USER_DB_FILE")"

# --- Step 2: Deep-merge admin postgresql.yaml on top (admin wins) ---
ADMIN_PG_FILE="$ADMIN_ENV_DIR/postgresql.yaml"
if [[ -f "$ADMIN_PG_FILE" ]]; then
  MERGED="$(echo "$MERGED" | yq eval-all 'select(fileIndex == 0) * select(fileIndex == 1)' - "$ADMIN_PG_FILE")"
fi

# --- Step 3: Deep-merge admin backup.yaml on top ---
ADMIN_BACKUP_FILE="$ADMIN_ENV_DIR/backup.yaml"
if [[ -f "$ADMIN_BACKUP_FILE" ]]; then
  MERGED="$(echo "$MERGED" | yq eval-all 'select(fileIndex == 0) * select(fileIndex == 1)' - "$ADMIN_BACKUP_FILE")"
fi

# --- Step 4: Extract client config from clients.yaml ---
CLIENTS_FILE="$ADMIN_ENV_DIR/clients.yaml"
if [[ ! -f "$CLIENTS_FILE" ]]; then
  echo "ERROR: Admin clients.yaml not found: $CLIENTS_FILE"
  exit 1
fi

CLIENT_CONFIG="$(yq ".clients.\"$INS\"" "$CLIENTS_FILE")"
if [[ "$CLIENT_CONFIG" == "null" ]]; then
  echo "ERROR: Client '$INS' not found in $CLIENTS_FILE"
  exit 1
fi

CLIENT_DCS="$(echo "$CLIENT_CONFIG" | yq_raw '.datacenters[]')"
CLIENT_S3_BUCKET="$(echo "$CLIENT_CONFIG" | yq_raw '.s3Bucket')"
REPLICATION_ENABLED="$(echo "$CLIENT_CONFIG" | yq_raw '.replication.enabled // false')"

# Determine primary datacenter (admin-configured)
PRIMARY_DC="$(echo "$CLIENT_CONFIG" | yq_raw '.primaryDatacenter // .datacenters[0]')"

# Determine current datacenter (deployment target)
# Use explicit DC input, or fall back to first DC in client list
if [[ -n "$DC_INPUT" ]]; then
  CURRENT_DC="${DC_INPUT,,}"
else
  CURRENT_DC="$(echo "$CLIENT_DCS" | head -1)"
fi
echo "    Current DC: $CURRENT_DC (primary: $PRIMARY_DC)"

# Determine if this is the primary cluster
if [[ "$REPLICATION_ENABLED" == "true" && "$CURRENT_DC" != "$PRIMARY_DC" ]]; then
  IS_PRIMARY=false
else
  IS_PRIMARY=true
fi

# --- Step 4b: Resolve storage profile ---
STORAGE_PROFILE="$(echo "$CLIENT_CONFIG" | yq_raw '.storageProfile // "S"')"
PROFILE_CONFIG="$(echo "$MERGED" | yq ".storageProfiles.\"$STORAGE_PROFILE\"")"
if [[ "$PROFILE_CONFIG" == "null" || -z "$PROFILE_CONFIG" ]]; then
  echo "ERROR: Storage profile '$STORAGE_PROFILE' not found in postgresql.yaml storageProfiles"
  exit 1
fi

# Merge profile values (storage.size + resources) into postgresql section
PROFILE_YAML="$(cat <<PROFEOF
postgresql:
  storage:
    size: $(echo "$PROFILE_CONFIG" | yq_raw '.storage.size')
  resources:
    requests:
      memory: $(echo "$PROFILE_CONFIG" | yq_raw '.resources.requests.memory')
      cpu: $(echo "$PROFILE_CONFIG" | yq_raw '.resources.requests.cpu')
    limits:
      memory: $(echo "$PROFILE_CONFIG" | yq_raw '.resources.limits.memory')
      cpu: $(echo "$PROFILE_CONFIG" | yq_raw '.resources.limits.cpu')
PROFEOF
)"
MERGED="$(echo "$MERGED" | yq eval-all 'select(fileIndex == 0) * select(fileIndex == 1)' - <(echo "$PROFILE_YAML"))"

# Remove storageProfiles from merged output (not needed in generated values)
MERGED="$(echo "$MERGED" | yq 'del(.storageProfiles)')"

# --- Step 5: Lookup current datacenter S3 config + DNS suffix ---
DC_FILE="$ADMIN_ENV_DIR/datacenters.yaml"
if [[ ! -f "$DC_FILE" ]]; then
  echo "ERROR: Admin datacenters.yaml not found: $DC_FILE"
  exit 1
fi

DC_CONFIG="$(yq ".datacenters.\"$CURRENT_DC\"" "$DC_FILE")"
if [[ "$DC_CONFIG" == "null" ]]; then
  echo "ERROR: Datacenter '$CURRENT_DC' not found in $DC_FILE"
  exit 1
fi

DC_S3_CONFIG="$(echo "$DC_CONFIG" | yq '.s3')"
DC_DNS_SUFFIX="$(echo "$DC_CONFIG" | yq_raw '.dnsSuffix // "svc.cluster.local"')"

if [[ "$DC_S3_CONFIG" == "null" ]]; then
  echo "ERROR: Datacenter '$CURRENT_DC' S3 config not found in $DC_FILE"
  exit 1
fi

S3_ENDPOINT="$(echo "$DC_S3_CONFIG" | yq_raw '.endpoint')"
S3_REGION="$(echo "$DC_S3_CONFIG" | yq_raw '.region')"

# --- Step 5c: Compute DNS aliases from datacenters.yaml dns config ---
DNS_ZONE="$(yq_raw '.dns.zone // ""' "$DC_FILE")"
DNS_PRIMARY_PREFIX="$(yq_raw '.dns.primaryPrefix // "primary"' "$DC_FILE")"
DNS_RO_PREFIX="$(echo "$DC_CONFIG" | yq_raw '.dns.roPrefix // ""')"

DNS_PRIMARY_FQDN=""
DNS_RO_FQDN=""
if [[ -n "$DNS_ZONE" ]]; then
  DNS_PRIMARY_FQDN="${DNS_PRIMARY_PREFIX}.${INS}-${ENV}.${DNS_ZONE}"
  if [[ -n "$DNS_RO_PREFIX" ]]; then
    DNS_RO_FQDN="${DNS_RO_PREFIX}.${INS}-${ENV}.${DNS_ZONE}"
  fi
fi

# --- Step 5b: Resolve per-client S3 credentials ---
# Local env: inline accessKey/secretKey strings in clients.yaml
# Real envs: reference a Vault-synced K8s secret name
CLIENT_S3_CREDS="$(echo "$CLIENT_CONFIG" | yq '.s3Credentials')"
S3_CREDS_SECRET_NAME="$(echo "$CLIENT_S3_CREDS" | yq_raw '.secretName // ""')"
S3_CREDS_ACCESS_KEY="$(echo "$CLIENT_S3_CREDS" | yq_raw '.accessKey // ""')"
S3_CREDS_SECRET_KEY="$(echo "$CLIENT_S3_CREDS" | yq_raw '.secretKey // ""')"

# --- Step 6: Compute derived values ---
# Destination paths include DC mention: INS-ENV-DC-BACKUP / INS-ENV-DC-REPLICA
BACKUP_DESTINATION_PATH="s3://${CLIENT_S3_BUCKET}/${INS}-${ENV}-${CURRENT_DC}-backup/"

# CNPG RW service host (used by pgAdmin and external connections)
CNPG_HOST="${CLUSTER_NAME}-rw.${NAMESPACE}.${DC_DNS_SUFFIX}"

# Build external clusters list for replication
EXTERNAL_CLUSTERS_YAML=""
if [[ "$REPLICATION_ENABLED" == "true" ]]; then
  EXTERNAL_CLUSTERS_YAML="externalClusters:"
  while IFS= read -r dc; do
    if [[ "$dc" != "$CURRENT_DC" ]]; then
      # Replication path for remote DC
      REPLICA_PATH="s3://${CLIENT_S3_BUCKET}/${INS}-${ENV}-${dc}-replica/"
      REMOTE_S3_ENDPOINT="$(yq_raw ".datacenters.\"$dc\".s3.endpoint" "$DC_FILE")"
      EXTERNAL_CLUSTERS_YAML="$EXTERNAL_CLUSTERS_YAML
  - name: ${CLUSTER_NAME}-${dc}
    barmanObjectStore:
      destinationPath: ${REPLICA_PATH}
      endpointURL: ${REMOTE_S3_ENDPOINT}"
    fi
  done <<< "$CLIENT_DCS"
fi

# --- Step 7: Assemble final values and write ---
mkdir -p "$OUTPUT_DIR"

# Build S3 credentials section
S3_CREDS_YAML=""
if [[ -n "$S3_CREDS_SECRET_NAME" ]]; then
  # Real env: reference Vault-synced secret by name
  S3_CREDS_YAML="  credentials:
    secretName: $S3_CREDS_SECRET_NAME"
elif [[ -n "$S3_CREDS_ACCESS_KEY" ]]; then
  # Local env: inline credentials
  S3_CREDS_YAML="  credentials:
    accessKey: $S3_CREDS_ACCESS_KEY
    secretKey: $S3_CREDS_SECRET_KEY"
fi

# Write base computed YAML
COMPUTED_YAML="$(cat <<EOF
clusterName: $CLUSTER_NAME
namespace: $NAMESPACE
ins: $INS
env: $ENV
teamEnv: $TEAM_ENV
isPrimary: $IS_PRIMARY
datacenter:
  name: $CURRENT_DC
  dnsSuffix: $DC_DNS_SUFFIX
s3:
  endpoint: $S3_ENDPOINT
  region: $S3_REGION
  bucket: $CLIENT_S3_BUCKET
  destinationPath: $BACKUP_DESTINATION_PATH
$S3_CREDS_YAML
replication:
  enabled: $REPLICATION_ENABLED
  primaryDatacenter: $PRIMARY_DC
dns:
  zone: ${DNS_ZONE}
  primaryFqdn: ${DNS_PRIMARY_FQDN}
  roFqdn: ${DNS_RO_FQDN}
EOF
)"

if [[ -n "$EXTERNAL_CLUSTERS_YAML" ]]; then
  COMPUTED_YAML="$COMPUTED_YAML
$EXTERNAL_CLUSTERS_YAML"
fi

# Merge: user base + admin overrides + computed values
FINAL="$(echo "$MERGED" | yq eval-all 'select(fileIndex == 0) * select(fileIndex == 1)' - <(echo "$COMPUTED_YAML"))"

# --- Step 8: Add pgAdmin4 CNPG connection config ---
DB_LIST="$(echo "$FINAL" | yq_raw '.databases[] | .name' 2>/dev/null || echo "")"
if [[ -n "$DB_LIST" ]]; then
  # Build pgadmin4 databases array via yq
  PGADMIN_YAML="pgadmin4:"
  if [[ "$ENV" != "local" ]]; then
    PGADMIN_YAML="$PGADMIN_YAML
  defaultPasswordCreate: false"
  fi
  PGADMIN_YAML="$PGADMIN_YAML
  tls:
    enabled: true
    secretName: ${CLUSTER_NAME}-pgadmin-server-tls
    issuerName: pgaas-ca-issuer
    issuerKind: ClusterIssuer
    dnsNames:
      - pgadmin-${CLUSTER_NAME}
      - pgadmin-${CLUSTER_NAME}.${NAMESPACE}.svc
      - pgadmin-${CLUSTER_NAME}.${NAMESPACE}.svc.cluster.local
      - pgadmin-${CLUSTER_NAME}.${NAMESPACE}.${DC_DNS_SUFFIX}
  cnpg:
    clusterName: $CLUSTER_NAME
    host: $CNPG_HOST
    port: 5432
    tlsSecret: pgadmin_readonly-client-tls
    caSecret: pgaas-root-ca
    databases:"
  while IFS= read -r db; do
    PGADMIN_YAML="$PGADMIN_YAML
      - name: $db"
  done <<< "$DB_LIST"

  # Add LDAP config — env-aware: local derives from openldap.yaml, real envs from ldap.yaml
  # Bind credentials are always per-client from clients.yaml
  LDAP_SERVER_URI=""
  LDAP_BASE_DN=""
  LDAP_SEARCH_FILTER=""

  if [[ "$ENV" == "local" ]]; then
    OPENLDAP_FILE="$ADMIN_ENV_DIR/openldap.yaml"
    if [[ -f "$OPENLDAP_FILE" ]]; then
      LDAP_SVC_NAME="$(yq_raw '.openldap.service.name' "$OPENLDAP_FILE")"
      LDAP_SVC_NS="$(yq_raw '.openldap.service.namespace' "$OPENLDAP_FILE")"
      LDAP_SVC_PORT="$(yq_raw '.openldap.service.port' "$OPENLDAP_FILE")"
      LDAP_BASE_DN="ou=people,$(yq_raw '.openldap.baseDn' "$OPENLDAP_FILE")"
      LDAP_SERVER_URI="ldap://${LDAP_SVC_NAME}.${LDAP_SVC_NS}.svc.cluster.local:${LDAP_SVC_PORT}"
    fi
  else
    LDAP_FILE="$ADMIN_ENV_DIR/ldap.yaml"
    if [[ -f "$LDAP_FILE" ]]; then
      LDAP_SERVER_URI="$(yq_raw '.ldap.serverUri' "$LDAP_FILE")"
      LDAP_BASE_DN="$(yq_raw '.ldap.baseDn' "$LDAP_FILE")"
      LDAP_SEARCH_FILTER="$(yq_raw '.ldap.searchFilter // ""' "$LDAP_FILE")"
    fi
  fi

  if [[ -n "$LDAP_SERVER_URI" ]]; then
    # Read per-client LDAP bind credentials from clients.yaml
    LDAP_BIND_DN="$(echo "$CLIENT_CONFIG" | yq_raw '.ldapCredentials.bindDn // ""')"
    LDAP_BIND_PASSWORD="$(echo "$CLIENT_CONFIG" | yq_raw '.ldapCredentials.bindPassword // ""')"
    LDAP_BIND_PASSWORD_SECRET="$(echo "$CLIENT_CONFIG" | yq_raw '.ldapCredentials.bindPasswordSecret // ""')"

    PGADMIN_YAML="$PGADMIN_YAML
  ldap:
    enabled: true
    serverUri: ${LDAP_SERVER_URI}
    baseDn: ${LDAP_BASE_DN}"

    if [[ -n "$LDAP_SEARCH_FILTER" ]]; then
      PGADMIN_YAML="$PGADMIN_YAML
    searchFilter: '${LDAP_SEARCH_FILTER}'"
    fi

    if [[ -n "$LDAP_BIND_DN" ]]; then
      PGADMIN_YAML="$PGADMIN_YAML
    bindUser: ${LDAP_BIND_DN}"
    fi

    if [[ -n "$LDAP_BIND_PASSWORD" ]]; then
      # Inline password (local env) — chart creates the secret, reference it
      PGADMIN_YAML="$PGADMIN_YAML
    bindPassword: ${LDAP_BIND_PASSWORD}
    bindPasswordSecret: pgaas-core-pgadmin4-ldap-bind"
    elif [[ -n "$LDAP_BIND_PASSWORD_SECRET" ]]; then
      # Vault-synced secret (real envs)
      PGADMIN_YAML="$PGADMIN_YAML
    bindPasswordSecret: ${LDAP_BIND_PASSWORD_SECRET}"
    fi
  fi

  FINAL="$(echo "$FINAL" | yq eval-all 'select(fileIndex == 0) * select(fileIndex == 1)' - <(echo "$PGADMIN_YAML"))"
fi

# --- Step 9: NetworkPolicy config ---
# Read per-client networkPolicy from clients.yaml; disable for local env
NETPOL_YAML="networkPolicy:"
if [[ "$TEAM_ENV" == "local" ]]; then
  NETPOL_YAML="$NETPOL_YAML
  enabled: false"
else
  NETPOL_YAML="$NETPOL_YAML
  enabled: true"

  # Read allowed namespaces from client config
  CLIENT_NP_NS="$(echo "$CLIENT_CONFIG" | yq_raw '.networkPolicy.allowedNamespaces // []')"
  if [[ "$CLIENT_NP_NS" != "[]" ]]; then
    NETPOL_YAML="$NETPOL_YAML
  allowedNamespaces:"
    while IFS= read -r ns; do
      [[ -z "$ns" ]] && continue
      NETPOL_YAML="$NETPOL_YAML
    - $ns"
    done <<< "$(echo "$CLIENT_CONFIG" | yq_raw '.networkPolicy.allowedNamespaces[]' 2>/dev/null)"
  fi

  # Read allowed CIDRs from client config
  CLIENT_NP_CIDR="$(echo "$CLIENT_CONFIG" | yq_raw '.networkPolicy.allowedCIDRs // []')"
  if [[ "$CLIENT_NP_CIDR" != "[]" ]]; then
    NETPOL_YAML="$NETPOL_YAML
  allowedCIDRs:"
    while IFS= read -r cidr; do
      [[ -z "$cidr" ]] && continue
      NETPOL_YAML="$NETPOL_YAML
    - $cidr"
    done <<< "$(echo "$CLIENT_CONFIG" | yq_raw '.networkPolicy.allowedCIDRs[]' 2>/dev/null)"
  fi
fi
FINAL="$(echo "$FINAL" | yq eval-all 'select(fileIndex == 0) * select(fileIndex == 1)' - <(echo "$NETPOL_YAML"))"

# --- Step 9b: RBAC config ---
# local: disabled; hp/perf: self-service (clientGroup); pprod/prod: admin-only
RBAC_YAML="rbac:"
if [[ "$TEAM_ENV" == "local" ]]; then
  RBAC_YAML="$RBAC_YAML
  enabled: false"
else
  RBAC_YAML="$RBAC_YAML
  enabled: true
  adminGroup: pgaas-admins"

  case "$TEAM_ENV" in
    hp|perf)
      RBAC_YAML="$RBAC_YAML
  clientGroup: pgaas-${INS}"
      ;;
    *)
      # pprod/prod: admin-only, no client group
      RBAC_YAML="$RBAC_YAML
  clientGroup: \"\""
      ;;
  esac
fi
FINAL="$(echo "$FINAL" | yq eval-all 'select(fileIndex == 0) * select(fileIndex == 1)' - <(echo "$RBAC_YAML"))"

echo "$FINAL" > "$OUTPUT_DIR/values.yaml"

# --- Step 10: Generate local-infra values if local env ---
if [[ "$ENV" == "local" ]]; then
  INFRA_OUTPUT_DIR="$GENERATED_DIR/local-infra"
  mkdir -p "$INFRA_OUTPUT_DIR"

  SEAWEEDFS_FILE="$ADMIN_ENV_DIR/seaweedfs.yaml"
  OPENLDAP_FILE="$ADMIN_ENV_DIR/openldap.yaml"

  # Generate SeaweedFS values
  if [[ -f "$SEAWEEDFS_FILE" ]]; then
    SEAWEEDFS_YAML="$(cat <<SWEOF
s3:
  accessKey: $(yq_raw '.seaweedfs.s3.accessKey' "$SEAWEEDFS_FILE")
  secretKey: $(yq_raw '.seaweedfs.s3.secretKey' "$SEAWEEDFS_FILE")
  port: $(yq_raw '.seaweedfs.s3.port' "$SEAWEEDFS_FILE")
volume:
  storage:
    size: $(yq_raw '.seaweedfs.storage.size' "$SEAWEEDFS_FILE")
SWEOF
)"
    echo "$SEAWEEDFS_YAML" > "$INFRA_OUTPUT_DIR/seaweedfs-values.yaml"
    echo "    Generated: local-infra/seaweedfs-values.yaml"
  fi

  # Generate OpenLDAP values with seed users from all clients
  if [[ -f "$OPENLDAP_FILE" ]]; then
    OPENLDAP_YAML="$(cat <<LDEOF
organization: $(yq_raw '.openldap.organization' "$OPENLDAP_FILE")
domain: $(yq_raw '.openldap.domain' "$OPENLDAP_FILE")
baseDn: $(yq_raw '.openldap.baseDn' "$OPENLDAP_FILE")
adminPassword: $(yq_raw '.openldap.adminPassword' "$OPENLDAP_FILE")
configPassword: $(yq_raw '.openldap.configPassword' "$OPENLDAP_FILE")
LDEOF
)"

    # Auto-generate one LDAP user per client: cn=INS, uid=INS, mail=mail@INS.local
    SEED_USERS="seedUsers:"
    for client_dir in "$USERS_DIR"/*/local; do
      [[ -d "$client_dir" ]] || continue
      client_ins="$(basename "$(dirname "$client_dir")")"
      SEED_USERS="$SEED_USERS
  - cn: ${client_ins}
    sn: ${client_ins}
    uid: ${client_ins}
    password: ${client_ins}
    mail: mail@${client_ins}.local"
    done

    OPENLDAP_YAML="$OPENLDAP_YAML
$SEED_USERS"
    echo "$OPENLDAP_YAML" > "$INFRA_OUTPUT_DIR/openldap-values.yaml"
    echo "    Generated: local-infra/openldap-values.yaml"
  fi
fi

echo "==> Generated: $OUTPUT_DIR/values.yaml"

# --- Step 11: Generate observability values if local env ---
# Only generated once (not per-client); reads clients.yaml to build Grafana folder list.
if [[ "$ENV" == "local" ]]; then
  OBS_FILE="$ADMIN_ENV_DIR/observability.yaml"
  if [[ -f "$OBS_FILE" ]]; then
    echo ""
    echo "==> Generating local-infra/observability-values.yaml"

    # Base values from admin observability.yaml (unwrap top-level 'observability' key)
    OBS_BASE="$(yq '.observability' "$OBS_FILE")"

    # Build clients list from all clients that have a local env directory
    CLIENTS_YAML="clients:"
    for client_dir in "$USERS_DIR"/*/local; do
      [[ -d "$client_dir" ]] || continue
      client_ins="$(basename "$(dirname "$client_dir")")"
      CLIENTS_YAML="$CLIENTS_YAML
  - ins: ${client_ins}
    env: local"
    done

    # Flatten observability sub-keys into top-level chart values and append clients list
    OBS_VALUES="$(echo "$OBS_BASE" | yq eval-all 'select(fileIndex == 0) * select(fileIndex == 1)' - <(echo "$CLIENTS_YAML"))"
    echo "$OBS_VALUES" > "$INFRA_OUTPUT_DIR/observability-values.yaml"
    echo "    Generated: local-infra/observability-values.yaml"
  else
    echo "    (no confs/admin/local/observability.yaml — skipping observability values)"
  fi
fi
