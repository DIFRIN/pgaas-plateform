#!/usr/bin/env bash
set -euo pipefail

_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$_COMMON_DIR/.." && pwd)"
PROJECT_ROOT="$(cd "$SCRIPTS_DIR/.." && pwd)"

CORE_DIR="$PROJECT_ROOT/core"
CONFS_DIR="$PROJECT_ROOT/confs"
ADMIN_DIR="$CONFS_DIR/admin"
USERS_DIR="$CONFS_DIR/users"
GENERATED_DIR="$CONFS_DIR/_generated"
LOCAL_INFRA_DIR="$PROJECT_ROOT/local-infra"

FIXED_ENVS=("local" "perf" "pprod" "prod")

usage_common() {
  echo "Usage: $0 <INS> <ENV> [DC]"
  echo "  INS  - Client INS code (e.g., ic1, is1)"
  echo "  ENV  - Environment (local, hp sub-env name, perf, pprod, prod)"
  echo "  DC   - Datacenter (e.g., dc1, dc2). Defaults to client's first DC."
  exit 1
}

validate_inputs() {
  local ins="${1:-}"
  local env="${2:-}"

  if [[ -z "$ins" || -z "$env" ]]; then
    echo "ERROR: INS and ENV are required."
    usage_common
  fi

  INS="${ins,,}"
  ENV="${env,,}"
}

# Determine if ENV is a fixed env or an HP sub-env.
# Sets: ADMIN_ENV_DIR, USER_ENV_DIR, TEAM_ENV, IS_HP_SUBENV
resolve_env() {
  IS_HP_SUBENV=false
  for fixed in "${FIXED_ENVS[@]}"; do
    if [[ "$ENV" == "$fixed" ]]; then
      TEAM_ENV="$ENV"
      ADMIN_ENV_DIR="$ADMIN_DIR/$ENV"
      USER_ENV_DIR="$USERS_DIR/$INS/$ENV"
      return
    fi
  done

  IS_HP_SUBENV=true
  TEAM_ENV="hp"
  ADMIN_ENV_DIR="$ADMIN_DIR/hp"
  USER_ENV_DIR="$USERS_DIR/$INS/hp/$ENV"
}

compute_names() {
  CLUSTER_NAME="${ENV}-${INS}"
  NAMESPACE="${INS}-${ENV}"
}

validate_paths() {
  if [[ ! -d "$ADMIN_ENV_DIR" ]]; then
    echo "ERROR: Admin values directory not found: $ADMIN_ENV_DIR"
    exit 1
  fi

  if [[ ! -d "$USER_ENV_DIR" ]]; then
    echo "ERROR: User values directory not found: $USER_ENV_DIR"
    exit 1
  fi
}

# Resolve the kubeContext for a datacenter from datacenters.yaml.
# Sets KUBE_CONTEXT if the DC has a kubeContext field, otherwise leaves it empty.
# Usage: resolve_kube_context <dc> <dc_file>
resolve_kube_context() {
  local dc="${1:-}"
  local dc_file="${2:-}"
  KUBE_CONTEXT=""

  if [[ -z "$dc" || -z "$dc_file" || ! -f "$dc_file" ]]; then
    return
  fi

  local ctx
  ctx="$(yq ".datacenters.\"$dc\".kubeContext // \"\"" "$dc_file")"
  if [[ -n "$ctx" ]]; then
    KUBE_CONTEXT="$ctx"
  fi
}

# kubectl wrapper: uses --context if KUBE_CONTEXT is set
kctl() {
  if [[ -n "${KUBE_CONTEXT:-}" ]]; then
    kubectl --context "$KUBE_CONTEXT" "$@"
  else
    kubectl "$@"
  fi
}

# helmfile wrapper: uses --kube-context if KUBE_CONTEXT is set
hfile() {
  if [[ -n "${KUBE_CONTEXT:-}" ]]; then
    helmfile --kube-context "$KUBE_CONTEXT" "$@"
  else
    helmfile "$@"
  fi
}

setup() {
  validate_inputs "${1:-}" "${2:-}"
  resolve_env
  compute_names
  validate_paths
}
