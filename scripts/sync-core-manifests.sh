#!/usr/bin/env bash
# Check or update registry manifests for built-in core plugins from workflow.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGINS_DIR="${REPO_ROOT}/plugins"
WORKFLOW_REPO="${WORKFLOW_REPO:-${REPO_ROOT}/../workflow}"
FIX=false

if [[ "${1:-}" == "--fix" ]]; then
  FIX=true
elif [[ $# -gt 0 ]]; then
  echo "usage: scripts/sync-core-manifests.sh [--fix]" >&2
  exit 2
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "error: jq is required" >&2
  exit 1
fi

if ! command -v go >/dev/null 2>&1; then
  echo "error: go is required" >&2
  exit 1
fi

if [[ ! -f "${WORKFLOW_REPO}/go.mod" ]]; then
  echo "error: WORKFLOW_REPO must point to a workflow checkout: ${WORKFLOW_REPO}" >&2
  exit 1
fi

inspect_dir="$(mktemp -d "${WORKFLOW_REPO}/.workflow-core-inspect.XXXXXX")"
inspect_go="${inspect_dir}/main.go"
actual_json="$(mktemp)"
expected_json="$(mktemp)"
current_json="$(mktemp)"
trap 'rm -rf "$inspect_dir"; rm -f "$actual_json" "$expected_json" "$current_json"' EXIT

cat > "$inspect_go" <<'GO'
package main

import (
	"encoding/json"
	"os"
	"sort"

	"github.com/GoCodeAlone/workflow/plugin"
	"github.com/GoCodeAlone/workflow/plugins/all"
)

type corePlugin struct {
	Name             string   `json:"name"`
	Version          string   `json:"version"`
	Description      string   `json:"description"`
	ModuleTypes      []string `json:"moduleTypes"`
	StepTypes        []string `json:"stepTypes"`
	TriggerTypes     []string `json:"triggerTypes"`
	WorkflowHandlers []string `json:"workflowHandlers"`
	WiringHooks      []string `json:"wiringHooks"`
}

func mapKeys[T any](m map[string]T) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}

func hookNames(hooks []plugin.WiringHook) []string {
	names := make([]string, 0, len(hooks))
	for _, hook := range hooks {
		if hook.Name != "" {
			names = append(names, hook.Name)
		}
	}
	sort.Strings(names)
	return names
}

func main() {
	out := make([]corePlugin, 0)
	for _, p := range all.DefaultPlugins() {
		m := p.EngineManifest()
		out = append(out, corePlugin{
			Name:             m.Name,
			Version:          m.Version,
			Description:      m.Description,
			ModuleTypes:      mapKeys(p.ModuleFactories()),
			StepTypes:        mapKeys(p.StepFactories()),
			TriggerTypes:     mapKeys(p.TriggerFactories()),
			WorkflowHandlers: mapKeys(p.WorkflowHandlers()),
			WiringHooks:      hookNames(p.WiringHooks()),
		})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	if err := json.NewEncoder(os.Stdout).Encode(out); err != nil {
		panic(err)
	}
}
GO

(cd "$WORKFLOW_REPO" && GOWORK=off go run "./$(basename "$inspect_dir")") > "$actual_json"

manifest_path_for() {
  local name="$1"
  local exact

  exact="$(jq -r --arg name "$name" 'select(.name == $name) | input_filename' "${PLUGINS_DIR}"/*/manifest.json | head -n 1)"
  if [[ -n "$exact" ]]; then
    echo "$exact"
    return 0
  fi

  local alias="$name"
  alias="${alias#workflow-plugin-}"
  alias="${alias%-plugin}"
  case "$alias" in
    "feature-flags") alias="featureflags" ;;
    "pipeline-steps") alias="pipelinesteps" ;;
    "modular-compat") alias="modularcompat" ;;
    "kubernetes-deploy") alias="k8s" ;;
  esac

  if [[ -f "${PLUGINS_DIR}/${alias}/manifest.json" ]]; then
    echo "${PLUGINS_DIR}/${alias}/manifest.json"
    return 0
  fi

  echo "${PLUGINS_DIR}/${alias}/manifest.json"
}

