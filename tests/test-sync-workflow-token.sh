#!/usr/bin/env bash
set -euo pipefail

workflow=".github/workflows/sync-registry-manifests.yml"

if ! grep -Fq 'GH_TOKEN: ${{ secrets.RELEASES_TOKEN || secrets.GITHUB_TOKEN }}' "$workflow"; then
  echo "sync-registry-manifests must expose RELEASES_TOKEN to wfctl for private plugin releases" >&2
  exit 1
fi
