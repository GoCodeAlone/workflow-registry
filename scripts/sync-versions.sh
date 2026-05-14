#!/usr/bin/env bash
# sync-versions.sh — checks that each plugin manifest version and release
# download URLs match the latest GitHub release tag. With --fix, updates
# manifest versions and platform download URLs in-place.
#
# Usage:
#   scripts/sync-versions.sh [--fix] [--plugin <directory-name>]
#
# Requirements: gh (GitHub CLI), jq

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGINS_DIR="$REPO_ROOT/plugins"
FIX=false
PLUGIN_FILTER=""

while [[ $# -gt 0 ]]; do
  arg="$1"
  case "$arg" in
    --fix) FIX=true ;;
    --plugin)
      shift
      PLUGIN_FILTER="${1:-}"
      if [[ -z "$PLUGIN_FILTER" ]]; then
        echo "--plugin requires a directory name" >&2
        exit 1
      fi
      ;;
    *) echo "Unknown argument: $arg" >&2; exit 1 ;;
  esac
  shift
done

normalize_repo() {
  local repo_url="$1"
  repo_url="${repo_url#https://github.com/}"
  repo_url="${repo_url#http://github.com/}"
  repo_url="${repo_url#github.com/}"
  repo_url="${repo_url%.git}"
  repo_url="${repo_url%/}"
  echo "$repo_url" | cut -d/ -f1,2
}

downloads_match_version() {
  local manifest="$1"
  local version="$2"
  jq -e --arg tag "v${version}" '
    (.downloads // []) as $downloads |
    all($downloads[]?;
      (.url | test("/releases/download/" + $tag + "/"))
    )
  ' "$manifest" >/dev/null
}

release_downloads() {
  local gh_repo="$1"
  local tag="$2"
  gh release view "$tag" \
    --repo "$gh_repo" \
    --json assets \
    --jq '
      [
        .assets[] |
        select(.name | test("(linux|darwin|windows)-(amd64|arm64)[.]tar[.]gz$")) |
        . as $asset |
        ($asset.name | capture("(?<os>linux|darwin|windows)-(?<arch>amd64|arm64)[.]tar[.]gz$")) as $parts |
        {
          os: $parts.os,
          arch: $parts.arch,
          url: $asset.url,
          sha256: ($asset.digest | if . then ltrimstr("sha256:") else "" end)
        }
      ] | sort_by(.os, .arch)
    '
}

version_gt() {
  local left="$1"
  local right="$2"
  [[ "$(printf '%s\n%s\n' "$right" "$left" | sort -V | tail -n 1)" == "$left" && "$left" != "$right" ]]
}

release_exists() {
  local gh_repo="$1"
  local tag="$2"
  gh release view "$tag" --repo "$gh_repo" --json tagName >/dev/null 2>&1
}

mismatches=0

for manifest in "$PLUGINS_DIR"/*/manifest.json; do
  plugin_name="$(basename "$(dirname "$manifest")")"
  if [[ -n "$PLUGIN_FILTER" && "$plugin_name" != "$PLUGIN_FILTER" ]]; then
    continue
  fi

  # Extract repository/source field (may be absent)
  repo_url="$(jq -r '.repository // .source // empty' "$manifest")"
  if [[ -z "$repo_url" ]]; then
    continue
  fi

  # Derive owner/repo from GitHub URL (e.g. https://github.com/org/repo)
  gh_repo="$(normalize_repo "$repo_url")"
  if [[ -z "$gh_repo" ]] || [[ "$gh_repo" != */* ]]; then
    continue
  fi

  manifest_version="$(jq -r '.version' "$manifest")"

  # Query latest release tag; skip plugins with no releases
  latest_tag="$(gh release view --repo "$gh_repo" --json tagName -q '.tagName' 2>/dev/null || true)"
  if [[ -z "$latest_tag" ]]; then
    echo "  SKIP  $plugin_name — no release found for $gh_repo"
    continue
  fi

  # Strip leading 'v' prefix
  latest_version="${latest_tag#v}"

  downloads_ok=true
  if ! downloads_match_version "$manifest" "$manifest_version"; then
    downloads_ok=false
  fi

  target_version="$manifest_version"
  target_tag="v${manifest_version}"
  bump_version=false
  current_release_exists=true
  if ! release_exists "$gh_repo" "$target_tag"; then
    current_release_exists=false
  fi
  if version_gt "$latest_version" "$manifest_version" || ! $current_release_exists; then
    latest_downloads="$(release_downloads "$gh_repo" "$latest_tag")"
    if [[ "$(echo "$latest_downloads" | jq 'length')" != "0" ]]; then
      target_version="$latest_version"
      target_tag="$latest_tag"
      bump_version=true
    elif ! $current_release_exists; then
      echo "  SKIP  $plugin_name — manifest version $manifest_version has no release and latest $latest_version has no platform release assets"
    else
      echo "  SKIP  $plugin_name — latest $latest_version has no platform release assets"
    fi
  fi

  if [[ "$manifest_version" == "$target_version" ]] && $downloads_ok; then
    echo "    OK  $plugin_name $manifest_version"
  else
    if $bump_version; then
      echo " MISMATCH  $plugin_name: manifest=$manifest_version latest=$latest_version ($gh_repo)"
    fi
    if ! $downloads_ok; then
      echo " MISMATCH  $plugin_name: download URLs do not match manifest version $manifest_version"
    fi
    mismatches=$((mismatches + 1))
    if $FIX; then
      downloads="[]"
      if release_exists "$gh_repo" "$target_tag"; then
        downloads="$(release_downloads "$gh_repo" "$target_tag")"
      fi
      tmp="$(mktemp)"
      if [[ "$(echo "$downloads" | jq 'length')" == "0" ]]; then
        jq --arg v "$target_version" '.version = $v' "$manifest" > "$tmp"
      else
        jq --arg v "$target_version" --argjson downloads "$downloads" '
          .version = $v |
          .downloads = $downloads
        ' "$manifest" > "$tmp"
      fi
      mv "$tmp" "$manifest"
      echo "   FIXED  $plugin_name → $target_version downloads=$(echo "$downloads" | jq 'length')"
    fi
  fi
done

if [[ $mismatches -gt 0 ]]; then
  if $FIX; then
    echo ""
    echo "Fixed $mismatches version mismatch(es)."
  else
    echo ""
    echo "Found $mismatches version mismatch(es). Re-run with --fix to update."
    exit 1
  fi
else
  echo ""
  echo "All manifest versions are in sync."
fi
