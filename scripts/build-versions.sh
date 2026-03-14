#!/usr/bin/env bash
# scripts/build-versions.sh
#
# For each plugin with a GitHub repository field, queries GitHub Releases API
# and builds v1/plugins/<name>/versions.json and v1/plugins/<name>/latest.json.
#
# Requires: gh CLI (authenticated), jq
#
# Notes:
#   - `gh release list` does NOT support --json assets; per-release assets are
#     fetched via `gh release view <tag> --json assets`.
#   - Asset digests (sha256) are read directly from the `digest` field returned
#     by `gh release view`, so checksums.txt does not need to be downloaded.
#   - The canonical plugin name used in versions.json is the directory name
#     (same convention as build-index.sh), not the manifest's "name" field.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
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

echo "Building version data..."

mkdir -p "${OUT_DIR}/plugins"

while IFS= read -r manifest; do
  plugin_name="$(basename "$(dirname "${manifest}")")"
  dest_dir="${OUT_DIR}/plugins/${plugin_name}"
  mkdir -p "${dest_dir}"

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

  echo "  ${plugin_name}: fetching releases for ${gh_repo}..."

  # List releases (tagName + publishedAt only; assets not available in list output)
  if ! releases_list="$(gh release list \
    --repo "${gh_repo}" \
    --limit 100 \
    --json tagName,publishedAt \
    2>&1)"; then
    echo "    WARNING: failed to list releases for ${gh_repo}: ${releases_list}" >&2
    releases_list="[]"
  fi

  if [[ "${releases_list}" == "[]" ]] || [[ "$(echo "${releases_list}" | jq 'length')" == "0" ]]; then
    echo "    no releases found"
    jq -n --arg name "${plugin_name}" '{"name": $name, "versions": []}' \
      > "${dest_dir}/versions.json"
    continue
  fi

  # For each release tag, fetch full asset list (includes digest/sha256)
  final_versions="[]"
  while IFS= read -r release_entry; do
    tag="$(echo "${release_entry}" | jq -r '.tagName')"
    published_at="$(echo "${release_entry}" | jq -r '.publishedAt')"
    ver="$(echo "${tag}" | sed 's/^v//')"

    # gh release view returns assets with a `digest` field (sha256:... format)
    if ! release_detail="$(gh release view "${tag}" \
      --repo "${gh_repo}" \
      --json assets \
      2>&1)"; then
      echo "    WARNING: failed to fetch assets for ${gh_repo}@${tag}: ${release_detail}" >&2
      release_detail='{"assets":[]}'
    fi

    version_entry="$(echo "${release_detail}" | jq \
      --arg ver "${ver}" \
      --arg published_at "${published_at}" \
      --arg minEng "${min_engine}" '
      {
        version: $ver,
        released: $published_at,
        minEngineVersion: (if $minEng != "" then $minEng else null end),
        downloads: [
          .assets[] |
          select(.name | test("(linux|darwin|windows)-(amd64|arm64)[.]tar[.]gz$")) |
          . as $asset |
          ($asset.name | capture("(?<os>linux|darwin|windows)-(?<arch>amd64|arm64)[.]tar[.]gz$")) as $parts |
          {
            os:     $parts.os,
            arch:   $parts.arch,
            url:    $asset.url,
            sha256: ($asset.digest | if . then ltrimstr("sha256:") else "" end)
          }
        ]
      }
    ')"

    final_versions="$(echo "${final_versions}" | jq --argjson v "${version_entry}" '. + [$v]')"
  done < <(echo "${releases_list}" | jq -c '.[]')

  # Write versions.json (newest-first order preserved from gh release list)
  jq -n \
    --arg name "${plugin_name}" \
    --argjson versions "${final_versions}" \
    '{"name": $name, "versions": $versions}' \
    > "${dest_dir}/versions.json"

  version_count="$(echo "${final_versions}" | jq 'length')"
  echo "    wrote ${version_count} version(s)"

  # Write latest.json (first/newest version entry)
  latest="$(echo "${final_versions}" | jq 'first // null')"
  if [[ "${latest}" != "null" ]]; then
    echo "${latest}" > "${dest_dir}/latest.json"
    echo "    latest: $(echo "${latest}" | jq -r '.version')"
  fi

done < <(find "${PLUGINS_DIR}" -name "manifest.json" | sort)

echo "Done. Version data written to v1/plugins/*/versions.json"
