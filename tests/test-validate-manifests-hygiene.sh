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

# Exercise the explicit hygiene guards through the real validator. Bypass
# schema validation only for these cases so an independent schema rejection
# cannot hide a broken guard; these cases make no schema-acceptance claim.
run_guard_validator() {
  REGISTRY_ROOT="${tmp}" \
  REGISTRY_SCHEMA="${repo_root}/schema/registry-schema.json" \
  PLUGINS_DIR="${tmp}/plugins" \
  AJV=true \
    bash "${repo_root}/scripts/validate-manifests.sh"
}

for extra_fields in \
  '{"flags_passthrough":true,"later":{}}' \
  '{"flags_passthrough":false,"later":{}}' \
  '{"metadata":[{"flags_passthrough":true},{}]}' \
  '{"metadata":[{},{"flags_passthrough":false}]}'
do
  write_manifest "$(jq --argjson extra "${extra_fields}" '. + $extra' <<<"${valid_manifest}")"
  if run_guard_validator >"${tmp}/legacy-key.out" 2>&1; then
    echo "expected legacy flags_passthrough to be rejected regardless of object order or value" >&2
    exit 1
  fi
  grep -q "legacy flags_passthrough" "${tmp}/legacy-key.out"
done

write_manifest "$(jq '.capabilities.cliCommands = [{"name":"example","flagsPassthrough":true}]' <<<"${valid_manifest}")"
run_guard_validator >"${tmp}/camel-case.out" 2>&1

assert_release_tag_guard() {
  local version="$1" tag="$2" expected="$3"
  write_manifest "$(jq --arg version "${version}" --arg tag "${tag}" '
    .version = $version |
    .downloads = [{os:"linux", arch:"amd64",
      url:("https://github.com/GoCodeAlone/workflow-plugin-example/releases/download/v" + $tag + "/plugin.tar.gz")}]
  ' <<<"${valid_manifest}")"
  if run_guard_validator >"${tmp}/release-tag.out" 2>&1; then
    if [[ "${expected}" != accept ]]; then
      echo "expected version ${version} to reject release tag ${tag}" >&2
      exit 1
    fi
  else
    if [[ "${expected}" == accept ]]; then
      cat "${tmp}/release-tag.out" >&2
      exit 1
    fi
    grep -q "downloads\[\].url release tag must match manifest version" "${tmp}/release-tag.out"
  fi
}

assert_release_tag_guard '1.2.3' '1.2.3' accept
assert_release_tag_guard '1.2.3' '1x2x3' reject
assert_release_tag_guard '1.2.3-rc.1' '1.2.3-rc.1' accept
assert_release_tag_guard '1.2.3-rc.1' '1.2.3-rcx1' reject
assert_release_tag_guard '1.2.3+build.1' '1.2.3+build.1' accept
assert_release_tag_guard '1.2.3+build.1' '1.2.33buildX1' reject

echo "validate-manifests hygiene tests passed"
