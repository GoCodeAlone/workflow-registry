#!/usr/bin/env bash
# Compatibility wrapper for the native wfctl README renderer.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec wfctl plugin registry-sync readme --registry-dir "${REPO_ROOT}" "$@"
