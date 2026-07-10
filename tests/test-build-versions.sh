#!/usr/bin/env bash
# tests/test-build-versions.sh
#
# Regression coverage for scripts/build-versions.sh. The version builder should
# fetch GitHub release metadata and assets in one cached REST call per upstream
# repo, preserving the public versions.json/latest.json contract.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT_REAL="$(cd "${SCRIPT_DIR}/.." && pwd)"

if ! command -v jq &>/dev/null; then
  echo "error: jq required" >&2
  exit 1
fi

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

mkdir -p "${tmp}/scripts" \
  "${tmp}/plugins/plugin-alpha" \
  "${tmp}/plugins/plugin-beta" \
  "${tmp}/plugins/plugin-local" \
  "${tmp}/plugins/plugin-prerelease-only" \
  "${tmp}/v1/plugins/plugin-prerelease-only" \
  "${tmp}/public/plugins/plugin-prerelease-only" \
  "${tmp}/public/v1/plugins/plugin-prerelease-only" \
  "${tmp}/bin"

cp "${REPO_ROOT_REAL}/scripts/build-index.sh" "${tmp}/scripts/build-index.sh"
cp "${REPO_ROOT_REAL}/scripts/build-versions.sh" "${tmp}/scripts/build-versions.sh"
cp "${REPO_ROOT_REAL}/scripts/prepare-pages-artifact.sh" "${tmp}/scripts/prepare-pages-artifact.sh"

cat > "${tmp}/plugins/plugin-alpha/manifest.json" <<'JSON'
{
  "name": "plugin-alpha",
  "version": "0.36.1",
  "repository": "https://github.com/example/shared-plugin",
  "minEngineVersion": "0.75.0"
}
JSON

cat > "${tmp}/plugins/plugin-beta/manifest.json" <<'JSON'
{
  "name": "plugin-beta",
  "version": "0.36.1",
  "repository": "https://github.com/example/shared-plugin.git",
  "minEngineVersion": "0.76.0"
}
JSON

cat > "${tmp}/plugins/plugin-prerelease-only/manifest.json" <<'JSON'
{
  "name": "plugin-prerelease-only",
  "repository": "https://github.com/example/prerelease-only"
}
JSON

cat > "${tmp}/v1/plugins/plugin-prerelease-only/latest.json" <<'JSON'
{
  "version": "0.9.0"
}
JSON
cp "${tmp}/v1/plugins/plugin-prerelease-only/latest.json" \
  "${tmp}/public/plugins/plugin-prerelease-only/latest.json"
cp "${tmp}/v1/plugins/plugin-prerelease-only/latest.json" \
  "${tmp}/public/v1/plugins/plugin-prerelease-only/latest.json"

cat > "${tmp}/plugins/plugin-local/manifest.json" <<'JSON'
{
  "name": "plugin-local",
  "repository": "https://gitlab.com/example/plugin-local"
}
JSON

calls_file="${tmp}/gh-api-calls"
: > "${calls_file}"

cat > "${tmp}/bin/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

if [[ "$1" != "api" ]]; then
  echo "unexpected gh invocation: gh $*" >&2
  exit 42
fi

endpoint="$2"
case "${endpoint}" in
  repos/example/shared-plugin/releases\?per_page=100)
    printf '%s\n' "${endpoint}" >> "${GH_CALLS_FILE}"
    cat <<'JSON'
