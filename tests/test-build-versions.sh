#!/usr/bin/env bash
# tests/test-build-versions.sh
#
# Regression coverage for scripts/build-versions.sh. The version builder should
# fetch paginated GitHub release metadata and cache it per upstream repo while
# preserving the public versions.json/latest.json contract.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT_REAL="$(cd "${SCRIPT_DIR}/.." && pwd)"

if ! command -v jq &>/dev/null; then
  echo "error: jq required" >&2
  exit 1
fi

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
real_cp="$(command -v cp)"

mkdir -p "${tmp}/scripts" \
  "${tmp}/plugins/plugin-alpha" \
  "${tmp}/plugins/plugin-beta" \
  "${tmp}/plugins/plugin-local" \
  "${tmp}/plugins/plugin-no-releases" \
  "${tmp}/plugins/plugin-prerelease-only" \
  "${tmp}/v1/plugins/plugin-alpha" \
  "${tmp}/v1/plugins/plugin-no-releases" \
  "${tmp}/v1/plugins/plugin-prerelease-only" \
  "${tmp}/public/plugins/plugin-no-releases" \
  "${tmp}/public/plugins/plugin-prerelease-only" \
  "${tmp}/public/v1/plugins/plugin-no-releases" \
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

cat > "${tmp}/plugins/plugin-no-releases/manifest.json" <<'JSON'
{
  "name": "plugin-no-releases",
  "repository": "https://github.com/example/no-releases"
}
JSON

cat > "${tmp}/v1/plugins/plugin-no-releases/latest.json" <<'JSON'
{
  "version": "0.8.0"
}
JSON
cp "${tmp}/v1/plugins/plugin-no-releases/latest.json" \
  "${tmp}/public/plugins/plugin-no-releases/latest.json"
cp "${tmp}/v1/plugins/plugin-no-releases/latest.json" \
  "${tmp}/public/v1/plugins/plugin-no-releases/latest.json"

cat > "${tmp}/v1/plugins/plugin-alpha/versions.json" <<'JSON'
{
  "name": "plugin-alpha",
  "versions": [{"version": "0.35.0", "prerelease": false}]
}
JSON
cat > "${tmp}/v1/plugins/plugin-alpha/latest.json" <<'JSON'
{
  "version": "0.35.0",
  "prerelease": false
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
mode="${GH_FIXTURE_MODE:-success}"

emit_shared_page_one() {
  jq -n '
    [
      {
        tag_name: "v1.0.0-rc.1",
        published_at: "2026-07-10T12:00:00Z",
        draft: false,
        prerelease: true,
        assets: []
      },
      {
        tag_name: "v1.1.0",
        published_at: null,
        draft: true,
        prerelease: false,
        assets: []
      }
    ] + [
      range(2; 100) as $release |
      {
        tag_name: ("v9.0.0-draft." + ($release | tostring)),
        published_at: null,
        draft: true,
        prerelease: true,
        assets: []
      }
    ]
  '
}

emit_shared_page_two() {
  cat <<'JSON' | jq '. + [range(1; 100) as $release | {
    tag_name: ("v8.0.0-draft." + ($release | tostring)),
    published_at: null,
    draft: true,
    prerelease: true,
    assets: []
  }]'
[
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
        "name": "workflow-plugin-shared-linux-arm64.tar.gz",
        "browser_download_url": "   ",
        "url": "https://api.github.com/repos/example/shared-plugin/releases/assets/4",
        "digest": null
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
}

