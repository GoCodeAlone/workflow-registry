#!/usr/bin/env bash
# Gate the three catalogs whose releases contain multiple archive roles.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/registry-artifact-roles.XXXXXX")"
trap 'rm -rf "${tmp}"' EXIT
failures=0

fail() {
  echo "FAIL: $*" >&2
  failures=$((failures + 1))
}

# Test real catalog inputs, including the first-match behavior used by wfctl.
for spec in \
  'github workflow-plugin-github 6' \
  'workflow-plugin-migrations workflow-plugin-migrations 6' \
  'workflow-plugin-atlas-migrate workflow-plugin-atlas-migrate 4'; do
  read -r catalog artifact count <<< "${spec}"
  manifest="${repo_root}/plugins/${catalog}/manifest.json"
  selected="$(jq -r 'first(.downloads[] | select(.os == "linux" and .arch == "amd64")) | .url' "${manifest}")"
  if [[ "${selected##*/}" != "${artifact}-linux-amd64.tar.gz" ]]; then
    fail "${catalog} first Linux/amd64 download selects ${selected##*/}, expected full ${artifact} archive"
  fi
  if ! jq -e --arg artifact "${artifact}" --argjson count "${count}" '
    (.downloads | length == $count)
    and all(.downloads[]; . as $download |
      $download.url | endswith("/" + $artifact + "-" + $download.os + "-" + $download.arch + ".tar.gz"))
  ' "${manifest}" >/dev/null; then
    fail "${catalog} catalog contains a wrong archive role or platform count"
  fi
done

atlas="${repo_root}/plugins/workflow-plugin-atlas-migrate/manifest.json"
if ! jq -e '
  .capabilities.migrationDrivers == ["atlas"]
  and .capabilities.stepTypes == []
  and .capabilities.cliCommands == []
' "${atlas}" >/dev/null; then
  fail "Atlas catalog must declare Atlas with no main-plugin steps or CLI"
fi

# Valid fixtures use the published full archive roles and Atlas plugin.atlas.json
# contract. Mutations below exercise the actual production validator.
mkdir -p "${tmp}/good"
for spec in \
  'github workflow-plugin-github' \
  'workflow-plugin-migrations workflow-plugin-migrations' \
  'workflow-plugin-atlas-migrate workflow-plugin-atlas-migrate'; do
  read -r catalog artifact <<< "${spec}"
  mkdir -p "${tmp}/good/${catalog}"
  jq --arg artifact "${artifact}" '
    .downloads |= map(select(.url | contains("/" + $artifact + "-")))
  ' "${repo_root}/plugins/${catalog}/manifest.json" > "${tmp}/good/${catalog}/manifest.json"
done
jq '.capabilities = {
  configProvider: false,
  moduleTypes: ["database.migrations", "database.migration_driver"],
  stepTypes: [], triggerTypes: [], migrationDrivers: ["atlas"],
  cliCommands: [], buildHooks: []
}' "${tmp}/good/workflow-plugin-atlas-migrate/manifest.json" > "${tmp}/atlas.json"
mv "${tmp}/atlas.json" "${tmp}/good/workflow-plugin-atlas-migrate/manifest.json"

reset_fixtures() {
  rm -rf "${tmp}/plugins"
  cp -R "${tmp}/good" "${tmp}/plugins"
}

mutate() {
  local catalog="$1" expression="$2"
  jq "${expression}" "${tmp}/plugins/${catalog}/manifest.json" > "${tmp}/mutated.json"
  mv "${tmp}/mutated.json" "${tmp}/plugins/${catalog}/manifest.json"
}

run_validator() {
  REGISTRY_ROOT="${repo_root}" \
  REGISTRY_SCHEMA="${repo_root}/schema/registry-schema.json" \
  PLUGINS_DIR="${tmp}/plugins" \
    bash "${repo_root}/scripts/validate-manifests.sh"
}

expect_rejection() {
  local label="$1" message="$2"
  if run_validator > "${tmp}/validator.out" 2>&1; then
    fail "validator accepted ${label}"
  elif ! grep -q "${message}" "${tmp}/validator.out"; then
    fail "${label} rejected for an unexpected reason"
    cat "${tmp}/validator.out" >&2
  else
    echo "PASS: rejects ${label}"
  fi
}

reset_fixtures
if ! run_validator > "${tmp}/validator.out" 2>&1; then
  fail "validator rejected valid published archive-role fixtures"
  cat "${tmp}/validator.out" >&2
fi
mutate workflow-plugin-atlas-migrate '.capabilities.moduleTypes |= reverse'
if ! run_validator > "${tmp}/validator.out" 2>&1; then
  fail "validator rejected equivalent Atlas module ordering"
  cat "${tmp}/validator.out" >&2
fi

for spec in \
  'github workflow-plugin-github github' \
  'workflow-plugin-migrations workflow-plugin-migrations workflow-migrate' \
  'workflow-plugin-atlas-migrate workflow-plugin-atlas-migrate workflow-migrate'; do
  read -r catalog artifact wrong_artifact <<< "${spec}"
  reset_fixtures
  mutate "${catalog}" ".downloads[0].url |= sub(\"/${artifact}-\"; \"/${wrong_artifact}-\")"
  expect_rejection "${catalog} wrong first archive role" 'catalog downloads must select full plugin archives'
done

reset_fixtures
mutate workflow-plugin-migrations '.downloads[0].url |= sub("/workflow-plugin-migrations-"; "/workflow-plugin-atlas-migrate-")'
expect_rejection 'main migrations with an Atlas archive' 'catalog downloads must select full plugin archives'

for catalog in github workflow-plugin-migrations workflow-plugin-atlas-migrate; do
  reset_fixtures
  mutate "${catalog}" '.downloads[1] = .downloads[0]'
  expect_rejection "${catalog} duplicate OS/arch" 'catalog downloads must select full plugin archives'
done

reset_fixtures
mutate github '.downloads = []'
expect_rejection 'empty Github downloads' 'catalog downloads must select full plugin archives'

reset_fixtures
mutate workflow-plugin-atlas-migrate '.downloads[0].os = "windows" | .downloads[0].url |= sub("-darwin-"; "-windows-")'
expect_rejection 'unsupported Atlas Windows archive' 'catalog downloads must select full plugin archives'

for expression in \
  '.capabilities.migrationDrivers = ["golang-migrate", "goose"]' \
  '.capabilities.stepTypes = ["step.migrate_up"]' \
  '.capabilities.cliCommands = [{"name":"db-migrate"}]' \
  '.capabilities.workflowHandlers = ["http"]'; do
  reset_fixtures
  mutate workflow-plugin-atlas-migrate "${expression}"
  expect_rejection "Atlas metadata: ${expression}" 'Atlas catalog must match its driver-only capabilities'
done

if [[ "${failures}" -gt 0 ]]; then
  echo "Artifact-role regression tests failed: ${failures}" >&2
  exit 1
fi
echo "validate-manifests artifact-role tests passed"
