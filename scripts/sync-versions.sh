#!/usr/bin/env bash
# Compatibility wrapper for the native wfctl release metadata sync.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec wfctl plugin registry-sync --registry-dir "${REPO_ROOT}" "$@"
