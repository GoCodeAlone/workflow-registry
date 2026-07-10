#!/usr/bin/env bash
# scripts/build-versions.sh
#
# For each plugin with a GitHub repository field, queries GitHub Releases API
# and builds v1/plugins/<name>/versions.json and v1/plugins/<name>/latest.json.
#
# Requires: gh CLI (authenticated), jq
#
# Notes:
#   - GitHub's REST releases list includes release assets, so each page is
#     fetched once and cached for all registry plugins that share an upstream.
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

validate_releases_file() {
  local gh_repo="$1" releases_file="$2"

  if ! jq -e '
    def valid_timestamp:
      type == "string" and
      ((try fromdateiso8601 catch null) != null);

    type == "array" and
    all(.[];
      type == "object" and
      has("tag_name") and (.tag_name | type == "string" and test("\\S")) and
      has("draft") and (.draft | type == "boolean") and
      has("prerelease") and (.prerelease | type == "boolean") and
      has("published_at") and
      (if .draft
       then (.published_at == null or (.published_at | valid_timestamp))
       else (.published_at | valid_timestamp)
       end)
    )
  ' "${releases_file}" >/dev/null; then
    echo "error: invalid release metadata for ${gh_repo}" >&2
    return 1
  fi
}

fetch_releases_file() {
  local gh_repo="$1" repo_cache_dir="$2" releases_cache="$3"
  local page=1 page_count
  local releases_error page_file aggregate_file next_file

  aggregate_file="${repo_cache_dir}/releases.aggregate.json"
  printf '[]\n' > "${aggregate_file}"

  while true; do
    page_file="${repo_cache_dir}/releases.page-${page}.json"
    releases_error="${repo_cache_dir}/releases.page-${page}.err"
    if ! run_gh api \
      "repos/${gh_repo}/releases?per_page=100&page=${page}" \
      >"${page_file}" 2>"${releases_error}"; then
      echo "error: failed to list releases for ${gh_repo} page ${page}: $(cat "${releases_error}")" >&2
      rm -f "${page_file}" "${releases_error}" "${aggregate_file}"
      return 1
    fi
    rm -f "${releases_error}"

    validate_releases_file "${gh_repo} page ${page}" "${page_file}"
    page_count="$(jq 'length' "${page_file}")"
    next_file="${aggregate_file}.next"
    jq -s '.[0] + .[1]' "${aggregate_file}" "${page_file}" > "${next_file}"
    mv "${next_file}" "${aggregate_file}"

    if (( page_count < 100 )); then
      break
    fi
    page=$((page + 1))
  done

  mv "${aggregate_file}" "${releases_cache}"
}

publish_plugin_outputs() {
  local dest_dir="$1" versions_source="$2" latest_source="${3:-}"
  local versions_tmp latest_tmp

  mkdir -p "${dest_dir}"
  versions_tmp="${dest_dir}/.versions.json.$$"
  latest_tmp="${dest_dir}/.latest.json.$$"
  rm -f "${versions_tmp}" "${latest_tmp}"

  cp "${versions_source}" "${versions_tmp}"
  if [[ -n "${latest_source}" ]]; then
    if ! cp "${latest_source}" "${latest_tmp}"; then
      rm -f "${versions_tmp}" "${latest_tmp}"
      return 1
    fi
  fi

  mv "${versions_tmp}" "${dest_dir}/versions.json"
  if [[ -n "${latest_source}" ]]; then
    mv "${latest_tmp}" "${dest_dir}/latest.json"
  else
    rm -f "${dest_dir}/latest.json"
  fi
}

echo "Building version data..."

mkdir -p "${OUT_DIR}/plugins"

while IFS= read -r manifest; do
  plugin_name="$(basename "$(dirname "${manifest}")")"
  dest_dir="${OUT_DIR}/plugins/${plugin_name}"

  # Read fields from manifest
  repository="$(jq -r '.repository // empty' "${manifest}")"
  min_engine="$(jq -r '.minEngineVersion // ""' "${manifest}")"

  # Plugins without a GitHub repository get an empty versions array
  if [[ -z "${repository}" ]] || [[ "${repository}" != *"github.com"* ]]; then
    empty_versions_file="${release_cache_root}/empty-versions-${plugin_name}.json"
    jq -n --arg name "${plugin_name}" '{"name": $name, "versions": []}' \
      > "${empty_versions_file}"
    publish_plugin_outputs "${dest_dir}" "${empty_versions_file}"
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
    fetch_releases_file "${gh_repo}" "${repo_cache_dir}" "${releases_cache}"
  else
    echo "  ${plugin_name}: using cached releases for ${gh_repo}..."
  fi
  releases_list="$(cat "${releases_cache}")"

  if [[ "${releases_list}" == "[]" ]] || [[ "$(echo "${releases_list}" | jq 'length')" == "0" ]]; then
    echo "    no releases found"
    empty_versions_file="${release_cache_root}/empty-versions-${plugin_name}.json"
    jq -n --arg name "${plugin_name}" '{"name": $name, "versions": []}' \
      > "${empty_versions_file}"
    publish_plugin_outputs "${dest_dir}" "${empty_versions_file}"
    continue
  fi

  # For each release tag, fetch full asset list (includes digest/sha256)
  final_versions_file="${release_cache_root}/versions-$(echo "${plugin_name}" | sed 's/[^A-Za-z0-9._-]/_/g').json"
  printf '[]\n' > "${final_versions_file}"
  while IFS= read -r release_entry; do
    tag="$(echo "${release_entry}" | jq -r '.tag_name')"
    published_at="$(echo "${release_entry}" | jq -r '.published_at')"
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
  plugin_versions_file="${release_cache_root}/plugin-versions-${plugin_name}.json"
  jq -n \
    --arg name "${plugin_name}" \
    --slurpfile versions "${final_versions_file}" \
    '{"name": $name, "versions": $versions[0]}' \
    > "${plugin_versions_file}"

  version_count="$(jq 'length' "${final_versions_file}")"
  echo "    wrote ${version_count} version(s)"

  # Write latest.json from the first non-prerelease in GitHub release order.
  plugin_latest_file="${release_cache_root}/plugin-latest-${plugin_name}.json"
  jq 'map(select(.prerelease == false)) | first // null' \
    "${final_versions_file}" > "${plugin_latest_file}"
  if jq -e '. != null' "${plugin_latest_file}" >/dev/null; then
    publish_plugin_outputs "${dest_dir}" "${plugin_versions_file}" "${plugin_latest_file}"
    echo "    latest: $(jq -r '.version' "${plugin_latest_file}")"
  else
    publish_plugin_outputs "${dest_dir}" "${plugin_versions_file}"
    echo "    no stable release found"
  fi

done < <(find "${PLUGINS_DIR}" -name "manifest.json" | sort)

echo "Done. Version data written to v1/plugins/*/versions.json"
