#!/usr/bin/env bash
# scripts/build-versions.sh
#
# For each plugin with a GitHub repository field, queries GitHub Releases API
# and builds v1/plugins/<name>/versions.json and v1/plugins/<name>/latest.json.
#
# Requires: gh CLI (authenticated), jq
#
# Notes:
#   - GitHub's REST releases list includes release assets, so each upstream repo
#     is fetched once and reused for all registry plugins that share it.
#   - Asset digests (sha256) are read directly from the `digest` field returned
#     by the API, so checksums.txt does not need to be downloaded.
#   - The canonical plugin name used in versions.json is the directory name
#     (same convention as build-index.sh), not the manifest's "name" field.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
PLUGINS_DIR="${REPO_ROOT}/plugins"
OUT_DIR="${REPO_ROOT}/v1"

if ! command -v jq &>/dev/null; then
  echo "error: jq is required but not found in PATH" >&2
  exit 1
fi

if ! command -v gh &>/dev/null; then
  echo "error: gh CLI is required but not found in PATH" >&2
  exit 1
fi

GH_TIMEOUT_SECONDS="${GH_TIMEOUT_SECONDS:-45}"
release_cache_root="$(mktemp -d "${TMPDIR:-/tmp}/workflow-registry-releases.XXXXXX")"
trap 'rm -rf "${release_cache_root}"' EXIT

run_gh() {
  if command -v timeout &>/dev/null; then
    timeout "${GH_TIMEOUT_SECONDS}s" gh "$@"
  else
    gh "$@"
  fi
}

echo "Building version data..."

mkdir -p "${OUT_DIR}/plugins"

while IFS= read -r manifest; do
  plugin_name="$(basename "$(dirname "${manifest}")")"
  dest_dir="${OUT_DIR}/plugins/${plugin_name}"
  mkdir -p "${dest_dir}"
  rm -f "${dest_dir}/latest.json"

  # Read fields from manifest
  repository="$(jq -r '.repository // empty' "${manifest}")"
  min_engine="$(jq -r '.minEngineVersion // ""' "${manifest}")"

  # Plugins without a GitHub repository get an empty versions array
  if [[ -z "${repository}" ]] || [[ "${repository}" != *"github.com"* ]]; then
    jq -n --arg name "${plugin_name}" '{"name": $name, "versions": []}' \
      > "${dest_dir}/versions.json"
    echo "  ${plugin_name}: no GitHub repository, wrote empty versions"
    continue
  fi

  # Extract owner/repo from URL, normalizing trailing slashes, .git suffix, and extra path segments
  gh_repo="$(echo "${repository}" | sed 's|https://github.com/||; s|http://github.com/||; s|github.com/||; s|\.git$||; s|/$||' | cut -d/ -f1,2)"
  repo_cache_dir="${release_cache_root}/$(echo "${gh_repo}" | tr '/:' '__')"
  mkdir -p "${repo_cache_dir}"

  # List releases and their assets in one REST call per upstream repo.
  releases_cache="${repo_cache_dir}/releases.json"
  if [[ ! -f "${releases_cache}" ]]; then
    echo "  ${plugin_name}: fetching releases for ${gh_repo}..."
    releases_error="${repo_cache_dir}/releases.err"
    if ! releases_list="$(run_gh api \
      "repos/${gh_repo}/releases?per_page=100" \
      2>"${releases_error}")"; then
      echo "    WARNING: failed to list releases for ${gh_repo}: $(cat "${releases_error}")" >&2
      releases_list="[]"
    fi
    rm -f "${releases_error}"
    printf '%s\n' "${releases_list}" > "${releases_cache}"
  else
    echo "  ${plugin_name}: using cached releases for ${gh_repo}..."
  fi
  releases_list="$(cat "${releases_cache}")"

  if [[ "${releases_list}" == "[]" ]] || [[ "$(echo "${releases_list}" | jq 'length')" == "0" ]]; then
    echo "    no releases found"
    jq -n --arg name "${plugin_name}" '{"name": $name, "versions": []}' \
      > "${dest_dir}/versions.json"
    continue
  fi

  # For each release tag, fetch full asset list (includes digest/sha256)
  final_versions_file="${release_cache_root}/versions-$(echo "${plugin_name}" | sed 's/[^A-Za-z0-9._-]/_/g').json"
  printf '[]\n' > "${final_versions_file}"
  while IFS= read -r release_entry; do
    tag="$(echo "${release_entry}" | jq -r '.tag_name // .tagName')"
    published_at="$(echo "${release_entry}" | jq -r '.published_at // .publishedAt')"
    ver="$(echo "${tag}" | sed 's/^v//')"

    version_entry_file="${release_cache_root}/version-entry-$(echo "${plugin_name}-${tag}" | sed 's/[^A-Za-z0-9._-]/_/g').json"
    echo "${release_entry}" | jq \
      --arg ver "${ver}" \
      --arg published_at "${published_at}" \
      --arg minEng "${min_engine}" '
      {
        version: $ver,
        released: $published_at,
        prerelease: ((.prerelease // false) == true),
        minEngineVersion: (if $minEng != "" then $minEng else null end),
        downloads: [
          (.assets // [])[] |
          select(.name | test("(linux|darwin|windows)[-_](amd64|arm64)[.]tar[.]gz$")) |
          . as $asset |
          ($asset.name | capture("(?<os>linux|darwin|windows)[-_](?<arch>amd64|arm64)[.]tar[.]gz$")) as $parts |
          {
            os:     $parts.os,
            arch:   $parts.arch,
            url:    ($asset.browser_download_url // $asset.url // ""),
            sha256: (($asset.digest // "") | ltrimstr("sha256:"))
          }
        ]
      }
    ' > "${version_entry_file}"

    next_versions_file="${final_versions_file}.next"
    jq --slurpfile v "${version_entry_file}" '. + [$v[0]]' \
      "${final_versions_file}" > "${next_versions_file}"
    mv "${next_versions_file}" "${final_versions_file}"
  done < <(echo "${releases_list}" | jq -c '.[] | select((.draft // false) == false)')

  # Write versions.json (newest-first order preserved from gh release list)
  jq -n \
    --arg name "${plugin_name}" \
    --slurpfile versions "${final_versions_file}" \
    '{"name": $name, "versions": $versions[0]}' \
    > "${dest_dir}/versions.json"

  version_count="$(jq 'length' "${final_versions_file}")"
  echo "    wrote ${version_count} version(s)"

  # Write latest.json from the first non-prerelease in GitHub release order.
  latest="$(jq 'map(select(.prerelease == false)) | first // null' "${final_versions_file}")"
  if [[ "${latest}" != "null" ]]; then
    echo "${latest}" > "${dest_dir}/latest.json"
    echo "    latest: $(echo "${latest}" | jq -r '.version')"
  else
    echo "    no stable release found"
  fi

done < <(find "${PLUGINS_DIR}" -name "manifest.json" | sort)

echo "Done. Version data written to v1/plugins/*/versions.json"
