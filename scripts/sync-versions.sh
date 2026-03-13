#!/usr/bin/env bash
# sync-versions.sh — checks that each plugin manifest version matches the
# latest GitHub release tag. With --fix, updates manifest versions in-place.
#
# Usage:
#   scripts/sync-versions.sh [--fix]
#
# Requirements: gh (GitHub CLI), jq

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGINS_DIR="$REPO_ROOT/plugins"
FIX=false

for arg in "$@"; do
  case "$arg" in
    --fix) FIX=true ;;
    *) echo "Unknown argument: $arg" >&2; exit 1 ;;
  esac
done

mismatches=0

for manifest in "$PLUGINS_DIR"/*/manifest.json; do
  plugin_name="$(basename "$(dirname "$manifest")")"

  # Extract repository field (may be absent)
  repo_url="$(jq -r '.repository // empty' "$manifest")"
  if [[ -z "$repo_url" ]]; then
    continue
  fi

  # Derive owner/repo from GitHub URL (e.g. https://github.com/org/repo)
  gh_repo="$(echo "$repo_url" | sed -E 's|https://github.com/||')"
  if [[ -z "$gh_repo" ]]; then
    continue
  fi

  manifest_version="$(jq -r '.version' "$manifest")"

  # Query latest release tag; skip plugins with no releases
  latest_tag="$(gh release view --repo "$gh_repo" --json tagName -q '.tagName' 2>/dev/null || true)"
  if [[ -z "$latest_tag" ]]; then
    echo "  SKIP  $plugin_name — no release found for $gh_repo"
    continue
  fi

  # Strip leading 'v' prefix
  latest_version="${latest_tag#v}"

  if [[ "$manifest_version" == "$latest_version" ]]; then
    echo "    OK  $plugin_name $manifest_version"
  else
    echo " MISMATCH  $plugin_name: manifest=$manifest_version latest=$latest_version ($gh_repo)"
    mismatches=$((mismatches + 1))
    if $FIX; then
      tmp="$(mktemp)"
      jq --arg v "$latest_version" '.version = $v' "$manifest" > "$tmp"
      mv "$tmp" "$manifest"
      echo "   FIXED  $plugin_name → $latest_version"
    fi
  fi
done

if [[ $mismatches -gt 0 ]]; then
  if $FIX; then
    echo ""
    echo "Fixed $mismatches version mismatch(es)."
  else
    echo ""
    echo "Found $mismatches version mismatch(es). Re-run with --fix to update."
    exit 1
  fi
else
  echo ""
  echo "All manifest versions are in sync."
fi
