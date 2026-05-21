#!/usr/bin/env bash
# tests/test-build-index.sh
#
# Primary projection contract for scripts/build-index.sh. Asserts which
# fields the v1/index.json allowlist surfaces and which it filters out.
# Exits non-zero on any assertion failure.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT_REAL="$(cd "${SCRIPT_DIR}/.." && pwd)"
FIXTURE_DIR="${SCRIPT_DIR}/fixtures"

if ! command -v jq &>/dev/null; then
  echo "error: jq required" >&2
  exit 1
fi

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

# Stage fixtures under a fake REPO_ROOT.
mkdir -p "${tmp}/plugins"
cp -R "${FIXTURE_DIR}/plugins/." "${tmp}/plugins/"

# Run the real build script against the fixture root.
REPO_ROOT="${tmp}" bash "${REPO_ROOT_REAL}/scripts/build-index.sh" >/dev/null

INDEX="${tmp}/v1/index.json"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_jq() {
  local desc="$1" expr="$2" expected="$3"
  local actual
  actual="$(jq -c "${expr}" "${INDEX}")"
  if [[ "${actual}" != "${expected}" ]]; then
    fail "${desc}: expected ${expected}, got ${actual}"
  fi
}

# === Structural assertions ===
assert_jq "index has 3 entries (private filtered)" 'length' '3'
assert_jq "names sorted ascending" 'map(.name)' '["bar-simple","foo-iac","qux-no-secrets"]'

# === Dir-name override ===
assert_jq "foo-iac name comes from dir not manifest" \
  '.[] | select(.name == "foo-iac") | .name' '"foo-iac"'

# === Must-be-present (allowlisted new fields) ===
assert_jq "foo-iac status" '.[] | select(.name=="foo-iac") | .status' '"verified"'
assert_jq "foo-iac homepage" '.[] | select(.name=="foo-iac") | .homepage' '"https://example.com/foo"'
assert_jq "foo-iac source" '.[] | select(.name=="foo-iac") | .source' '"github.com/example/foo"'
assert_jq "foo-iac assets" '.[] | select(.name=="foo-iac") | .assets' '{"ui":false,"config":true}'
assert_jq "foo-iac dependencies len" '.[] | select(.name=="foo-iac") | .dependencies | length' '1'
assert_jq "foo-iac capabilities.iacProvider.name" \
  '.[] | select(.name=="foo-iac") | .capabilities.iacProvider.name' '"foo"'
assert_jq "foo-iac capabilities.iacProvider.resourceTypes" \
  '.[] | select(.name=="foo-iac") | .capabilities.iacProvider.resourceTypes' \
  '["infra.dns","infra.dns_delegation"]'
assert_jq "foo-iac capabilities.iacProvider.supportedCanonicalKeys" \
  '.[] | select(.name=="foo-iac") | .capabilities.iacProvider.supportedCanonicalKeys' \
  '["zone","record"]'
assert_jq "foo-iac capabilities.cliCommands[0].name" \
  '.[] | select(.name=="foo-iac") | .capabilities.cliCommands[0].name' '"foo"'
assert_jq "foo-iac capabilities.cliCommands[0].flags_passthrough" \
  '.[] | select(.name=="foo-iac") | .capabilities.cliCommands[0].flags_passthrough' 'true'
assert_jq "foo-iac capabilities.cliCommands[0].subcommands[0].name" \
  '.[] | select(.name=="foo-iac") | .capabilities.cliCommands[0].subcommands[0].name' '"sync"'
assert_jq "foo-iac capabilities.migrationDrivers" \
  '.[] | select(.name=="foo-iac") | .capabilities.migrationDrivers' '["foo-migrate"]'
assert_jq "foo-iac iacProvider.computePlanVersion" \
  '.[] | select(.name=="foo-iac") | .iacProvider.computePlanVersion' '"v2"'
assert_jq "foo-iac required_secrets has 2 items" \
  '.[] | select(.name=="foo-iac") | .required_secrets | length' '2'

# === Empty-array preservation ===
assert_jq "bar-simple required_secrets preserved as []" \
  '.[] | select(.name=="bar-simple") | .required_secrets' '[]'
assert_jq "bar-simple status" \
  '.[] | select(.name=="bar-simple") | .status' '"experimental"'

# === Absent-key omission (C-1 regression coverage) ===
assert_jq "qux-no-secrets is present in index" \
  'map(.name) | contains(["qux-no-secrets"])' 'true'
if jq -e '.[] | select(.name=="qux-no-secrets") | has("required_secrets")' "${INDEX}" >/dev/null; then
  fail "qux-no-secrets should have no required_secrets key (manifest omits it); C-1 regression"