if [[ "${endpoint}" == "repos/example/shared-plugin/releases?per_page=100" ||
      "${endpoint}" == "repos/example/shared-plugin/releases?per_page=100&page=1" ]]; then
  case "${mode}" in
    api-failure)
      echo "fixture API failure" >&2
      exit 44
      ;;
    malformed-json)
      printf '{not-json\n'
      exit 0
      ;;
    missing-draft)
      printf '[{"tag_name":"v0.36.1","published_at":"2026-07-08T12:00:00Z","prerelease":false,"assets":[]}]\n'
      exit 0
      ;;
    invalid-draft-type)
      printf '[{"tag_name":"v0.36.1","published_at":"2026-07-08T12:00:00Z","draft":"false","prerelease":false,"assets":[]}]\n'
      exit 0
      ;;
    missing-prerelease)
      printf '[{"tag_name":"v0.36.1","published_at":"2026-07-08T12:00:00Z","draft":false,"assets":[]}]\n'
      exit 0
      ;;
    invalid-prerelease-type)
      printf '[{"tag_name":"v0.36.1","published_at":"2026-07-08T12:00:00Z","draft":false,"prerelease":"false","assets":[]}]\n'
      exit 0
      ;;
    empty-tag)
      printf '[{"tag_name":"","published_at":"2026-07-08T12:00:00Z","draft":false,"prerelease":false,"assets":[]}]\n'
      exit 0
      ;;
    missing-published)
      printf '[{"tag_name":"v0.36.1","published_at":null,"draft":false,"prerelease":false,"assets":[]}]\n'
      exit 0
      ;;
    invalid-published)
      printf '[{"tag_name":"v0.36.1","published_at":"not-a-timestamp","draft":false,"prerelease":false,"assets":[]}]\n'
      exit 0
      ;;
    invalid-assets-type)
      printf '[{"tag_name":"v0.36.1","published_at":"2026-07-08T12:00:00Z","draft":false,"prerelease":false,"assets":{}}]\n'
      exit 0
      ;;
    invalid-calendar-timestamp)
      printf '[{"tag_name":"v0.36.1","published_at":"2026-02-30T12:00:00Z","draft":false,"prerelease":false,"assets":[]}]\n'
      exit 0
      ;;
    invalid-asset-name-type)
      printf '[{"tag_name":"v0.36.1","published_at":"2026-07-08T12:00:00Z","draft":false,"prerelease":false,"assets":[{"name":42,"browser_download_url":"https://downloads.example/shared/v0.36.1/linux-amd64.tar.gz","url":null,"digest":null}]}]\n'
      exit 0
      ;;
    invalid-asset-browser-url-type)
      printf '[{"tag_name":"v0.36.1","published_at":"2026-07-08T12:00:00Z","draft":false,"prerelease":false,"assets":[{"name":"workflow-plugin-shared-linux-amd64.tar.gz","browser_download_url":{},"url":"https://api.github.com/assets/1","digest":null}]}]\n'
      exit 0
      ;;
    invalid-asset-api-url-type)
      printf '[{"tag_name":"v0.36.1","published_at":"2026-07-08T12:00:00Z","draft":false,"prerelease":false,"assets":[{"name":"workflow-plugin-shared-linux-amd64.tar.gz","browser_download_url":null,"url":[],"digest":null}]}]\n'
      exit 0
      ;;
    invalid-asset-digest-type)
      printf '[{"tag_name":"v0.36.1","published_at":"2026-07-08T12:00:00Z","draft":false,"prerelease":false,"assets":[{"name":"workflow-plugin-shared-linux-amd64.tar.gz","browser_download_url":"https://downloads.example/shared/v0.36.1/linux-amd64.tar.gz","url":null,"digest":{}}]}]\n'
      exit 0
      ;;
    invalid-asset-digest-content)
      printf '[{"tag_name":"v0.36.1","published_at":"2026-07-08T12:00:00Z","draft":false,"prerelease":false,"assets":[{"name":"workflow-plugin-shared-linux-amd64.tar.gz","browser_download_url":"https://downloads.example/shared/v0.36.1/linux-amd64.tar.gz","url":null,"digest":"sha256:not-a-sha256"}]}]\n'
      exit 0
      ;;
    missing-asset-effective-url)
      printf '[{"tag_name":"v0.36.1","published_at":"2026-07-08T12:00:00Z","draft":false,"prerelease":false,"assets":[{"name":"workflow-plugin-shared-linux-amd64.tar.gz","browser_download_url":"","url":null,"digest":null}]}]\n'
      exit 0
      ;;
  esac
fi

