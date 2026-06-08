#!/usr/bin/env bash
# scripts/categorize-manifests.sh
#
# Assigns the `category` field to each plugin manifest under plugins/.
# Source of truth: the explicit CATEGORY_MAP array below.
#
# Usage:
#   --dry-run   Print what would change; exit non-zero if any plugin is unmapped.
#   --apply     Write category into each manifest.json.
#   --check     Read each manifest.json; exit non-zero if any has missing/null category.
#               Used by CI (validate.yml) to enforce category coverage on every PR.
#
# The CATEGORY_MAP is the authoritative assignment for all 86 plugin dirs
# as of 2026-05-21 (verified via `gh api repos/GoCodeAlone/workflow-registry/contents/plugins`).
# New plugin dirs added without a MAP entry will cause --dry-run and --check to fail.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
PLUGINS_DIR="${REPO_ROOT}/plugins"

declare -A CATEGORY_MAP=(
  [actors]="infrastructure"
  [admin]="core"
  [agent]="ai"
  [ai]="ai"
  [analytics]="integrations"
  [api]="core"
  [approval]="core"
  [audit]="observability"
  [audit-chain]="security"
  [auth]="core"
  [authz]="core"
  [authz-ui]="core"
  [aws]="infrastructure"
  [azure]="infrastructure"
  [bento]="core"
  [broker]="messaging"
  [ci-generator]="core"
  [cicd]="core"
  [cloud]="infrastructure"
  [cloud-ui]="core"
  [cms]="core"
  [configprovider]="core"
  [crm]="integrations"
  [data-engineering]="data"
  [datadog]="observability"
  [datastores]="data"
  [digitalocean]="infrastructure"
  [discord]="messaging"
  [dlq]="messaging"
  [erp]="integrations"
  [eventbus]="infrastructure"
  [eventstore]="data"
  [featureflags]="integrations"
  [gcp]="infrastructure"
  [github]="integrations"
  [gitlab]="integrations"
  [hover]="infrastructure"
  [http]="core"
  [infra]="core"
  [integration]="integrations"
  [k8s]="infrastructure"
  [launchdarkly]="integrations"
  [license]="core"
  [marketplace]="core"
  [mcp]="ai"
  [messaging]="messaging"
  [messaging-core]="core"
  [modularcompat]="core"
  [monday]="integrations"
  [namecheap]="infrastructure"
  [observability]="observability"
  [okta]="integrations"
  [openapi]="core"
  [openlms]="integrations"
  [payments]="payments"
  [pipelinesteps]="core"
  [platform]="core"
  [policy]="security"
  [ratchet]="core"
  [rooms]="core"
  [salesforce]="integrations"
  [scanner]="security"
  [scheduler]="core"
  [secrets]="security"
  [security]="security"
  [security-scanner]="security"
  [slack]="messaging"
  [sso]="integrations"
  [statemachine]="core"
  [steam]="integrations"
  [storage]="data"
  [teams]="integrations"
  [template]="core"
  [timeline]="data"
  [tofu]="infrastructure"
  [turnio]="messaging"
  [twilio]="messaging"
  [vectorstore]="data"
  [websocket]="messaging"
  [workflow-plugin-atlas-migrate]="data"
  [workflow-plugin-auth]="core"
  [workflow-plugin-compute]="core"
  [workflow-plugin-gitlab]="integrations"
  [workflow-plugin-migrations]="data"
  [workflow-plugin-product-capture]="core"
  [workflow-plugin-supply-chain]="security"
  [ws-auth]="messaging"
)

MODE="${1:-}"
if [[ -z "${MODE}" ]]; then
  echo "Usage: $0 [--dry-run|--apply|--check]" >&2
  exit 1
fi

fail=0

case "${MODE}" in
  --dry-run)
    echo "=== dry-run: showing category assignments ==="
    while IFS= read -r manifest; do
      plugin="$(basename "$(dirname "${manifest}")")"
      cat="${CATEGORY_MAP[$plugin]:-}"
      if [[ -z "${cat}" ]]; then
        echo "  UNMAPPED: ${plugin} → add to CATEGORY_MAP in $0" >&2
        fail=1
      else
        current="$(jq -r '.category // "null"' "${manifest}")"
        if [[ "${current}" == "${cat}" ]]; then
          echo "  OK (already set): ${plugin} → ${cat}"
        else
          echo "  WOULD SET: ${plugin} → ${cat} (currently: ${current})"
        fi
      fi
    done < <(find "${PLUGINS_DIR}" -name "manifest.json" | sort)
    if [[ "${fail}" -ne 0 ]]; then
      echo "ERROR: unmapped plugins found. Add them to CATEGORY_MAP before running --apply." >&2
      exit 1
    fi
    ;;

  --apply)
    echo "=== apply: writing category to manifests ==="
    while IFS= read -r manifest; do
      plugin="$(basename "$(dirname "${manifest}")")"
      cat="${CATEGORY_MAP[$plugin]:-}"
      if [[ -z "${cat}" ]]; then
        echo "  SKIP UNMAPPED: ${plugin} — add to CATEGORY_MAP first" >&2
        fail=1
        continue
      fi
      # Use jq to add/update the category field (preserves all other fields).
      tmp="$(mktemp)"
      jq --arg cat "${cat}" '. + {category: $cat}' "${manifest}" > "${tmp}"
      mv "${tmp}" "${manifest}"
      echo "  SET: ${plugin} → ${cat}"
    done < <(find "${PLUGINS_DIR}" -name "manifest.json" | sort)
    if [[ "${fail}" -ne 0 ]]; then
      echo "ERROR: some plugins were unmapped and skipped. Add them to CATEGORY_MAP." >&2
      exit 1
    fi
    echo "Done."
    ;;

  --check)
    echo "=== check: verifying all manifests have category assigned ==="
    while IFS= read -r manifest; do
      plugin="$(basename "$(dirname "${manifest}")")"
      cat="$(jq -r '.category // empty' "${manifest}")"
      if [[ -z "${cat}" ]]; then
        echo "  FAIL: ${plugin} is missing category in manifest.json — run scripts/categorize-manifests.sh --apply or add to CATEGORY_MAP" >&2
        fail=1
      fi
    done < <(find "${PLUGINS_DIR}" -name "manifest.json" | sort)
    if [[ "${fail}" -ne 0 ]]; then
      echo "ERROR: plugin(s) missing category. Add to CATEGORY_MAP and re-run --apply." >&2
      exit 1
    fi
    echo "OK — all plugins have category assigned."
    ;;

  *)
    echo "Unknown mode: ${MODE}" >&2
    echo "Usage: $0 [--dry-run|--apply|--check]" >&2
    exit 1
    ;;
esac
