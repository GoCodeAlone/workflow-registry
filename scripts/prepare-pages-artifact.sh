#!/usr/bin/env bash
# scripts/prepare-pages-artifact.sh
#
# Builds the final GitHub Pages artifact from generated v1 registry data.
# The artifact publishes root endpoints for current static consumers and a
# /v1 mirror for wfctl and versioned API consumers.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
SRC_DIR="${REPO_ROOT}/v1"
OUT_DIR="${REPO_ROOT}/public"

if [[ ! -d "${SRC_DIR}" ]]; then
  echo "error: generated registry directory not found: ${SRC_DIR}" >&2
  exit 1
fi

rm -rf "${OUT_DIR}"
mkdir -p "${OUT_DIR}" "${OUT_DIR}/v1"

cp -R "${SRC_DIR}/." "${OUT_DIR}/"
cp -R "${SRC_DIR}/." "${OUT_DIR}/v1/"

echo "Prepared Pages artifact at ${OUT_DIR} with root and /v1 registry paths."
