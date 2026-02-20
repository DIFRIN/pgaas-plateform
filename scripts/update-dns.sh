#!/usr/bin/env bash
# update-dns.sh — Update the primary DNS alias after a switchover/promotion.
#
# Usage:
#   update-dns.sh <dns_fqdn> <target_fqdn> [<kube_context>]
#
#   dns_fqdn    — the alias to update (e.g. primary.ic1-prod.example.com)
#   target_fqdn — the new RW service FQDN (e.g. prod-ic1-dc2-rw.ic1-prod.dc2.example.com)
#   kube_context — optional kubectl context (for CoreDNS rewrite on local env)
#
# Backends (auto-detected, in priority order):
#   1. ExternalDNS DNSEndpoint CRD  — if the CRD exists in the cluster
#   2. CoreDNS ConfigMap rewrite    — for local/minikube environments
#   3. No-op with clear instructions — if neither is available
#
# For production, extend or replace this script with a backend that calls your
# DNS provider's API (Route53, Azure DNS, Infoblox, etc.).
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

DNS_FQDN="${1:-}"
TARGET_FQDN="${2:-}"
KUBE_CTX="${3:-}"

if [[ -z "$DNS_FQDN" || -z "$TARGET_FQDN" ]]; then
  echo "Usage: $0 <dns_fqdn> <target_fqdn> [<kube_context>]"
  echo "  dns_fqdn    — alias to update (e.g. primary.ic1-prod.example.com)"
  echo "  target_fqdn — new target FQDN (e.g. prod-ic1-dc2-rw.ic1-prod.dc2.example.com)"
  exit 1
fi

if [[ -n "$KUBE_CTX" ]]; then
  KUBE_CONTEXT="$KUBE_CTX"
fi

echo "==> Updating DNS alias"
echo "    $DNS_FQDN  →  $TARGET_FQDN"

# --- Backend 1: ExternalDNS DNSEndpoint CRD ---
if kctl get crd dnsendpoints.externaldns.k8s.io &>/dev/null 2>&1; then
  echo "    Backend: ExternalDNS DNSEndpoint CRD"

  # Find the primary DNSEndpoint across all namespaces
  ENDPOINT_NS="$(kctl get dnsendpoints \
    --all-namespaces \
    -o json 2>/dev/null \
    | yq '.items[] | select(.metadata.annotations["pgaas.io/dns-alias"] == "primary") | .metadata.namespace' \
    | head -1 || echo "")"

  ENDPOINT_NAME="$(kctl get dnsendpoints \
    --all-namespaces \
    -o json 2>/dev/null \
    | yq '.items[] | select(.metadata.annotations["pgaas.io/dns-alias"] == "primary") | .metadata.name' \
    | head -1 || echo "")"

  if [[ -n "$ENDPOINT_NS" && -n "$ENDPOINT_NAME" ]]; then
    kctl patch dnsendpoint "$ENDPOINT_NAME" -n "$ENDPOINT_NS" \
      --type=json \
      -p "[{\"op\":\"replace\",\"path\":\"/spec/endpoints/0/targets/0\",\"value\":\"${TARGET_FQDN}\"}]"
    echo "    Updated DNSEndpoint $ENDPOINT_NAME in namespace $ENDPOINT_NS"
  else
    echo "    No existing primary DNSEndpoint found — creating is handled by promote-cluster.sh"
  fi
  exit 0
fi

# --- Backend 2: CoreDNS ConfigMap (local/minikube) ---
# Rewrites the primary alias as a CNAME pointing to the target FQDN using
# CoreDNS rewrite plugin rules patched into the coredns ConfigMap.
if kctl get configmap coredns -n kube-system &>/dev/null 2>&1; then
  echo "    Backend: CoreDNS ConfigMap rewrite (local env)"

  # Extract the alias hostname (strip the zone suffix for the rewrite rule)
  ALIAS_HOST="${DNS_FQDN%%.*}"  # e.g. "primary" from "primary.ic1-prod.pgaas.local"

  # We inject a literal CNAME entry into CoreDNS using the template plugin or
  # rewrite plugin. The simplest portable approach for local dev is to patch the
  # Corefile with a hosts/rewrite stanza.
  #
  # Build a hosts entry block: the alias resolves to the same IP as the target
  # (since in-cluster CNAME to an external host requires DNS chaining).
  # For local minikube, we resolve the target to the minikube node IP and map
  # the alias to that same IP.

  local_target_ip=""
  if command -v minikube &>/dev/null; then
    local_target_ip="$(minikube ip -p "${KUBE_CONTEXT:-minikube}" 2>/dev/null || echo "")"
  fi
  if [[ -z "$local_target_ip" ]]; then
    local_target_ip="$(kctl get nodes \
      -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' \
      2>/dev/null || echo "")"
  fi

  if [[ -z "$local_target_ip" ]]; then
    echo "    WARNING: Cannot determine cluster node IP for CoreDNS rewrite"
    _print_manual_instructions
    exit 0
  fi

  # Patch the coredns ConfigMap: add/replace a hosts block for the alias
  CURRENT_COREFILE="$(kctl get configmap coredns -n kube-system -o jsonpath='{.data.Corefile}')"

  # Remove any previous pgaas-primary rewrite block
  CLEANED_COREFILE="$(echo "$CURRENT_COREFILE" \
    | sed '/# pgaas-primary-dns-start/,/# pgaas-primary-dns-end/d')"

  HOSTS_BLOCK="# pgaas-primary-dns-start
        hosts {
          ${local_target_ip} ${DNS_FQDN}
          fallthrough
        }
        # pgaas-primary-dns-end"

  # Inject before the first closing brace of the top-level server block
  PATCHED_COREFILE="$(echo "$CLEANED_COREFILE" \
    | sed "0,/^}/s|^}|${HOSTS_BLOCK}\n}|")"

  kctl create configmap coredns \
    -n kube-system \
    --from-literal="Corefile=${PATCHED_COREFILE}" \
    --dry-run=client -o yaml \
    | kctl apply -f -

  # Restart CoreDNS to pick up the change
  kctl rollout restart deployment/coredns -n kube-system >/dev/null 2>&1 || true
  echo "    CoreDNS ConfigMap patched: $DNS_FQDN → $local_target_ip"
  echo "    NOTE: In-cluster pods will resolve $DNS_FQDN to $local_target_ip"
  echo "          Update /etc/hosts on your workstation for external access:"
  echo "          $local_target_ip  $DNS_FQDN"
  exit 0
fi

# --- Backend 3: No-op — print instructions ---
_print_manual_instructions() {
  echo ""
  echo "    No supported DNS backend detected."
  echo "    Update your DNS provider manually:"
  echo ""
  echo "      Record type : CNAME"
  echo "      Name        : $DNS_FQDN"
  echo "      Target      : $TARGET_FQDN"
  echo "      TTL         : 60"
  echo ""
  echo "    For ExternalDNS: ensure the DNSEndpoint CRD is installed and"
  echo "    re-run after ExternalDNS is ready."
}

_print_manual_instructions
