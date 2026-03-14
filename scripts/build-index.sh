#!/usr/bin/env bash
# scripts/build-index.sh
#
# Generates v1/index.json — an array of plugin summaries sorted by name.
# Also copies each manifest to v1/plugins/<name>/manifest.json.
#
# Requires: jq

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PLUGINS_DIR="${REPO_ROOT}/plugins"
OUT_DIR="${REPO_ROOT}/v1"

if ! command -v jq &>/dev/null; then
  echo "error: jq is required but not found in PATH" >&2
  exit 1
fi

echo "Building registry index..."

mkdir -p "${OUT_DIR}/plugins"

# Collect summaries from all plugin manifests, sorted by name
summaries="[]"

while IFS= read -r manifest; do
  plugin_name="$(basename "$(dirname "${manifest}")")"

  # Validate it's readable JSON
  if ! jq empty "${manifest}" 2>/dev/null; then
    echo "warning: skipping invalid JSON at ${manifest}" >&2
    continue
  fi

  # Extract summary fields.
  # Use the directory name as the canonical "name" so that it matches the
  # v1/plugins/<name>/ API path, even if the manifest's "name" field differs.
  summary="$(jq --arg dir_name "${plugin_name}" '{
    name:             $dir_name,
    description:      (.description // ""),
    version:          (.version // ""),
    type:             (.type // ""),
    tier:             (.tier // ""),
    license:          (.license // ""),
    author:           (.author // ""),
    keywords:         (.keywords // []),
    private:          (.private // false),
    repository:       (.repository // null),
    minEngineVersion: (.minEngineVersion // null),
    capabilities: {
      moduleTypes:      (.capabilities.moduleTypes      // []),
      stepTypes:        (.capabilities.stepTypes        // []),
      triggerTypes:     (.capabilities.triggerTypes     // []),
      workflowHandlers: (.capabilities.workflowHandlers // []),
      wiringHooks:      (.capabilities.wiringHooks      // [])
    }
  }' "${manifest}")"

  summaries="$(echo "${summaries}" | jq --argjson s "${summary}" '. + [$s]')"

  # Copy manifest to v1/plugins/<name>/manifest.json
  dest_dir="${OUT_DIR}/plugins/${plugin_name}"
  mkdir -p "${dest_dir}"
  cp "${manifest}" "${dest_dir}/manifest.json"
  echo "  copied plugins/${plugin_name}/manifest.json"
done < <(find "${PLUGINS_DIR}" -name "manifest.json" | sort)

# Sort summaries by name and write index
echo "${summaries}" | jq 'sort_by(.name)' > "${OUT_DIR}/index.json"

plugin_count="$(echo "${summaries}" | jq 'length')"
echo "Done. Generated v1/index.json with ${plugin_count} plugins."
