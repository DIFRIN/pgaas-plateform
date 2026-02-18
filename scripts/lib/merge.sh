#!/usr/bin/env bash
set -euo pipefail

# Deep merge two YAML files. The second file (override) wins on conflicts.
# Usage: deep_merge <base_file> <override_file>
# Outputs merged YAML to stdout.
deep_merge() {
  local base="$1"
  local override="$2"

  if [[ ! -f "$base" ]]; then
    echo "ERROR: Base file not found: $base" >&2
    return 1
  fi
  if [[ ! -f "$override" ]]; then
    echo "ERROR: Override file not found: $override" >&2
    return 1
  fi

  yq eval-all 'select(fileIndex == 0) * select(fileIndex == 1)' "$base" "$override"
}

# Deep merge, but only if the override file exists. Otherwise output the base as-is.
# Usage: deep_merge_optional <base_file> <override_file>
deep_merge_optional() {
  local base="$1"
  local override="$2"

  if [[ ! -f "$base" ]]; then
    echo "ERROR: Base file not found: $base" >&2
    return 1
  fi

  if [[ -f "$override" ]]; then
    yq eval-all 'select(fileIndex == 0) * select(fileIndex == 1)' "$base" "$override"
  else
    cat "$base"
  fi
}

# Merge multiple files in order (each subsequent file overrides the previous).
# Usage: deep_merge_chain <file1> <file2> [file3 ...]
# Files that don't exist are skipped.
deep_merge_chain() {
  local files=("$@")
  local result=""

  for f in "${files[@]}"; do
    if [[ ! -f "$f" ]]; then
      continue
    fi
    if [[ -z "$result" ]]; then
      result="$(cat "$f")"
    else
      result="$(echo "$result" | yq eval-all 'select(fileIndex == 0) * select(fileIndex == 1)' - "$f")"
    fi
  done

  echo "$result"
}
