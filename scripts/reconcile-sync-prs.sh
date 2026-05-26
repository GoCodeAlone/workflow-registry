#!/usr/bin/env bash
# Close superseded bot-created registry sync PRs.

set -euo pipefail

REPO="GoCodeAlone/workflow-registry"
CURRENT_PR=""
MODE=""
PLUGIN=""
DRY_RUN=false

usage() {
  cat >&2 <<'EOF'
usage: scripts/reconcile-sync-prs.sh --current-pr <number> --mode full|plugin [--plugin <name>] [--dry-run]

Modes:
  full    close older bot sync PRs for any plugin/full-registry sync
  plugin  close older bot sync PRs for the same plugin only
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --current-pr)
      shift
      CURRENT_PR="${1:-}"
      ;;
    --mode)
      shift
      MODE="${1:-}"
      ;;
    --plugin)
      shift
      PLUGIN="${1:-}"
      ;;
    --dry-run)
      DRY_RUN=true
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage
      exit 2
      ;;
  esac
  shift
done

if [[ -z "$CURRENT_PR" || -z "$MODE" ]]; then
  usage
  exit 2
fi

case "$MODE" in
  full) ;;
  plugin)
    if [[ -z "$PLUGIN" ]]; then
      echo "--plugin is required when --mode plugin" >&2
      exit 2
    fi
    ;;
  *)
    echo "--mode must be full or plugin" >&2
    exit 2
    ;;
esac

prs_json="$(gh pr list --repo "$REPO" --state open --limit 100 \
  --json number,title,author,headRefName,url)"

if [[ "$MODE" == "full" ]]; then
  candidates="$(jq -r --argjson current "$CURRENT_PR" '
    .[]
    | select(.number != $current)
    | select(.author.login == "app/github-actions" or .author.login == "github-actions[bot]")
    | select(.headRefName | startswith("chore/sync-"))
    | [.number, .headRefName, .title] | @tsv
  ' <<<"$prs_json")"
else
  candidates="$(jq -r --argjson current "$CURRENT_PR" --arg plugin "$PLUGIN" '
    .[]
    | select(.number != $current)
    | select(.author.login == "app/github-actions" or .author.login == "github-actions[bot]")
    | select(.headRefName | startswith("chore/sync-" + $plugin + "-"))
    | [.number, .headRefName, .title] | @tsv
  ' <<<"$prs_json")"
fi

if [[ -z "$candidates" ]]; then
  echo "reconcile-sync-prs: no superseded sync PRs found"
  exit 0
fi

while IFS=$'\t' read -r pr branch title; do
  [[ -n "$pr" ]] || continue
  echo "reconcile-sync-prs: superseded #$pr ($branch) $title"
  if $DRY_RUN; then
    continue
  fi
  gh pr comment "$pr" --repo "$REPO" \
    --body "Closed as superseded by registry sync PR #${CURRENT_PR}. The newer sync PR covers this generated manifest update."
  gh pr close "$pr" --repo "$REPO" --delete-branch
done <<<"$candidates"
