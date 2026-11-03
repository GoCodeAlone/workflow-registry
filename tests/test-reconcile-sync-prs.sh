#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/registry-reconcile-prs.XXXXXX")"
trap 'rm -rf "${tmp}"' EXIT

mkdir -p "${tmp}/bin"
cat > "${tmp}/bin/gh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-} ${2:-}" in
  'pr list') cat "${GH_PR_FIXTURE:?}" ;;
  'pr comment'|'pr close')
    printf '%s %s\n' "$2" "$3" >> "${GH_PR_RECORD:?}"
    ;;
  *) echo "unexpected gh request in reconciliation test" >&2; exit 2 ;;
esac
MOCK
chmod +x "${tmp}/bin/gh"

cat > "${tmp}/prs.json" <<'JSON'
[
  {"number":100,"title":"older demo","author":{"login":"app/github-actions"},"headRefName":"chore/sync-demo-v1.0.0"},
  {"number":200,"title":"current demo","author":{"login":"github-actions[bot]"},"headRefName":"chore/sync-demo-v2.0.0"},
  {"number":300,"title":"newer demo","author":{"login":"github-actions[bot]"},"headRefName":"chore/sync-demo-v3.0.0"},
  {"number":50,"title":"human work","author":{"login":"contributor"},"headRefName":"chore/sync-demo-v0.5.0"},
  {"number":60,"title":"unrelated branch","author":{"login":"github-actions[bot]"},"headRefName":"feature/unrelated"},
  {"number":70,"title":"older other plugin","author":{"login":"github-actions[bot]"},"headRefName":"chore/sync-other-v1.0.0"}
]
JSON

for mode in full plugin; do
  args=(--current-pr 200 --mode "${mode}")
  if [[ "${mode}" == plugin ]]; then
    args+=(--plugin demo)
  fi
  : > "${tmp}/calls"
  PATH="${tmp}/bin:${PATH}" \
  GH_PR_FIXTURE="${tmp}/prs.json" \
  GH_PR_RECORD="${tmp}/calls" \
    bash "${repo_root}/scripts/reconcile-sync-prs.sh" "${args[@]}"

  printf 'comment 100\nclose 100\n' > "${tmp}/expected"
  if [[ "${mode}" == full ]]; then
    printf 'comment 70\nclose 70\n' >> "${tmp}/expected"
  fi
  # Inspect the real script's attempted mutations, not just its log output.
  diff -u "${tmp}/expected" "${tmp}/calls"
done

echo "reconcile-sync-prs older-only tests passed"
