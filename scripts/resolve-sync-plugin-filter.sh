#!/usr/bin/env bash
# Resolve the plugin filter for sync-registry-manifests.yml.

set -euo pipefail

plugins_dir="${PLUGINS_DIR:-plugins}"
event_name="${EVENT_NAME:-}"
dispatch_action="${DISPATCH_ACTION:-}"
plugin_from_dispatch="${PLUGIN_FROM_DISPATCH:-}"
plugin_from_input="${PLUGIN_FROM_INPUT:-}"
github_output="${GITHUB_OUTPUT:-}"

emit() {
  local key="$1"
  local value="$2"
  if [[ -n "${github_output}" ]]; then
    echo "${key}=${value}" >> "${github_output}"
  else
    echo "${key}=${value}"
  fi
}

warn() {
  echo "::warning::$*" >&2
}

manifest_repository() {
  local manifest="$1"
  jq -r '.repository // empty' "${manifest}"
}

plugin=""
case "${event_name}" in
  repository_dispatch)
    if [[ "${dispatch_action}" == "plugin-release" ]]; then
      plugin="${plugin_from_dispatch}"
      if [[ -z "${plugin}" ]]; then
        warn "plugin-release dispatch received with empty client_payload.plugin; skipping (use workflow-release for full-sync intent)"
        emit "skip" "1"
        emit "plugin" ""
        exit 0
      fi
    fi
    ;;
  workflow_dispatch)
    plugin="${plugin_from_input}"
    ;;
esac

if [[ -n "${plugin}" ]]; then
  if [[ "${plugin}" == "." || "${plugin}" == ".." ]]; then
    warn "plugin-name '.'/'..' rejected (path traversal attempt); skipping"
    emit "skip" "1"
    emit "plugin" ""
    exit 0
  fi
  if [[ ! "${plugin}" =~ ^[A-Za-z0-9._-]+$ ]]; then
    warn "plugin-name regex validation failed; ignoring this dispatch"
    emit "skip" "1"
    emit "plugin" ""
    exit 0
  fi

  manifest="${plugins_dir}/${plugin}/manifest.json"
  alias="workflow-plugin-${plugin}"
  alias_manifest="${plugins_dir}/${alias}/manifest.json"
  if [[ -f "${manifest}" && -f "${alias_manifest}" ]]; then
    repo="$(manifest_repository "${manifest}")"
    alias_repo="$(manifest_repository "${alias_manifest}")"
    if [[ "${repo}" == "https://github.com/GoCodeAlone/workflow" && "${alias_repo}" != "https://github.com/GoCodeAlone/workflow" ]]; then
      echo "resolved plugin-release alias ${plugin} -> ${alias}" >&2
      plugin="${alias}"
      manifest="${alias_manifest}"
    fi
  fi

  if [[ ! -f "${manifest}" ]]; then
    warn "dispatched plugin has no plugins/<name>/manifest.json; skipping"
    emit "skip" "1"
    emit "plugin" ""
    exit 0
  fi
fi

emit "plugin" "${plugin}"
emit "skip" "0"