case "${endpoint}" in
  repos/example/shared-plugin/releases\?per_page=100|repos/example/shared-plugin/releases\?per_page=100\&page=1)
    printf '%s\n' "${endpoint}" >> "${GH_CALLS_FILE}"
    emit_shared_page_one
    ;;
  repos/example/shared-plugin/releases\?per_page=100\&page=2)
    printf '%s\n' "${endpoint}" >> "${GH_CALLS_FILE}"
    if [[ "${mode}" == "page-2-api-failure" ]]; then
      echo "fixture page 2 API failure" >&2
      exit 45
    fi
    if [[ "${mode}" == "page-2-schema-failure" ]]; then
      printf '{"not":"an array"}\n'
      exit 0
    fi
    emit_shared_page_two
    ;;
  repos/example/shared-plugin/releases\?per_page=100\&page=3)
    echo "unexpected page 3 request" >&2
    exit 43
    ;;
  repos/example/no-releases/releases\?per_page=100|repos/example/no-releases/releases\?per_page=100\&page=1)
    printf '%s\n' "${endpoint}" >> "${GH_CALLS_FILE}"
    printf '[]\n'
    ;;
  repos/example/prerelease-only/releases\?per_page=100|repos/example/prerelease-only/releases\?per_page=100\&page=1)
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

fail() { echo "FAIL: $*" >&2; exit 1; }
alpha_versions="${tmp}/v1/plugins/plugin-alpha/versions.json"
alpha_latest="${tmp}/v1/plugins/plugin-alpha/latest.json"
expected_alpha_versions="${tmp}/expected-alpha-versions.json"
expected_alpha_latest="${tmp}/expected-alpha-latest.json"
cp "${alpha_versions}" "${expected_alpha_versions}"
cp "${alpha_latest}" "${expected_alpha_latest}"

failure_marker="${tmp}/first-versions-copy-failure"
cat > "${tmp}/bin/cp" <<SH
#!/usr/bin/env bash
set -euo pipefail

destination="\$2"
if [[ -e "${failure_marker}" &&
      "\${destination}" == *.versions.json.* ]]; then
  printf 'partial output\n' > "\${destination}"
  exit 77
fi

exec "\${REAL_CP}" "\$@"
SH
chmod +x "${tmp}/bin/cp"

assert_failed_build_preserves_alpha() {
  local mode="$1" description="$2"
  local output="${tmp}/build-${mode}.log"

  if GH_FIXTURE_MODE="${mode}" GH_CALLS_FILE="${calls_file}" REAL_CP="${real_cp}" PATH="${tmp}/bin:${PATH}" \
    bash "${tmp}/scripts/build-versions.sh" >"${output}" 2>&1; then
    fail "${description} unexpectedly succeeded"
  fi

  cmp --silent "${expected_alpha_versions}" "${alpha_versions}" || \
    fail "${description} replaced existing versions.json"
  cmp --silent "${expected_alpha_latest}" "${alpha_latest}" || \
    fail "${description} replaced or removed existing latest.json"
}

assert_failed_build_preserves_alpha "api-failure" "API fetch failure"
assert_failed_build_preserves_alpha "malformed-json" "malformed API JSON"
assert_failed_build_preserves_alpha "missing-draft" "release missing draft"
assert_failed_build_preserves_alpha "invalid-draft-type" "release with non-boolean draft"
assert_failed_build_preserves_alpha "missing-prerelease" "release missing prerelease"
assert_failed_build_preserves_alpha "invalid-prerelease-type" "release with non-boolean prerelease"
assert_failed_build_preserves_alpha "empty-tag" "release with empty tag"
assert_failed_build_preserves_alpha "missing-published" "non-draft release missing published timestamp"
assert_failed_build_preserves_alpha "invalid-published" "release with invalid published timestamp"
assert_failed_build_preserves_alpha "invalid-assets-type" "release with non-array assets"
assert_failed_build_preserves_alpha "invalid-calendar-timestamp" "release with nonexistent calendar timestamp"
assert_failed_build_preserves_alpha "invalid-asset-name-type" "asset with non-string name"
assert_failed_build_preserves_alpha "invalid-asset-browser-url-type" "asset with non-string browser URL"
assert_failed_build_preserves_alpha "invalid-asset-api-url-type" "asset with non-string API URL"
assert_failed_build_preserves_alpha "invalid-asset-digest-type" "asset with non-string digest"
assert_failed_build_preserves_alpha "invalid-asset-digest-content" "asset with invalid digest content"
assert_failed_build_preserves_alpha "missing-asset-effective-url" "asset without effective URL"
assert_failed_build_preserves_alpha "page-2-api-failure" "page 2 API failure"
assert_failed_build_preserves_alpha "page-2-schema-failure" "page 2 schema failure"