[
  {
    "tag_name": "v1.0.0-rc.1",
    "published_at": "2026-07-10T12:00:00Z",
    "draft": false,
    "prerelease": true,
    "assets": []
  },
  {
    "tag_name": "v1.1.0",
    "published_at": "2026-07-09T12:00:00Z",
    "draft": true,
    "prerelease": false,
    "assets": []
  },
  {
    "tag_name": "v0.36.1",
    "published_at": "2026-07-08T12:00:00Z",
    "draft": false,
    "prerelease": false,
    "assets": [
      {
        "name": "workflow-plugin-shared-linux-amd64.tar.gz",
        "browser_download_url": "https://downloads.example/shared/v0.36.1/linux-amd64.tar.gz",
        "url": "https://api.github.com/repos/example/shared-plugin/releases/assets/1",
        "digest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      },
      {
        "name": "workflow-plugin-shared-darwin-arm64.tar.gz",
        "browser_download_url": "https://downloads.example/shared/v0.36.1/darwin-arm64.tar.gz",
        "url": "https://api.github.com/repos/example/shared-plugin/releases/assets/2",
        "digest": "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
      },
      {
        "name": "workflow-plugin-shared_0.36.1_windows_arm64.tar.gz",
        "browser_download_url": "https://downloads.example/shared/v0.36.1/windows-arm64.tar.gz",
        "url": "https://api.github.com/repos/example/shared-plugin/releases/assets/3",
        "digest": "sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
      },
      {
        "name": "checksums.txt",
        "browser_download_url": "https://downloads.example/shared/v0.36.1/checksums.txt",
        "digest": "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
      }
    ]
  }
]
JSON
    ;;
  repos/example/prerelease-only/releases\?per_page=100)
    printf '%s\n' "${endpoint}" >> "${GH_CALLS_FILE}"
    cat <<'JSON'
[
  {
    "tag_name": "v2.0.0-rc.1",
    "published_at": "2026-07-10T12:00:00Z",
    "draft": false,
    "prerelease": true,
    "assets": []
  },
  {
    "tag_name": "v1.0.0",
    "published_at": "2026-07-09T12:00:00Z",
    "draft": true,
    "prerelease": false,
    "assets": []
  }
]
JSON
    ;;
  *)
    echo "unexpected gh api endpoint: ${endpoint}" >&2
    exit 43
    ;;
esac
SH
chmod +x "${tmp}/bin/gh"

PATH="${tmp}/bin:${PATH}" \
  bash "${tmp}/scripts/build-index.sh" >/dev/null
GH_CALLS_FILE="${calls_file}" PATH="${tmp}/bin:${PATH}" \
  bash "${tmp}/scripts/build-versions.sh" >/dev/null
PATH="${tmp}/bin:${PATH}" \
  bash "${tmp}/scripts/prepare-pages-artifact.sh" >/dev/null

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_jq_file() {
  local desc="$1" file="$2" expr="$3" expected="$4"
  local actual
  actual="$(jq -c "${expr}" "${file}")"
  if [[ "${actual}" != "${expected}" ]]; then
    fail "${desc}: expected ${expected}, got ${actual}"
  fi
}

alpha_versions="${tmp}/v1/plugins/plugin-alpha/versions.json"
alpha_latest="${tmp}/v1/plugins/plugin-alpha/latest.json"
beta_latest="${tmp}/v1/plugins/plugin-beta/latest.json"
local_versions="${tmp}/v1/plugins/plugin-local/versions.json"
prerelease_versions="${tmp}/v1/plugins/plugin-prerelease-only/versions.json"
prerelease_latest="${tmp}/v1/plugins/plugin-prerelease-only/latest.json"
root_alpha_latest="${tmp}/public/plugins/plugin-alpha/latest.json"
v1_alpha_latest="${tmp}/public/v1/plugins/plugin-alpha/latest.json"

test -f "${alpha_versions}" || fail "plugin-alpha versions.json missing"
test -f "${alpha_latest}" || fail "plugin-alpha latest.json missing"
test -f "${beta_latest}" || fail "plugin-beta latest.json missing"
test -f "${local_versions}" || fail "plugin-local versions.json missing"
test -f "${prerelease_versions}" || fail "plugin-prerelease-only versions.json missing"
test -f "${root_alpha_latest}" || fail "public root plugin-alpha latest.json missing"
test -f "${v1_alpha_latest}" || fail "public v1 plugin-alpha latest.json missing"

