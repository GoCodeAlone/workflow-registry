#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/registry-filter.XXXXXX")"
trap 'rm -rf "${tmp}"' EXIT

mkdir -p "${tmp}/plugins/auth" \
  "${tmp}/plugins/workflow-plugin-auth" \
  "${tmp}/plugins/admin" \
  "${tmp}/plugins/workflow-plugin-signal"

cat > "${tmp}/plugins/auth/manifest.json" <<'JSON'
{"name":"auth","repository":"https://github.com/GoCodeAlone/workflow"}
JSON
cat > "${tmp}/plugins/workflow-plugin-auth/manifest.json" <<'JSON'
{"name":"workflow-plugin-auth","repository":"https://github.com/GoCodeAlone/workflow-plugin-auth"}
JSON
cat > "${tmp}/plugins/admin/manifest.json" <<'JSON'
{"name":"admin","repository":"https://github.com/GoCodeAlone/workflow-plugin-admin"}
JSON
cat > "${tmp}/plugins/workflow-plugin-signal/manifest.json" <<'JSON'
{"name":"workflow-plugin-signal","repository":"https://github.com/GoCodeAlone/workflow-plugin-signal"}
JSON

run_case() {
  local event="$1"
  local action="$2"
  local dispatch_plugin="$3"
  local input_plugin="$4"
  PLUGINS_DIR="${tmp}/plugins" \
  EVENT_NAME="${event}" \
  DISPATCH_ACTION="${action}" \
  PLUGIN_FROM_DISPATCH="${dispatch_plugin}" \
  PLUGIN_FROM_INPUT="${input_plugin}" \
    bash "${repo_root}/scripts/resolve-sync-plugin-filter.sh"
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  if [[ "${haystack}" != *"${needle}"* ]]; then
    echo "expected output to contain ${needle}, got:" >&2
    echo "${haystack}" >&2
    exit 1
  fi
}

out="$(run_case repository_dispatch plugin-release auth "")"
assert_contains "${out}" "plugin=workflow-plugin-auth"
assert_contains "${out}" "skip=0"

out="$(run_case repository_dispatch plugin-release admin "")"
assert_contains "${out}" "plugin=admin"
assert_contains "${out}" "skip=0"

out="$(run_case repository_dispatch plugin-release workflow-plugin-auth "")"
assert_contains "${out}" "plugin=workflow-plugin-auth"
assert_contains "${out}" "skip=0"

out="$(run_case repository_dispatch plugin-release GoCodeAlone/workflow-plugin-signal "")"
assert_contains "${out}" "plugin=workflow-plugin-signal"
assert_contains "${out}" "skip=0"

out="$(run_case workflow_dispatch "" "" auth)"
assert_contains "${out}" "plugin=workflow-plugin-auth"
assert_contains "${out}" "skip=0"

out="$(run_case repository_dispatch plugin-release missing "")"
assert_contains "${out}" "plugin="
assert_contains "${out}" "skip=1"

out="$(run_case repository_dispatch plugin-release "../auth" "")"
assert_contains "${out}" "plugin="
assert_contains "${out}" "skip=1"

echo "resolve-sync-plugin-filter tests passed"