touch "${failure_marker}"
if GH_CALLS_FILE="${calls_file}" REAL_CP="${real_cp}" \
  PATH="${tmp}/bin:${PATH}" bash "${tmp}/scripts/build-versions.sh" \
  >"${tmp}/build-first-versions-copy-failure.log" 2>&1; then
  fail "first versions copy failure unexpectedly succeeded"
fi
rm -f "${failure_marker}"
cmp --silent "${expected_alpha_versions}" "${alpha_versions}" || \
  fail "first versions copy failure replaced existing versions.json"
cmp --silent "${expected_alpha_latest}" "${alpha_latest}" || \
  fail "first versions copy failure replaced or removed existing latest.json"
shopt -s nullglob
leftover_output_temps=(
  "${tmp}/v1/plugins/plugin-alpha"/.versions.json.*
  "${tmp}/v1/plugins/plugin-alpha"/.latest.json.*
)
shopt -u nullglob
if ((${#leftover_output_temps[@]} != 0)); then
  fail "first versions copy failure left output temp files: ${leftover_output_temps[*]}"
fi

: > "${calls_file}"
GH_CALLS_FILE="${calls_file}" REAL_CP="${real_cp}" PATH="${tmp}/bin:${PATH}" \
  bash "${tmp}/scripts/build-versions.sh" >/dev/null
REAL_CP="${real_cp}" PATH="${tmp}/bin:${PATH}" \
  bash "${tmp}/scripts/prepare-pages-artifact.sh" >/dev/null

assert_jq_file() {
  local desc="$1" file="$2" expr="$3" expected="$4"
  local actual
  actual="$(jq -c "${expr}" "${file}")"
  if [[ "${actual}" != "${expected}" ]]; then
    fail "${desc}: expected ${expected}, got ${actual}"
  fi
}

beta_latest="${tmp}/v1/plugins/plugin-beta/latest.json"
local_versions="${tmp}/v1/plugins/plugin-local/versions.json"
no_releases_versions="${tmp}/v1/plugins/plugin-no-releases/versions.json"
no_releases_latest="${tmp}/v1/plugins/plugin-no-releases/latest.json"
prerelease_versions="${tmp}/v1/plugins/plugin-prerelease-only/versions.json"
prerelease_latest="${tmp}/v1/plugins/plugin-prerelease-only/latest.json"
root_alpha_latest="${tmp}/public/plugins/plugin-alpha/latest.json"
v1_alpha_latest="${tmp}/public/v1/plugins/plugin-alpha/latest.json"
root_alpha_versions="${tmp}/public/plugins/plugin-alpha/versions.json"
v1_alpha_versions="${tmp}/public/v1/plugins/plugin-alpha/versions.json"

test -f "${alpha_versions}" || fail "plugin-alpha versions.json missing"
test -f "${alpha_latest}" || fail "stable release on page 2 was not published as latest"
test -f "${beta_latest}" || fail "plugin-beta latest.json missing"
test -f "${local_versions}" || fail "plugin-local versions.json missing"
test -f "${no_releases_versions}" || fail "plugin-no-releases versions.json missing"
test -f "${prerelease_versions}" || fail "plugin-prerelease-only versions.json missing"
test -f "${root_alpha_latest}" || fail "public root plugin-alpha latest.json missing"
test -f "${v1_alpha_latest}" || fail "public v1 plugin-alpha latest.json missing"
test -f "${root_alpha_versions}" || fail "public root plugin-alpha versions.json missing"
test -f "${v1_alpha_versions}" || fail "public v1 plugin-alpha versions.json missing"

assert_jq_file "alpha latest stays on stable release" "${alpha_latest}" '.version' '"0.36.1"'
assert_jq_file "alpha versions has two non-draft releases" "${alpha_versions}" '.versions | length' '2'
assert_jq_file "alpha versions preserve API order" "${alpha_versions}" \
  '[.versions[].version]' '["1.0.0-rc.1","0.36.1"]'
assert_jq_file "alpha RC retained as prerelease" "${alpha_versions}" \
  '.versions[] | select(.version=="1.0.0-rc.1") | .prerelease' 'true'
assert_jq_file "alpha stable release marked non-prerelease" "${alpha_versions}" \
  '.versions[] | select(.version=="0.36.1") | .prerelease' 'false'
assert_jq_file "alpha draft excluded" "${alpha_versions}" \
  '[.versions[] | select(.version=="1.1.0")] | length' '0'
assert_jq_file "manifest-backed canonical plugin index stays stable" "${tmp}/v1/index.json" \
  '.[] | select(.name=="plugin-alpha") | .version' '"0.36.1"'
assert_jq_file "manifest-backed public root plugin index stays stable" "${tmp}/public/index.json" \
  '.[] | select(.name=="plugin-alpha") | .version' '"0.36.1"'
assert_jq_file "manifest-backed public v1 plugin index stays stable" "${tmp}/public/v1/index.json" \
  '.[] | select(.name=="plugin-alpha") | .version' '"0.36.1"'
assert_jq_file "public root latest stays stable" "${root_alpha_latest}" \
  '.version' '"0.36.1"'
assert_jq_file "public v1 latest stays stable" "${v1_alpha_latest}" \
  '.version' '"0.36.1"'
assert_jq_file "public root versions retains RC metadata" "${root_alpha_versions}" \
  '.versions[] | select(.version=="1.0.0-rc.1") | .prerelease' 'true'
assert_jq_file "public v1 versions retains RC metadata" "${v1_alpha_versions}" \
  '.versions[] | select(.version=="1.0.0-rc.1") | .prerelease' 'true'
assert_jq_file "public root versions excludes drafts" "${root_alpha_versions}" \
  '[.versions[] | select(.version=="1.1.0")] | length' '0'
assert_jq_file "public v1 versions excludes drafts" "${v1_alpha_versions}" \
  '[.versions[] | select(.version=="1.1.0")] | length' '0'
assert_jq_file "alpha min engine propagated" "${alpha_latest}" '.minEngineVersion' '"0.75.0"'
assert_jq_file "matching assets only" "${alpha_latest}" '.downloads | length' '4'
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
assert_jq_file "API asset URL is accepted" "${alpha_latest}" \
  '.downloads[] | select(.os=="linux" and .arch=="arm64") | .url' \
  '"https://api.github.com/repos/example/shared-plugin/releases/assets/4"'
assert_jq_file "null asset digest emits empty sha256" "${alpha_latest}" \
  '.downloads[] | select(.os=="linux" and .arch=="arm64") | .sha256' '""'
assert_jq_file "beta reuses same release data with its own min engine" "${beta_latest}" \
  '.minEngineVersion' '"0.76.0"'
assert_jq_file "non-GitHub plugin writes empty versions" "${local_versions}" \
  '.versions' '[]'
assert_jq_file "no-release repo writes empty versions" "${no_releases_versions}" \
  '.versions' '[]'
assert_jq_file "prerelease-only repo retains RC history" "${prerelease_versions}" \
  '.versions[] | select(.version=="2.0.0-rc.1") | .prerelease' 'true'
assert_jq_file "prerelease-only repo excludes draft" "${prerelease_versions}" \
  '[.versions[] | select(.version=="1.0.0")] | length' '0'

[[ ! -e "${prerelease_latest}" ]] || fail "prerelease-only latest.json was not removed"
[[ ! -e "${no_releases_latest}" ]] || fail "no-release latest.json was not removed"
[[ ! -e "${tmp}/public/plugins/plugin-no-releases/latest.json" ]] || \
  fail "no-release latest.json was published at root"
[[ ! -e "${tmp}/public/v1/plugins/plugin-no-releases/latest.json" ]] || \
  fail "no-release latest.json was published at v1"
[[ ! -e "${tmp}/public/plugins/plugin-prerelease-only/latest.json" ]] || \
  fail "prerelease-only latest.json was published at root"
[[ ! -e "${tmp}/public/v1/plugins/plugin-prerelease-only/latest.json" ]] || \
  fail "prerelease-only latest.json was published at v1"

api_calls="$(wc -l < "${calls_file}" | tr -d ' ')"
if [[ "${api_calls}" != "4" ]]; then
  fail "expected four paginated gh api calls for three upstream repos, got ${api_calls}"
fi

echo "OK - test-build-versions.sh passed"
