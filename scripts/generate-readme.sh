#!/usr/bin/env bash
# Compatibility wrapper for the native wfctl README renderer.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! command -v wfctl >/dev/null 2>&1; then
  echo "error: wfctl is required; install it with GoCodeAlone/setup-wfctl or from a workflow release" >&2
  exit 1
fi

exec wfctl plugin registry-sync readme --registry-dir "${REPO_ROOT}" "$@"
