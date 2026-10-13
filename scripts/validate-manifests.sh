#!/usr/bin/env bash
# validate-manifests.sh — validates every plugins/*/manifest.json against
# schema/registry-schema.json using ajv-cli (JSON Schema draft 2020-12).

set -euo pipefail

REPO_ROOT="${REGISTRY_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SCHEMA="${REGISTRY_SCHEMA:-$REPO_ROOT/schema/registry-schema.json}"
PLUGINS_DIR="${PLUGINS_DIR:-$REPO_ROOT/plugins}"

errors=0

# Use the globally installed ajv if available, otherwise fall back to npx
AJV="${AJV:-$(command -v ajv 2>/dev/null || echo "npx --yes ajv-cli")}"

for manifest in "$PLUGINS_DIR"/*/manifest.json; do
  if ! $AJV validate --spec=draft2020 -s "$SCHEMA" -d "$manifest"; then
    errors=$((errors + 1))
  fi
  if ! jq -e '
    (.name // "") as $name |
    (.source // "") as $source |
    (.repository // "") as $repository |
    ($name != "scaffold-workflow-plugin")
    and ($source != "github.com/GoCodeAlone/scaffold-workflow-plugin")
    and ($repository != "https://github.com/GoCodeAlone/scaffold-workflow-plugin")
  ' "$manifest" >/dev/null; then
    echo "$manifest invalid: scaffold/template repositories must not be published as installable plugins" >&2
    errors=$((errors + 1))
  fi
  if jq -e '.. | objects | has("flags_passthrough")' "$manifest" >/dev/null; then
    echo "$manifest invalid: use capabilities.cliCommands[].flagsPassthrough instead of legacy flags_passthrough" >&2
    errors=$((errors + 1))
  fi
  if ! jq -e '
    [
      (.capabilities.moduleTypes // [])[],
      (.capabilities.stepTypes // [])[],
      (.capabilities.triggerTypes // [])[],
      (.capabilities.workflowHandlers // [])[],
      (.capabilities.resourceTypes // [])[]
    ] | all(. as $value | ($value | test("(^TEMPLATE\\.|\\.TEMPLATE\\.|\\.placeholder$|^placeholder\\.)") | not))
  ' "$manifest" >/dev/null; then
    echo "$manifest invalid: placeholder capability names must not be published" >&2
    errors=$((errors + 1))
  fi
  if ! jq -e '
    (.version // "") as $version |
    if $version == "" then
      true
    else
      all((.downloads // [])[]?;
        (.url | test("/releases/download/v" + $version + "/"))
      )
    end
  ' "$manifest" >/dev/null; then
    echo "$manifest invalid: downloads[].url release tag must match manifest version" >&2
    errors=$((errors + 1))
  fi

  # These releases contain standalone and plugin archive families. wfctl
  # selects the first OS/arch match, so publish only the full plugin role.
  catalog="$(basename "$(dirname "$manifest")")"
  artifact=""
  case "$catalog" in
    github)
      artifact="workflow-plugin-github"
      repository="workflow-plugin-github"
      operating_systems='["darwin", "linux", "windows"]'
      download_count=6
      ;;
    workflow-plugin-migrations)
      artifact="workflow-plugin-migrations"
      repository="workflow-plugin-migrations"
      operating_systems='["darwin", "linux", "windows"]'
      download_count=6
      ;;
    workflow-plugin-atlas-migrate)
      artifact="workflow-plugin-atlas-migrate"
      repository="workflow-plugin-migrations"
      operating_systems='["darwin", "linux"]'
      download_count=4
      ;;
  esac
  if [[ -n "$artifact" ]]; then
    if ! jq -e --arg catalog "$catalog" --arg artifact "$artifact" \
      --arg repository "$repository" --argjson operating_systems "$operating_systems" \
      --argjson download_count "$download_count" '
      .version as $version | (.downloads // []) as $downloads |
      .name == $catalog and .type == "external"
      and ($downloads | length == $download_count)
      and ($downloads | map([.os, .arch]) | unique | length == $download_count)
      and all($downloads[]; . as $download |
        ($operating_systems | index($download.os)) != null
        and (["amd64", "arm64"] | index($download.arch)) != null
        and $download.url == ("https://github.com/GoCodeAlone/" + $repository
          + "/releases/download/v" + $version + "/" + $artifact
          + "-" + $download.os + "-" + $download.arch + ".tar.gz"))
    ' "$manifest" >/dev/null; then
      echo "$manifest invalid: catalog downloads must select full plugin archives with one entry per supported OS/arch" >&2
      errors=$((errors + 1))
    fi
  fi
  # Atlas is driver-only; use plugin.atlas.json, not the main plugin manifest.
  if [[ "$catalog" == "workflow-plugin-atlas-migrate" ]] && ! jq -e '
    (.capabilities | keys) == ["buildHooks", "cliCommands", "configProvider",
      "migrationDrivers", "moduleTypes", "stepTypes", "triggerTypes"]
    and .capabilities.configProvider == false
    and (.capabilities.moduleTypes | sort) == ["database.migration_driver", "database.migrations"]
    and .capabilities.migrationDrivers == ["atlas"]
    and .capabilities.stepTypes == [] and .capabilities.cliCommands == []
    and .capabilities.triggerTypes == [] and .capabilities.buildHooks == []
  ' "$manifest" >/dev/null; then
    echo "$manifest invalid: Atlas catalog must match its driver-only capabilities" >&2
    errors=$((errors + 1))
  fi
done

if [[ $errors -gt 0 ]]; then
  echo ""
  echo "Manifest validation failed: $errors invalid manifest(s)."
  exit 1
else
  echo "All plugin manifests are valid."
fi
