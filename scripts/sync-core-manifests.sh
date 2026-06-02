#!/usr/bin/env bash
# Compatibility wrapper for the native wfctl core manifest sync.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW_REPO="${WORKFLOW_REPO:-${REPO_ROOT}/../workflow}"

if ! command -v wfctl >/dev/null 2>&1; then
  echo "error: wfctl is required; install it with GoCodeAlone/setup-wfctl or from a workflow release" >&2
  exit 1
fi

if [[ ! -f "${WORKFLOW_REPO}/go.mod" ]]; then
  echo "error: WORKFLOW_REPO must point to a workflow checkout: ${WORKFLOW_REPO}" >&2
  exit 1
fi

exec wfctl plugin registry-sync core \
  --registry-dir "${REPO_ROOT}" \
  --workflow-repo "${WORKFLOW_REPO}" \
  "$@"
