#!/usr/bin/env bash
# Compatibility wrapper for the native wfctl core manifest sync.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW_REPO="${WORKFLOW_REPO:-${REPO_ROOT}/../workflow}"

exec wfctl plugin registry-sync core \
  --registry-dir "${REPO_ROOT}" \
  --workflow-repo "${WORKFLOW_REPO}" \
  "$@"
