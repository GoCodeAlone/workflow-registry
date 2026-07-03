#!/usr/bin/env bash
# tests/test-prepare-pages-artifact.sh
#
# Regression coverage for scripts/prepare-pages-artifact.sh. The deployed
# Pages artifact must expose registry data at the site root and at /v1 so
# existing root consumers and wfctl's /v1 default both resolve.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT_REAL="$(cd "${SCRIPT_DIR}/.." && pwd)"

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

mkdir -p "${tmp}/v1/plugins/portfolio" "${tmp}/public/plugins/stale"

cat > "${tmp}/v1/index.json" <<'JSON'
[
  {
    "name": "portfolio",
    "version": "0.3.2"
  }
]
JSON

cat > "${tmp}/v1/plugins/portfolio/manifest.json" <<'JSON'
{
  "name": "portfolio",
  "version": "0.3.2"
}
JSON

cat > "${tmp}/v1/plugins/portfolio/latest.json" <<'JSON'
{
  "version": "0.3.2",
  "downloads": []
}
JSON

printf 'remove me\n' > "${tmp}/public/stale.txt"
printf 'stale plugin\n' > "${tmp}/public/plugins/stale/manifest.json"

REPO_ROOT="${tmp}" bash "${REPO_ROOT_REAL}/scripts/prepare-pages-artifact.sh" >/dev/null

cmp --silent "${tmp}/v1/index.json" "${tmp}/public/index.json" || \
  fail "root index.json is not byte-identical to v1/index.json"
cmp --silent "${tmp}/v1/index.json" "${tmp}/public/v1/index.json" || \
  fail "v1 index.json compatibility copy is not byte-identical"
cmp --silent "${tmp}/v1/plugins/portfolio/manifest.json" "${tmp}/public/plugins/portfolio/manifest.json" || \
  fail "root manifest.json is not byte-identical"
cmp --silent "${tmp}/v1/plugins/portfolio/manifest.json" "${tmp}/public/v1/plugins/portfolio/manifest.json" || \
  fail "v1 manifest.json compatibility copy is not byte-identical"
cmp --silent "${tmp}/v1/plugins/portfolio/latest.json" "${tmp}/public/plugins/portfolio/latest.json" || \
  fail "root latest.json is not byte-identical"
cmp --silent "${tmp}/v1/plugins/portfolio/latest.json" "${tmp}/public/v1/plugins/portfolio/latest.json" || \
  fail "v1 latest.json compatibility copy is not byte-identical"

[[ ! -e "${tmp}/public/stale.txt" ]] || fail "stale public root file was not removed"
[[ ! -e "${tmp}/public/plugins/stale/manifest.json" ]] || fail "stale public plugin file was not removed"

echo "OK - test-prepare-pages-artifact.sh passed"