normalize_manifest() {
  jq -S '{
    name,
    version,
    author,
    description,
    source,
    path,
    type,
    tier,
    license,
    homepage,
    repository,
    capabilities: {
      moduleTypes: (.capabilities.moduleTypes // [] | sort),
      stepTypes: (.capabilities.stepTypes // [] | sort),
      triggerTypes: (.capabilities.triggerTypes // [] | sort),
      workflowHandlers: (.capabilities.workflowHandlers // [] | sort),
      wiringHooks: (.capabilities.wiringHooks // [] | sort)
    }
  }' "$1"
}

failures=0

while IFS= read -r plugin_json; do
  name="$(jq -r '.name' <<<"$plugin_json")"
  manifest="$(manifest_path_for "$name")"
  dir="$(basename "$(dirname "$manifest")")"
  rel_path="plugins/${dir}"

  jq -S -n \
    --arg name "$name" \
    --arg version "$(jq -r '.version' <<<"$plugin_json")" \
    --arg description "$(jq -r '.description' <<<"$plugin_json")" \
    --arg path "$rel_path" \
    --argjson moduleTypes "$(jq '.moduleTypes' <<<"$plugin_json")" \
    --argjson stepTypes "$(jq '.stepTypes' <<<"$plugin_json")" \
    --argjson triggerTypes "$(jq '.triggerTypes' <<<"$plugin_json")" \
    --argjson workflowHandlers "$(jq '.workflowHandlers' <<<"$plugin_json")" \
    --argjson wiringHooks "$(jq '.wiringHooks' <<<"$plugin_json")" \
    '{
      name: $name,
      version: $version,
      author: "GoCodeAlone",
      description: $description,
      source: "github.com/GoCodeAlone/workflow",
      path: $path,
      type: "builtin",
      tier: "core",
      license: "MIT",
      homepage: "https://github.com/GoCodeAlone/workflow",
      repository: "https://github.com/GoCodeAlone/workflow",
      capabilities: {
        moduleTypes: ($moduleTypes | sort),
        stepTypes: ($stepTypes | sort),
        triggerTypes: ($triggerTypes | sort),
        workflowHandlers: ($workflowHandlers | sort),
        wiringHooks: ($wiringHooks | sort)
      }
    }' > "$expected_json"

  if [[ ! -f "$manifest" ]]; then
    if $FIX; then
      mkdir -p "$(dirname "$manifest")"
      jq -S '.' "$expected_json" > "$manifest"
      echo "created ${manifest#${REPO_ROOT}/}"
      continue
    fi
    echo "missing core plugin manifest for ${name}: expected ${manifest#${REPO_ROOT}/}" >&2
    failures=$((failures + 1))
    continue
  fi

  normalize_manifest "$manifest" > "$current_json"

  if ! diff -u "$current_json" "$expected_json" >/dev/null; then
    if $FIX; then
      tmp="$(mktemp)"
      jq -S --slurpfile expected "$expected_json" '
        . as $current |
        ($expected[0]) as $next |
        ($current
          + $next
          + {
            capabilities: (($current.capabilities // {}) + $next.capabilities)
          })
        | del(.downloads)
      ' "$manifest" > "$tmp"
      mv "$tmp" "$manifest"
      echo "updated ${manifest#${REPO_ROOT}/}"
    else
      echo "core plugin manifest drift for ${name}: ${manifest#${REPO_ROOT}/}" >&2
      diff -u "$current_json" "$expected_json" || true
      failures=$((failures + 1))
    fi
  fi
done < <(jq -c '.[]' "$actual_json")

if [[ $failures -gt 0 ]]; then
  echo "core manifest validation failed: ${failures} issue(s)" >&2
  exit 1
fi

if $FIX; then
  echo "Core plugin manifests synced."
else
  echo "Core plugin manifests match workflow plugin declarations."
fi
