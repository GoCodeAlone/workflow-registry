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
  "${tmp}/bin"

cp "${REPO_ROOT_REAL}/scripts/build-versions.sh" "${tmp}/scripts/build-versions.sh"

cat > "${tmp}/plugins/plugin-alpha/manifest.json" <<'JSON'
{
  "name": "plugin-alpha",
  "repository": "https://github.com/example/shared-plugin",
  "minEngineVersion": "0.75.0"
}
JSON

cat > "${tmp}/plugins/plugin-beta/manifest.json" <<'JSON'
{
  "name": "plugin-beta",
  "repository": "https://github.com/example/shared-plugin.git",
  "minEngineVersion": "0.76.0"
}
JSON

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
    "tag_name": "v1.2.3",
    "published_at": "2026-06-01T12:00:00Z",
    "assets": [
      {
        "name": "workflow-plugin-shared-linux-amd64.tar.gz",
        "browser_download_url": "https://downloads.example/shared/v1.2.3/linux-amd64.tar.gz",
        "url": "https://api.github.com/repos/example/shared-plugin/releases/assets/1",
        "digest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      },
      {
        "name": "workflow-plugin-shared-darwin-arm64.tar.gz",
        "browser_download_url": "https://downloads.example/shared/v1.2.3/darwin-arm64.tar.gz",
        "url": "https://api.github.com/repos/example/shared-plugin/releases/assets/2",
        "digest": "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
      },
      {
        "name": "workflow-plugin-shared_1.2.3_windows_arm64.tar.gz",
        "browser_download_url": "https://downloads.example/shared/v1.2.3/windows-arm64.tar.gz",
        "url": "https://api.github.com/repos/example/shared-plugin/releases/assets/3",
        "digest": "sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
      },
      {
        "name": "checksums.txt",
        "browser_download_url": "https://downloads.example/shared/v1.2.3/checksums.txt",
        "digest": "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
      }
    ]
  },
  {
    "tag_name": "v1.2.2",
    "published_at": "2026-05-01T12:00:00Z",
    "assets": [
      {
        "name": "workflow-plugin-shared-windows-amd64.tar.gz",
        "browser_download_url": "https://downloads.example/shared/v1.2.2/windows-amd64.tar.gz",
        "digest": "sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
      }
    ]
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

GH_CALLS_FILE="${calls_file}" PATH="${tmp}/bin:${PATH}" \
  bash "${tmp}/scripts/build-versions.sh" >/dev/null

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

test -f "${alpha_versions}" || fail "plugin-alpha versions.json missing"
test -f "${alpha_latest}" || fail "plugin-alpha latest.json missing"
test -f "${beta_latest}" || fail "plugin-beta latest.json missing"
test -f "${local_versions}" || fail "plugin-local versions.json missing"

assert_jq_file "alpha versions has two releases" "${alpha_versions}" '.versions | length' '2'
assert_jq_file "alpha latest version" "${alpha_latest}" '.version' '"1.2.3"'
assert_jq_file "alpha min engine propagated" "${alpha_latest}" '.minEngineVersion' '"0.75.0"'
assert_jq_file "matching assets only" "${alpha_latest}" '.downloads | length' '3'
assert_jq_file "download URL uses browser_download_url" "${alpha_latest}" \
  '.downloads[] | select(.os=="linux" and .arch=="amd64") | .url' \
  '"https://downloads.example/shared/v1.2.3/linux-amd64.tar.gz"'
assert_jq_file "sha256 prefix stripped" "${alpha_latest}" \
  '.downloads[] | select(.os=="linux" and .arch=="amd64") | .sha256' \
  '"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"'
assert_jq_file "underscore asset names are parsed" "${alpha_latest}" \
  '.downloads[] | select(.os=="windows" and .arch=="arm64") | .url' \
  '"https://downloads.example/shared/v1.2.3/windows-arm64.tar.gz"'
assert_jq_file "underscore asset sha256 prefix stripped" "${alpha_latest}" \
  '.downloads[] | select(.os=="windows" and .arch=="arm64") | .sha256' \
  '"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"'
assert_jq_file "beta reuses same release data with its own min engine" "${beta_latest}" \
  '.minEngineVersion' '"0.76.0"'
assert_jq_file "non-GitHub plugin writes empty versions" "${local_versions}" \
  '.versions' '[]'

api_calls="$(wc -l < "${calls_file}" | tr -d ' ')"
if [[ "${api_calls}" != "1" ]]; then
  fail "expected one gh api call for shared upstream repo, got ${api_calls}"
fi

echo "OK - test-build-versions.sh passed"
