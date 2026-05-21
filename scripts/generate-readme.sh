#!/usr/bin/env bash
# Regenerate README plugin/template indexes from registry source data.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
README="${REPO_ROOT}/README.md"
PLUGINS_DIR="${REPO_ROOT}/plugins"
TEMPLATES_DIR="${REPO_ROOT}/templates"
CHECK=false

if [[ "${1:-}" == "--check" ]]; then
  CHECK=true
elif [[ $# -gt 0 ]]; then
  echo "usage: scripts/generate-readme.sh [--check]" >&2
  exit 2
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "error: jq is required" >&2
  exit 1
fi

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

emit_plugin_rows() {
  local filter="$1"
  local third_column="$2"

  jq -r --arg third_column "$third_column" "$filter"' |
    [
      "[" + .dir + "](./plugins/" + .dir + "/manifest.json)",
      (.description | gsub("\\|"; "\\|") | gsub("\n"; " ")),
      .[$third_column]
    ] | @tsv' "${PLUGINS_DIR}"/*/manifest.json |
    sort -f |
    awk -F '\t' '{ printf "| %s | %s | %s |\n", $1, $2, $3 }'
}

template_description() {
  awk '
    /^description:/ {
      sub(/^description:[[:space:]]*/, "")
      gsub(/\|/, "\\|")
      print
      found=1
      exit
    }
    END { if (!found) print "" }
  ' "$1"
}

{
  awk '/^## (Built-in|Core) Plugins$/ { exit } { print }' "$README"

  cat <<'MARKDOWN'
## Core Plugins

These plugins are maintained by GoCodeAlone as part of the core Workflow ecosystem. `builtin` plugins ship in the `GoCodeAlone/workflow` engine; `external` core plugins are maintained separately but treated as first-party platform capabilities.

| Plugin | Description | Type |
|--------|-------------|------|
MARKDOWN
  emit_plugin_rows '{
      dir: (input_filename | split("/")[-2]),
      name,
      description: (.description // ""),
      type: (.type // ""),
      tier: (.tier // "")
    } | select(.tier == "core")' "type"

  cat <<'MARKDOWN'

## External Plugins

These plugins run outside the core engine process or are distributed from a separate plugin repository.

| Plugin | Description | Tier |
|--------|-------------|------|
MARKDOWN
  emit_plugin_rows '{
      dir: (input_filename | split("/")[-2]),
      name,
      description: (.description // ""),
      type: (.type // ""),
      tier: (.tier // "")
    } | select(.type == "external")' "tier"

  cat <<'MARKDOWN'

## Templates

Starter configurations for common workflow patterns:

| Template | Description |
|----------|-------------|
MARKDOWN

  while IFS= read -r template; do
    name="$(basename "$template" .yaml)"
    desc="$(template_description "$template")"
    printf '| [%s](./templates/%s) | %s |\n' "$name" "$(basename "$template")" "$desc"
  done < <(find "$TEMPLATES_DIR" -maxdepth 1 -name '*.yaml' | sort)

  echo
  cat <<'MARKDOWN'
Initialize a project from a template:

```bash
wfctl init my-project --template api-service
```

---

MARKDOWN

  awk 'found { print; next } /^## Schema$/ { found=1; print }' "$README"
} > "$tmp"

if $CHECK; then
  if ! diff -u "$README" "$tmp"; then
    echo "README.md is out of date; run scripts/generate-readme.sh" >&2
    exit 1
  fi
else
  mv "$tmp" "$README"
  trap - EXIT
fi