fi

# === required_secrets per-item allowlist (extras dropped) ===
assert_jq "required_secrets[0] item has exactly 4 known keys" \
  '.[] | select(.name=="foo-iac") | .required_secrets[0] | keys_unsorted | sort' \
  '["description","name","prompt","sensitive"]'

# === Per-item allowlist on cliCommands (extras dropped) ===
assert_jq "cliCommands item has exactly 4 known keys" \
  '.[] | select(.name=="foo-iac") | .capabilities.cliCommands[0] | keys_unsorted | sort' \
  '["description","flags_passthrough","name","subcommands"]'

# === Per-key allowlist on assets (round-2 Copilot — extras dropped) ===
assert_jq "assets has exactly 2 known keys (ui, config)" \
  '.[] | select(.name=="foo-iac") | .assets | keys_unsorted | sort' \
  '["config","ui"]'
if jq -e '.[] | select(.name=="foo-iac") | .assets | has("assets_leak")' "${INDEX}" >/dev/null; then
  fail "G3 allowlist regression: assets leaked sub-field 'assets_leak'"
fi

# === Per-item allowlist on dependencies (round-2 Copilot — extras dropped) ===
assert_jq "dependencies[0] item has exactly 3 known keys" \
  '.[] | select(.name=="foo-iac") | .dependencies[0] | keys_unsorted | sort' \
  '["maxVersion","minVersion","name"]'
if jq -e '.[] | select(.name=="foo-iac") | .dependencies[0] | has("dep_leak")' "${INDEX}" >/dev/null; then
  fail "G3 allowlist regression: dependencies item leaked sub-field 'dep_leak'"
fi

# === Per-item allowlist on cliCommands[].subcommands (round-2 Copilot — extras dropped) ===
assert_jq "cliCommands[0].subcommands[0] has exactly 2 known keys" \
  '.[] | select(.name=="foo-iac") | .capabilities.cliCommands[0].subcommands[0] | keys_unsorted | sort' \
  '["description","name"]'
if jq -e '.[] | select(.name=="foo-iac") | .capabilities.cliCommands[0].subcommands[0] | has("subcommand_leak")' "${INDEX}" >/dev/null; then
  fail "G3 allowlist regression: subcommand item leaked sub-field 'subcommand_leak'"
fi
if jq -e '.[] | select(.name=="foo-iac") | .capabilities.cliCommands[0] | has("cli_extra_leak")' "${INDEX}" >/dev/null; then
  fail "G3 allowlist regression: cliCommand item leaked sub-field 'cli_extra_leak'"
fi

# === Security: excluded fields MUST NOT appear ===
for excluded_field in downloads checksums contracts extra_undocumented_field path serviceMethods portIntrospect configProvider; do
  if jq -e ".[] | select(.name==\"foo-iac\") | has(\"${excluded_field}\")" "${INDEX}" >/dev/null; then
    fail "G3 allowlist regression: index leaked excluded field '${excluded_field}'; remove from build-index.sh projection or extend allowlist explicitly"
  fi
done

# === capabilities.buildHooks must not appear ===
if jq -e '.[] | select(.name=="foo-iac") | .capabilities | has("buildHooks")' "${INDEX}" >/dev/null; then
  fail "G3 allowlist regression: capabilities.buildHooks leaked into index"
fi

# === Private plugin handling: ABSENT from index, PRESENT as per-plugin copy ===
if jq -e '.[] | select(.name=="baz-private")' "${INDEX}" >/dev/null; then
  fail "private plugin baz-private leaked into public index"
fi
test -f "${tmp}/v1/plugins/baz-private/manifest.json" || \
  fail "private plugin baz-private per-plugin manifest copy missing"
test -f "${tmp}/v1/plugins/foo-iac/manifest.json" || fail "foo-iac per-plugin manifest copy missing"
test -f "${tmp}/v1/plugins/bar-simple/manifest.json" || fail "bar-simple per-plugin manifest copy missing"
test -f "${tmp}/v1/plugins/qux-no-secrets/manifest.json" || fail "qux-no-secrets per-plugin manifest copy missing"

# === Byte-identity for per-plugin manifest copies (per design spec line 249) ===
# Future refactor that swaps raw `cp` for a jq-projected write would break
# wfctl plugin install (which depends on full-fidelity per-plugin manifests).
for f in foo-iac bar-simple baz-private qux-no-secrets; do
  cmp --silent "${FIXTURE_DIR}/plugins/$f/manifest.json" "${tmp}/v1/plugins/$f/manifest.json" \
    || fail "per-plugin manifest copy for $f is not byte-identical to source"
done

echo "OK — test-build-index.sh passed"
