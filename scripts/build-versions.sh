#!/usr/bin/env bash
# scripts/build-versions.sh
#
# For each plugin with a GitHub repository field, queries GitHub Releases API
# and builds v1/plugins/<name>/versions.json and v1/plugins/<name>/latest.json.
#
# Requires: gh CLI (authenticated), jq

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

  # Extract owner/repo from URL (https://github.com/owner/repo or github.com/owner/repo)
  gh_repo="$(echo "${repository}" | sed 's|https://github.com/||; s|http://github.com/||; s|github.com/||')"

  echo "  ${plugin_name}: fetching releases for ${gh_repo}..."

  # Query GitHub Releases API
  releases_json="$(gh release list \
    --repo "${gh_repo}" \
    --limit 100 \
    --json tagName,publishedAt,assets \
    2>/dev/null || echo "[]")"

  if [[ "${releases_json}" == "[]" ]]; then
    echo "    no releases found"
    jq -n --arg name "${plugin_name}" '{"name": $name, "versions": []}' \
      > "${dest_dir}/versions.json"
    continue
  fi

  # Build versions array from releases, newest-first (gh release list already returns newest-first)
  versions="$(echo "${releases_json}" | jq --arg minEng "${min_engine}" '
    [
      .[] |
      . as $release |
      ($release.tagName | ltrimstr("v")) as $ver |
      {
        version: $ver,
        released: $release.publishedAt,
        minEngineVersion: (if $minEng != "" then $minEng else null end),
        downloads: (
          # Find checksums.txt asset content URL if available
          ($release.assets | map(select(.name == "checksums.txt")) | first | .url // "") as $checksums_url |
          [
            $release.assets[] |
            select(.name | test("(linux|darwin|windows)-(amd64|arm64)\\.tar\\.gz$")) |
            . as $asset |
            ($asset.name | capture("(?P<os>linux|darwin|windows)-(?P<arch>amd64|arm64)\\.tar\\.gz$")) as $parts |
            {
              os:     $parts.os,
              arch:   $parts.arch,
              url:    $asset.url,
              sha256: ""
            }
          ]
        )
      }
    ]
  ')"

  # Resolve checksums for each version by fetching checksums.txt
  versions_with_checksums="$(echo "${releases_json}" | jq --arg minEng "${min_engine}" '
    [
      .[] |
      ($release = .) |
      ($release.tagName | ltrimstr("v")) as $ver |
      ($release.assets | map(select(.name == "checksums.txt")) | first) as $checksum_asset |
      {
        version: $ver,
        released: $release.publishedAt,
        minEngineVersion: (if $minEng != "" then $minEng else null end),
        checksum_url: ($checksum_asset.url // ""),
        downloads: [
          $release.assets[] |
          select(.name | test("(linux|darwin|windows)-(amd64|arm64)\\.tar\\.gz$")) |
          . as $asset |
          ($asset.name | capture("(?P<os>linux|darwin|windows)-(?P<arch>amd64|arm64)\\.tar\\.gz$")) as $parts |
          {
            os:        $parts.os,
            arch:      $parts.arch,
            url:       $asset.url,
            asset_name: $asset.name,
            sha256:    ""
          }
        ]
      }
    ]
  ')"

  # Fetch checksums and populate sha256 fields
  final_versions="[]"
  while IFS= read -r version_entry; do
    checksum_url="$(echo "${version_entry}" | jq -r '.checksum_url // ""')"
    ver="$(echo "${version_entry}" | jq -r '.version')"

    if [[ -n "${checksum_url}" ]]; then
      # Download checksums.txt via gh api
      checksums_txt="$(gh api "${checksum_url}" 2>/dev/null || echo "")"
      # gh api on a release asset URL redirects; try direct download approach
      if [[ -z "${checksums_txt}" ]]; then
        checksums_txt="$(curl -sf -L "${checksum_url}" 2>/dev/null || echo "")"
      fi
    else
      checksums_txt=""
    fi

    # Update sha256 for each download by matching asset name in checksums.txt
    updated_entry="$(echo "${version_entry}" | jq \
      --arg checksums "${checksums_txt}" '
      del(.checksum_url) |
      .downloads = [
        .downloads[] |
        . as $dl |
        ($checksums | split("\n")[] | select(contains($dl.asset_name)) | split("  ")[0] // "") as $sha |
        del(.asset_name) |
        .sha256 = $sha
      ]
    ')"

    final_versions="$(echo "${final_versions}" | jq --argjson v "${updated_entry}" '. + [$v]')"
  done < <(echo "${versions_with_checksums}" | jq -c '.[]')

  # Write versions.json (newest-first order preserved from gh release list)
  jq -n \
    --arg name "${plugin_name}" \
    --argjson versions "${final_versions}" \
    '{"name": $name, "versions": $versions}' \
    > "${dest_dir}/versions.json"

  # Write latest.json (first/newest version entry)
  latest="$(echo "${final_versions}" | jq 'first // null')"
  if [[ "${latest}" != "null" ]]; then
    echo "${latest}" > "${dest_dir}/latest.json"
    echo "    wrote ${final_versions_count:-$(echo "${final_versions}" | jq 'length')} versions, latest: $(echo "${latest}" | jq -r '.version')"
  else
    echo "    no versions parsed"
  fi

done < <(find "${PLUGINS_DIR}" -name "manifest.json" | sort)

echo "Done. Version data written to v1/plugins/*/versions.json"
