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

  # Allowlisted summary projection — see docs/plans/2026-05-21-build-index-inline-manifest-design.md.
  # Every schema-allowed field below must appear here as G3-include OR G3-exclude.
  # tests/test-schema-allowlist-coverage.sh enforces this on every PR.
  # Marker format: dot-qualified, schema-relative (e.g. capabilities.iacProvider.name).
  #
  # G3-include: name
  # G3-include: version
  # G3-include: author
  # G3-include: description
  # G3-include: source
  # G3-include: type
  # G3-include: tier
  # G3-include: status
  # G3-include: category
  # G3-include: license
  # G3-include: minEngineVersion
  # G3-include: keywords
  # G3-include: homepage
  # G3-include: repository
  # G3-include: private
  # G3-include: assets
  # G3-include: assets.ui
  # G3-include: assets.config
  # G3-include: dependencies
  # G3-include: dependencies.name
  # G3-include: dependencies.minVersion
  # G3-include: dependencies.maxVersion
  # G3-include: required_secrets
  # G3-include: secret_targets
  # G3-include: secret_targets.provider
  # G3-include: secret_targets.scopes
  # G3-include: secret_targets.description
  # G3-include: capabilities
  # G3-include: capabilities.moduleTypes
  # G3-include: capabilities.stepTypes
  # G3-include: capabilities.triggerTypes
  # G3-include: capabilities.workflowHandlers
  # G3-include: capabilities.wiringHooks
  # G3-include: capabilities.migrationDrivers
  # G3-include: capabilities.configProvider
  # G3-include: capabilities.iacStateBackends
  # G3-include: capabilities.resourceTypes
  # G3-exclude: capabilities.serviceMethods — engine-internal gRPC method names, not user-facing search
  # G3-exclude: capabilities.iacProvider.configSchema — large free-form per-resource schema (DO's is ~10KB); per-plugin manifest carries it
  # G3-include: capabilities.iacProvider
  # G3-include: capabilities.iacProvider.name
  # G3-include: capabilities.iacProvider.resourceTypes
  # G3-include: capabilities.iacProvider.supportedCanonicalKeys
  # G3-include: capabilities.cliCommands
  # G3-include: capabilities.cliCommands.name
  # G3-include: capabilities.cliCommands.description
  # G3-include: capabilities.cliCommands.flags_passthrough
  # G3-include: capabilities.cliCommands.subcommands
  # G3-include: capabilities.cliCommands.subcommands.name
  # G3-include: capabilities.cliCommands.subcommands.description
  # G3-include: iacProvider
  # G3-include: iacProvider.name
  # G3-include: iacProvider.resourceTypes
  # G3-include: iacProvider.computePlanVersion
  #
  # G3-exclude: path — wfctl-internal subpackage path, not user-facing
  # G3-exclude: downloads — stale relative to build-versions.sh latest.json
  # G3-exclude: checksums — belongs in versions.json next to download list
  # G3-exclude: capabilities.buildHooks — wfctl-internal build-time hook list

  summary="$(jq --arg dir_name "${plugin_name}" '({
    name:             $dir_name,
    description:      (.description // ""),
    version:          (.version // ""),
    type:             (.type // ""),
    tier:             (.tier // ""),
    status:           (.status // null),
    category:         (.category // null),
    license:          (.license // ""),
    author:           (.author // ""),
    keywords:         (.keywords // []),
    private:          (.private // false),
    homepage:         (.homepage // null),
    source:           (.source // null),
    repository:       (.repository // null),
    minEngineVersion: (.minEngineVersion // null),
    assets: (
      if .assets == null then null
      else {
        ui:     (.assets.ui // false),
        config: (.assets.config // false)
      }
      end
    ),
    dependencies: (
      [(.dependencies // [])[] | {
        name:       (.name // null),
        minVersion: (.minVersion // null),
        maxVersion: (.maxVersion // null)
      }]
    ),
    capabilities: {
      configProvider:   (.capabilities.configProvider   // false),
      moduleTypes:      (.capabilities.moduleTypes      // []),
      stepTypes:        (.capabilities.stepTypes        // []),
      triggerTypes:     (.capabilities.triggerTypes     // []),
      workflowHandlers: (.capabilities.workflowHandlers // []),
      wiringHooks:      (.capabilities.wiringHooks      // []),
      migrationDrivers: (.capabilities.migrationDrivers // []),
      iacStateBackends: (.capabilities.iacStateBackends // []),
      resourceTypes:    (.capabilities.resourceTypes    // []),
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
          subcommands: (
            [(.subcommands // [])[] | {
              name:        (.name // null),
              description: (.description // null)
            }]
          )
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
  )
  +
  (
    if (.secret_targets // null) == null then {}
    else { secret_targets: [.secret_targets[] | {
      provider:    (.provider // null),
      scopes:      (.scopes // []),
      description: (.description // null)
    }]}
    end
  ))' "${manifest}")"
  summaries="$(echo "${summaries}" | jq --argjson s "${summary}" '. + [$s]')"
done < <(find "${PLUGINS_DIR}" -name "manifest.json" | sort)

# Sort summaries by name and write index
echo "${summaries}" | jq 'sort_by(.name)' > "${OUT_DIR}/index.json"

plugin_count="$(echo "${summaries}" | jq 'length')"
echo "Done. Generated v1/index.json with ${plugin_count} plugins."
