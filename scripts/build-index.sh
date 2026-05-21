#!/usr/bin/env bash
# scripts/build-index.sh
#
# Generates v1/index.json — an array of plugin summaries sorted by name.
# Also copies each manifest to v1/plugins/<name>/manifest.json.
#
# Requires: jq

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
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

  # Validate readable JSON.
  if ! jq empty "${manifest}" 2>/dev/null; then
    echo "warning: skipping invalid JSON at ${manifest}" >&2
    continue
  fi

  # ALWAYS copy per-plugin manifest, including for private:true.
  # Authenticated wfctl consumers of /v1/plugins/<name>/manifest.json
  # depend on this endpoint working for private plugins too.
  dest_dir="${OUT_DIR}/plugins/${plugin_name}"
  mkdir -p "${dest_dir}"
  cp "${manifest}" "${dest_dir}/manifest.json"
  echo "  copied plugins/${plugin_name}/manifest.json"

  # Private plugins: do NOT append to the public bulk index.
  is_private="$(jq -r '.private // false' "${manifest}")"
  if [[ "${is_private}" == "true" ]]; then
    echo "  skipped (private) plugins/${plugin_name}/"
    continue
  fi

  # G3 markers go here — see Task 6.

  summary="$(jq --arg dir_name "${plugin_name}" '({
    name:             $dir_name,
    description:      (.description // ""),
    version:          (.version // ""),
    type:             (.type // ""),
    tier:             (.tier // ""),
    status:           (.status // null),
    license:          (.license // ""),
    author:           (.author // ""),
    keywords:         (.keywords // []),
    private:          (.private // false),
    homepage:         (.homepage // null),
    source:           (.source // null),
    repository:       (.repository // null),
    minEngineVersion: (.minEngineVersion // null),
    assets:           (.assets // null),
    dependencies:     (.dependencies // []),
    capabilities: {
      moduleTypes:      (.capabilities.moduleTypes      // []),
      stepTypes:        (.capabilities.stepTypes        // []),
      triggerTypes:     (.capabilities.triggerTypes     // []),
      workflowHandlers: (.capabilities.workflowHandlers // []),
      wiringHooks:      (.capabilities.wiringHooks      // []),
      migrationDrivers: (.capabilities.migrationDrivers // []),
      iacProvider: (
        if .capabilities.iacProvider == null then null
        else {
          name:                   (.capabilities.iacProvider.name // null),
          resourceTypes:          (.capabilities.iacProvider.resourceTypes // []),
          supportedCanonicalKeys: (.capabilities.iacProvider.supportedCanonicalKeys // [])
        }
        end
      ),
      cliCommands: (
        [(.capabilities.cliCommands // [])[] | {
          name:              (.name // null),
          description:       (.description // null),
          flags_passthrough: (.flags_passthrough // false),
          subcommands:       (.subcommands // [])
        }]
      )
    },
    iacProvider: (
      if .iacProvider == null then null
      else {
        name:               (.iacProvider.name // null),
        resourceTypes:      (.iacProvider.resourceTypes // []),
        computePlanVersion: (.iacProvider.computePlanVersion // null)
      }
      end
    )
  }
  +
  (
    if (.required_secrets // null) == null then {}
    else { required_secrets: [.required_secrets[] | {
      name:        (.name // null),
      sensitive:   (.sensitive // false),
      description: (.description // null),
      prompt:      (.prompt // null)
    }]}
    end
  ))' "${manifest}")"
  summaries="$(echo "${summaries}" | jq --argjson s "${summary}" '. + [$s]')"
done < <(find "${PLUGINS_DIR}" -name "manifest.json" | sort)

# Sort summaries by name and write index
echo "${summaries}" | jq 'sort_by(.name)' > "${OUT_DIR}/index.json"

plugin_count="$(echo "${summaries}" | jq 'length')"
echo "Done. Generated v1/index.json with ${plugin_count} plugins."
