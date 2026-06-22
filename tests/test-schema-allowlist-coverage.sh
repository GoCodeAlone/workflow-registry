#!/usr/bin/env bash
# tests/test-schema-allowlist-coverage.sh
#
# Bidirectional drift guard between schema/registry-schema.json and the
# G3-include/G3-exclude markers in scripts/build-index.sh.
#
# Forward (schema → markers): every schema property in the in-scope set
#   must have a decision marker. Catches: someone added a field to the
#   schema, forgot to triage it for the public index.
# Reverse (markers → schema): every marker must correspond to a real
#   schema property. Catches: phantom markers for fields that don't exist.
#
# In-scope properties:
#   - Top-level properties of the schema
#   - capabilities.* direct children
#   - capabilities.iacProvider.* (name, resourceTypes, supportedCanonicalKeys)
#   - capabilities.cliCommands.items.* (name, description, flagsPassthrough, subcommands)
#   - capabilities.cliCommands.subcommands.items.* (name, description) — added round 2 per Copilot
#   - iacProvider.* (top-level — name, resourceTypes, computePlanVersion)
#   - assets.* (ui, config) — added round 2 per Copilot
#   - dependencies.items.* (name, minVersion, maxVersion) — added round 2 per Copilot
#   - secret_targets.items.* (provider, scopes, description)
#   - required_config.items.* (name, key, sensitive, description, prompt)
#   - config_targets.items.* (provider, scopes, description)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SCHEMA="${REPO_ROOT}/schema/registry-schema.json"
BUILD_SCRIPT="${REPO_ROOT}/scripts/build-index.sh"

if ! command -v jq &>/dev/null; then
  echo "error: jq required" >&2
  exit 1
fi

# Per round-2 M-NEW-2: explicit input-file existence guard. Without this,
# a missing or moved schema file silently produces empty schema_props
# output and the script exits 0 (false-pass).
if [[ ! -f "${SCHEMA}" ]]; then
  echo "error: schema file not found at ${SCHEMA}" >&2
  exit 1
fi
if [[ ! -f "${BUILD_SCRIPT}" ]]; then
  echo "error: build script not found at ${BUILD_SCRIPT}" >&2
  exit 1
fi

# Extract schema property paths in dot-qualified form. Each nested path
# uses `// {}` so a future schema refactor (e.g. switching iacProvider to
# a $ref) returns an empty container instead of jq's "null has no keys"
# error — which is then caught by the line-count guard below.
schema_props() {
  jq -r '
    [
      ((.properties // {}) | keys[]),
      ((.properties.capabilities.properties // {}) | keys[] | "capabilities." + .),
      ((.properties.capabilities.properties.iacProvider.properties // {}) | keys[] | "capabilities.iacProvider." + .),
      ((.properties.capabilities.properties.cliCommands.items.properties // {}) | keys[] | "capabilities.cliCommands." + .),
      ((.properties.capabilities.properties.cliCommands.items.properties.subcommands.items.properties // {}) | keys[] | "capabilities.cliCommands.subcommands." + .),
      ((.properties.iacProvider.properties // {}) | keys[] | "iacProvider." + .),
      ((.properties.assets.properties // {}) | keys[] | "assets." + .),
      ((.properties.dependencies.items.properties // {}) | keys[] | "dependencies." + .),
      ((.properties.secret_targets.items.properties // {}) | keys[] | "secret_targets." + .),
      ((.properties.required_config.items.properties // {}) | keys[] | "required_config." + .),
      ((.properties.config_targets.items.properties // {}) | keys[] | "config_targets." + .)
    ] | .[]
  ' "${SCHEMA}" | sort -u
}

# Extract marker decisions from build script.
marker_decisions() {
  grep -E '^[[:space:]]*#[[:space:]]*G3-(include|exclude):' "${BUILD_SCRIPT}" \
    | sed -E 's/^[[:space:]]*#[[:space:]]*G3-(include|exclude):[[:space:]]*([^[:space:]]+).*/\2/' \
    | sort -u
}

schema_set="$(mktemp)"
marker_set="$(mktemp)"
trap 'rm -f "${schema_set}" "${marker_set}"' EXIT

schema_props > "${schema_set}"
marker_decisions > "${marker_set}"

# Per round-2 I-NEW-1: explicit empty-output guard. `func > file` does
# NOT reliably propagate the function's non-zero exit through `set -e`
# (empirically verified). Without this guard, a jq parse error or
# null-key crash produces an empty schema_set and the forward-trace loop
# silently iterates zero times, returning OK — defeating the drift
# guard's purpose on the day it would matter most.
if [[ ! -s "${schema_set}" ]]; then
  echo "FAIL: schema_props() produced no output — schema structure may have changed (path traversal hit a null), or jq failed silently" >&2
  exit 1
fi
if [[ ! -s "${marker_set}" ]]; then
  echo "FAIL: no G3-include/G3-exclude markers found in ${BUILD_SCRIPT}; was Task 6 applied?" >&2
  exit 1
fi

fail=0

# Forward trace: schema → markers.
while IFS= read -r prop; do
  if ! grep -Fxq "${prop}" "${marker_set}"; then
    echo "FAIL: schema field '${prop}' has no allow/exclude decision in build-index.sh; add '# G3-include: ${prop}' or '# G3-exclude: ${prop} — <reason>'" >&2
    fail=1
  fi
done < "${schema_set}"

# Reverse trace: markers → schema.
while IFS= read -r marker; do
  if ! grep -Fxq "${marker}" "${schema_set}"; then
    echo "FAIL: build-index.sh marker '${marker}' does not correspond to a schema property — remove it (or fix typo)" >&2
    fail=1
  fi
done < "${marker_set}"

if [[ "${fail}" -ne 0 ]]; then
  exit 1
fi

echo "OK — test-schema-allowlist-coverage.sh passed ($(wc -l < "${schema_set}" | tr -d ' ') schema props ↔ $(wc -l < "${marker_set}" | tr -d ' ') markers)"
