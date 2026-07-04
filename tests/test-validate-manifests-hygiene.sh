#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/registry-manifest-hygiene.XXXXXX")"
trap 'rm -rf "${tmp}"' EXIT

mkdir -p "${tmp}/plugins/example"

write_manifest() {
  local body="$1"
  rm -rf "${tmp}/plugins"
  mkdir -p "${tmp}/plugins/example"
  printf '%s\n' "${body}" > "${tmp}/plugins/example/manifest.json"
}

run_validator() {
  REGISTRY_ROOT="${tmp}" \
  REGISTRY_SCHEMA="${repo_root}/schema/registry-schema.json" \
  PLUGINS_DIR="${tmp}/plugins" \
    bash "${repo_root}/scripts/validate-manifests.sh"
}

valid_manifest='{
  "name": "example",
  "version": "1.0.0",
  "author": "GoCodeAlone",
  "description": "Example plugin manifest",
  "type": "external",
  "tier": "community",
  "license": "MIT",
  "repository": "https://github.com/GoCodeAlone/workflow-plugin-example",
  "source": "github.com/GoCodeAlone/workflow-plugin-example",
  "capabilities": {
    "moduleTypes": ["example.module"],
    "stepTypes": ["step.example"]
  }
}'

write_manifest "${valid_manifest}"
run_validator >/dev/null

write_manifest '{
  "name": "scaffold-workflow-plugin",
  "version": "1.0.0",
  "author": "GoCodeAlone",
  "description": "Template repository",
  "type": "external",
  "tier": "community",
  "license": "MIT",
  "repository": "https://github.com/GoCodeAlone/scaffold-workflow-plugin",
  "source": "github.com/GoCodeAlone/scaffold-workflow-plugin"
}'
if run_validator >"${tmp}/scaffold.out" 2>&1; then
  echo "expected scaffold placeholder manifest to fail validation" >&2
  exit 1
fi
grep -q "scaffold/template repositories must not be published" "${tmp}/scaffold.out"

write_manifest '{
  "name": "example",
  "version": "1.0.0",
  "author": "GoCodeAlone",
  "description": "Example plugin manifest",
  "type": "external",
  "tier": "community",
  "license": "MIT",
  "capabilities": {
    "cliCommands": [
      {"name": "example", "flags_passthrough": true}
    ]
  }
}'
if run_validator >"${tmp}/flags.out" 2>&1; then
  echo "expected legacy flags_passthrough manifest to fail validation" >&2
  exit 1
fi
grep -q "legacy flags_passthrough" "${tmp}/flags.out"

write_manifest '{
  "name": "example",
  "version": "1.0.0",
  "author": "GoCodeAlone",
  "description": "Example plugin manifest",
  "type": "external",
  "tier": "community",
  "license": "MIT",
  "capabilities": {
    "moduleTypes": ["TEMPLATE.module"]
  }
}'
if run_validator >"${tmp}/template.out" 2>&1; then
  echo "expected placeholder capability manifest to fail validation" >&2
  exit 1
fi
grep -q "placeholder capability names" "${tmp}/template.out"

echo "validate-manifests hygiene tests passed"