assert_jq_file "alpha latest stays on stable release" "${alpha_latest}" '.version' '"0.36.1"'
assert_jq_file "alpha versions has two non-draft releases" "${alpha_versions}" '.versions | length' '2'
assert_jq_file "alpha RC retained as prerelease" "${alpha_versions}" \
  '.versions[] | select(.version=="1.0.0-rc.1") | .prerelease' 'true'
assert_jq_file "alpha stable release marked non-prerelease" "${alpha_versions}" \
  '.versions[] | select(.version=="0.36.1") | .prerelease' 'false'
assert_jq_file "alpha draft excluded" "${alpha_versions}" \
  '[.versions[] | select(.version=="1.1.0")] | length' '0'
assert_jq_file "canonical plugin index stays stable" "${tmp}/v1/index.json" \
  '.[] | select(.name=="plugin-alpha") | .version' '"0.36.1"'
assert_jq_file "public root plugin index stays stable" "${tmp}/public/index.json" \
  '.[] | select(.name=="plugin-alpha") | .version' '"0.36.1"'
assert_jq_file "public v1 plugin index stays stable" "${tmp}/public/v1/index.json" \
  '.[] | select(.name=="plugin-alpha") | .version' '"0.36.1"'
assert_jq_file "public root latest stays stable" "${root_alpha_latest}" \
  '.version' '"0.36.1"'
assert_jq_file "public v1 latest stays stable" "${v1_alpha_latest}" \
  '.version' '"0.36.1"'
assert_jq_file "alpha min engine propagated" "${alpha_latest}" '.minEngineVersion' '"0.75.0"'
assert_jq_file "matching assets only" "${alpha_latest}" '.downloads | length' '3'
assert_jq_file "download URL uses browser_download_url" "${alpha_latest}" \
  '.downloads[] | select(.os=="linux" and .arch=="amd64") | .url' \
  '"https://downloads.example/shared/v0.36.1/linux-amd64.tar.gz"'
assert_jq_file "sha256 prefix stripped" "${alpha_latest}" \
  '.downloads[] | select(.os=="linux" and .arch=="amd64") | .sha256' \
  '"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"'
assert_jq_file "underscore asset names are parsed" "${alpha_latest}" \
  '.downloads[] | select(.os=="windows" and .arch=="arm64") | .url' \
  '"https://downloads.example/shared/v0.36.1/windows-arm64.tar.gz"'
assert_jq_file "underscore asset sha256 prefix stripped" "${alpha_latest}" \
  '.downloads[] | select(.os=="windows" and .arch=="arm64") | .sha256' \
  '"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"'
assert_jq_file "beta reuses same release data with its own min engine" "${beta_latest}" \
  '.minEngineVersion' '"0.76.0"'
assert_jq_file "non-GitHub plugin writes empty versions" "${local_versions}" \
  '.versions' '[]'
assert_jq_file "prerelease-only repo retains RC history" "${prerelease_versions}" \
  '.versions[] | select(.version=="2.0.0-rc.1") | .prerelease' 'true'
assert_jq_file "prerelease-only repo excludes draft" "${prerelease_versions}" \
  '[.versions[] | select(.version=="1.0.0")] | length' '0'

[[ ! -e "${prerelease_latest}" ]] || fail "prerelease-only latest.json was not removed"
[[ ! -e "${tmp}/public/plugins/plugin-prerelease-only/latest.json" ]] || \
  fail "prerelease-only latest.json was published at root"
[[ ! -e "${tmp}/public/v1/plugins/plugin-prerelease-only/latest.json" ]] || \
  fail "prerelease-only latest.json was published at v1"

api_calls="$(wc -l < "${calls_file}" | tr -d ' ')"
if [[ "${api_calls}" != "2" ]]; then
  fail "expected two gh api calls for two upstream repos, got ${api_calls}"
fi

echo "OK - test-build-versions.sh passed"
