#!/usr/bin/env bash
set -euo pipefail

workflow=".github/workflows/build-pages.yml"
script="scripts/build-versions.sh"

if ! grep -Fq 'GH_TOKEN: ${{ secrets.RELEASES_TOKEN || secrets.GITHUB_TOKEN }}' "$workflow"; then
  echo "build-pages must expose RELEASES_TOKEN to version metadata generation" >&2
  exit 1
fi

if ! grep -Fq 'run_gh release list' "$script" || ! grep -Fq 'run_gh release view' "$script"; then
  echo "build-versions must wrap gh release calls with a timeout guard" >&2
  exit 1
fi

if ! grep -Fq 'release_cache_root=' "$script" || ! grep -Fq 'repo_cache_dir=' "$script"; then
  echo "build-versions must cache release API responses by repository" >&2
  exit 1
fi
