#!/usr/bin/env bash

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

MISSING=0

check_tool() {
  local name="$1" required="${2:-true}" version_cmd="${3:-}"
  if command -v "$name" &>/dev/null; then
    local version
    if [[ -n "$version_cmd" ]]; then
      version="$(eval "$version_cmd" 2>&1 | head -1)"
    else
      version="$(command -v "$name")"
    fi
    echo -e "  ${GREEN}✓${NC} $name — $version"
  elif [[ "$required" == "true" ]]; then
    echo -e "  ${RED}✗${NC} $name — NOT FOUND (required)"
    MISSING=$((MISSING + 1))
  else
    echo -e "  ${YELLOW}!${NC} $name — not found (optional)"
  fi
}

echo "PGaaS — Required CLI tools"
echo ""

echo "Required:"
check_tool yq true "yq --version"
check_tool helm true "helm version --short"
check_tool helmfile true "helmfile --version"
check_tool kubectl true "kubectl version --client 2>/dev/null | head -1"

echo ""
echo "Optional:"
check_tool jq false "jq --version"

echo ""
if [[ $MISSING -gt 0 ]]; then
  echo -e "${RED}$MISSING required tool(s) missing. Please install them before continuing.${NC}"
  exit 1
else
  echo -e "${GREEN}All required tools are installed.${NC}"
fi
