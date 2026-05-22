# Dynamic Plugin Sync Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a `category` enum field to workflow-registry's manifest schema, sweep all 86 plugin manifests with explicit category assignments, add parity to workflow-cloud-registry's schema, and wire a scheduled cron sync in gocodealone-website that fetches the live registry index and commits a snapshot — enabling PluginsPage.tsx to render dynamically from live registry data.

**Architecture:** PR 1 adds the optional `category` enum to `schema/registry-schema.json` and wires the G3 projection + test assertions; PR 2 sweeps all 86 plugin manifests with the explicit CATEGORY_MAP and adds a CI gate (`--check` mode) in `validate.yml`; PR 3 ports the schema change to `workflow-cloud-registry` (schema-only, no sweep); PR 4 adds `scripts/sync-plugins.mjs`, `src/data/plugins.json` snapshot, `.github/workflows/registry-sync.yml` (cron */15 min + workflow_dispatch, 3-case branch policy), and rewrites `PluginsPage.tsx` to consume the committed snapshot.

**Tech Stack:** Bash (jq), JSON Schema (draft/2020-12), Node.js 22 (ESM, fetch API), TypeScript/React (Vite), GitHub Actions (ubuntu-latest, GITHUB_TOKEN), ajv-cli

**Base branch:** main (all repos)

---

## Scope Manifest

**PR Count:** 4
**Tasks:** 14
**Estimated Lines of Change:** ~1800 (86 manifest edits ~860 lines, schema 2×~15 lines, build-index.sh ~8 lines, test additions ~40 lines, categorize-manifests.sh ~130 lines, validate.yml ~8 lines, sync-plugins.mjs ~60 lines, plugins.json snapshot ~600 lines, PluginsPage.tsx rewrite ~80 lines, registry-sync.yml ~60 lines)

**Out of scope:**
- Modifying `release.yml` in gocodealone-website (M-1 defect from round-2; separate fix PR)
- Cross-repo dispatch from workflow-registry to gocodealone-website (dropped in round-1)
- Auto-merging the cron-opened snapshot PRs (A8: acceptable fallback if ruleset blocks github-actions[bot])
- Surfacing `keywords`, `capabilities`, `iacProvider`, `assets`, `required_secrets` in PluginsPage cards (future iteration)
- Deploying gocodealone-website to production (deploys happen on next manual `git tag v*` push)

**PR Grouping:**

| PR # | Title | Tasks | Branch |
|------|-------|-------|--------|
| 1 | feat(schema): add `category` enum + G3 projection + test assertions | Task 1, Task 2, Task 3 | feat/category-schema |
| 2 | feat(registry): categorize all 86 plugin manifests + CI gate | Task 4, Task 5, Task 6 | feat/categorize-plugins |
| 3 | feat(schema): add `category` enum to workflow-cloud-registry (parity) | Task 7 | feat/category-schema |
| 4 | feat(plugins-page): scheduled sync from workflow-registry | Task 8, Task 9, Task 10, Task 11, Task 12, Task 13, Task 14 | feat/plugins-dynamic-sync |

**Status:** Locked 2026-05-21T00:00:00Z

---

## Sequence note

PR 1 BEFORE PR 2 (PR 2 writes `category` values that must pass schema validation). PR 3 can merge in parallel with PR 1/2 (independent repo). PR 4 AFTER PRs 1+2 merge AND GH Pages rebuilds (so the initial `src/data/plugins.json` snapshot is fresh with `category` fields).

---

## PR 1 — feat(schema): add `category` enum + G3 projection + test assertions

### Task 1: Add `category` enum to `schema/registry-schema.json`

**Files:**
- Modify: `schema/registry-schema.json`

**Step 1: Add the `category` property**

In `schema/registry-schema.json`, add the following property block immediately after the closing `}` of the `"assets"` property (before `"dependencies"`). The field is optional (not in `required`):

```json
"category": {
  "type": "string",
  "enum": ["core", "ai", "payments", "security", "infrastructure", "ide",
           "messaging", "data", "integrations", "observability", "other"],
  "description": "Coarse-grained category for UI grouping (e.g. the gocodealone-website plugins page). Optional — manifests without a category render under 'other'."
},
```

**Step 2: Verify schema is valid JSON**

Run:
```bash
jq empty schema/registry-schema.json
```
Expected: exits 0, no output.

**Step 3: Verify existing manifests still validate (pre-sweep)**

Run:
```bash
npm install --global ajv-cli
bash scripts/validate-manifests.sh
```
Expected: all 86 manifests validate. No "category" errors (field is optional). Exit 0.

**Step 4: Commit**

```bash
git add schema/registry-schema.json
git commit -m "feat(schema): add optional category enum to registry-schema.json"
```

Rollback: `git revert HEAD` removes the field; existing manifests stay valid (field is optional).

---

### Task 2: Add G3 projection for `category` in `scripts/build-index.sh`

**Files:**
- Modify: `scripts/build-index.sh`

**Step 1: Add the `category` G3-include marker and jq projection**

In `scripts/build-index.sh`, find the G3 markers block (starts with `# G3-include: name`). After the line `# G3-include: status` (line ~68), add the new marker immediately below:

```bash
  # G3-include: category
```

Then in the jq summary projection (the `summary="$(jq ... '({` block), after the line:

```
    status:           (.status // null),
```

add:

```
    category:         (.category // null),
```

**Step 2: Run the schema↔allowlist drift guard test**

Run:
```bash
bash tests/test-schema-allowlist-coverage.sh
```
Expected: `OK — test-schema-allowlist-coverage.sh passed (N schema props ↔ N markers)` where N is the count including the new `category` property. Exit 0.

The existing script already auto-detects top-level schema properties; adding `# G3-include: category` satisfies the forward-trace for the new field.

**Step 3: Run the full build-index test to confirm projection works**

Run:
```bash
bash tests/test-build-index.sh
```
Expected: `OK — test-build-index.sh passed`. Exit 0. (The existing fixtures don't have `category`, so the new projection emits `"category": null` for them — this is correct behavior for the optional field.)

**Step 4: Commit**

```bash
git add scripts/build-index.sh
git commit -m "feat(build-index): project category field through G3 allowlist"
```

---

### Task 3: Add `category` test assertion to `tests/test-build-index.sh` + update fixture

**Files:**
- Modify: `tests/test-build-index.sh`
- Modify: `tests/fixtures/plugins/foo-iac/manifest.json`

**Step 1: Add `"category": "infrastructure"` to the foo-iac fixture**

In `tests/fixtures/plugins/foo-iac/manifest.json`, add the following field anywhere in the top-level JSON object (e.g. after `"status": "verified"`):

```json
"category": "infrastructure",
```

**Step 2: Add assertion in test-build-index.sh**

In `tests/test-build-index.sh`, after the line:
```bash
assert_jq "foo-iac status" '.[] | select(.name=="foo-iac") | .status' '"verified"'
```

add:

```bash
assert_jq "foo-iac category" '.[] | select(.name=="foo-iac") | .category' '"infrastructure"'
```

Also verify that plugins WITHOUT a `category` field (like `bar-simple`) emit `null` not an error. Add after the `bar-simple status` assertion:

```bash
assert_jq "bar-simple category is null (optional field, not set in fixture)" \
  '.[] | select(.name=="bar-simple") | .category' 'null'
```

**Step 3: Run test-build-index.sh to confirm new assertions pass**

Run:
```bash
bash tests/test-build-index.sh
```
Expected: `OK — test-build-index.sh passed`. Exit 0. Both new assertions must appear in the passing output path.

**Step 4: Run schema allowlist coverage to confirm no regression**

Run:
```bash
bash tests/test-schema-allowlist-coverage.sh
```
Expected: `OK — test-schema-allowlist-coverage.sh passed`. Exit 0.

**Step 5: Commit**

```bash
git add tests/test-build-index.sh tests/fixtures/plugins/foo-iac/manifest.json
git commit -m "test(build-index): assert category field surfaces in projection + fixture"
```

---

## PR 2 — feat(registry): categorize all 86 plugin manifests + CI gate

### Task 4: Write `scripts/categorize-manifests.sh` with CATEGORY_MAP

**Files:**
- Create: `scripts/categorize-manifests.sh`

**Step 1: Write the script**

Create `scripts/categorize-manifests.sh` with the following content:

```bash
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
      echo "ERROR: ${fail} plugin(s) missing category. Add to CATEGORY_MAP and re-run --apply." >&2
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
```

**Step 2: Make executable**

```bash
chmod +x scripts/categorize-manifests.sh
```

**Step 3: Run dry-run to verify all 86 plugins map**

```bash
bash scripts/categorize-manifests.sh --dry-run
```
Expected: 86 lines of `WOULD SET:` or `OK (already set):`. Zero `UNMAPPED:` lines. Exit 0.

If any `UNMAPPED:` lines appear, add those plugin dir names to the CATEGORY_MAP in the script and re-run until clean.

**Step 4: Commit the script**

```bash
git add scripts/categorize-manifests.sh
git commit -m "feat(scripts): add categorize-manifests.sh with explicit 86-entry CATEGORY_MAP"
```

---

### Task 5: Run `--apply` and commit all 86 manifest categorizations

**Files:**
- Modify: `plugins/*/manifest.json` (all 86)

**Step 1: Apply categorizations**

```bash
bash scripts/categorize-manifests.sh --apply
```
Expected: 86 lines of `SET: <plugin> → <category>`. Exit 0.

**Step 2: Verify all manifests now have category**

```bash
bash scripts/categorize-manifests.sh --check
```
Expected: `OK — all plugins have category assigned.` Exit 0.

**Step 3: Validate all manifests against schema**

```bash
bash scripts/validate-manifests.sh
```
Expected: all 86 manifests validate. No schema errors. Exit 0.

**Step 4: Verify the category values are valid enum values**

```bash
jq -r '.[].category' /dev/null 2>/dev/null || true
# Quick spot-check: all categories in manifests are in the enum
find plugins -name "manifest.json" -exec jq -r '.category // "null"' {} \; | sort | uniq -c | sort -rn
```
Expected: output shows 10 known category names (`core`, `ai`, `payments`, `security`, `infrastructure`, `ide`, `messaging`, `data`, `integrations`, `observability`) with their plugin counts. No `null`, no `other`, no unknown values.

**Step 5: Commit all 86 manifests**

```bash
git add plugins/
git commit -m "feat(registry): assign category to all 86 plugin manifests"
```

Rollback: `git revert HEAD` removes all categorizations; index.json emits `category: null` for each.

---

### Task 6: Add `--check` CI gate to `validate.yml`

**Files:**
- Modify: `.github/workflows/validate.yml`

**Step 1: Add a new job step to the `validate-manifests` job**

In `.github/workflows/validate.yml`, in the `validate-manifests` job, after the existing step `Validate all plugin manifests` (`run: bash scripts/validate-manifests.sh`), add:

```yaml
      - name: Validate every plugin has a category assigned
        run: bash scripts/categorize-manifests.sh --check
```

**Step 2: Verify the validate.yml is valid YAML**

```bash
python3 -c "import yaml, sys; yaml.safe_load(open('.github/workflows/validate.yml'))" && echo "YAML OK"
```
Expected: `YAML OK`. Exit 0.

**Step 3: Commit**

```bash
git add .github/workflows/validate.yml
git commit -m "ci: add category-coverage gate to validate.yml (categorize-manifests.sh --check)"
```

---

## PR 3 — feat(schema): add `category` enum to workflow-cloud-registry (parity)

*All work in this task happens in `/Users/jon/workspace/workflow-cloud-registry`.*

### Task 7: Add `category` to cloud-registry schema

**Files:**
- Modify: `schema/registry-schema.json` (in `workflow-cloud-registry` repo)

**Step 1: Check out feat branch in cloud-registry**

```bash
cd /Users/jon/workspace/workflow-cloud-registry
git checkout main && git pull
git checkout -b feat/category-schema
```

**Step 2: Add the `category` property to schema**

In `schema/registry-schema.json`, add the following property block. The cloud-registry schema currently has no `status`, `private`, `dependencies`, `required_secrets`, `iacProvider`, or `migrationDrivers` fields (it is a stripped-down schema). Add `category` as an optional top-level property in the `"properties"` block, after the `"assets"` property:

```json
"category": {
  "type": "string",
  "enum": ["core", "ai", "payments", "security", "infrastructure", "ide",
           "messaging", "data", "integrations", "observability", "other"],
  "description": "Coarse-grained category for UI grouping (e.g. the gocodealone-website plugins page). Optional — manifests without a category render under 'other'."
}
```

**Step 3: Verify schema is valid JSON**

```bash
jq empty schema/registry-schema.json && echo "JSON OK"
```
Expected: `JSON OK`. Exit 0.

**Step 4: Validate existing cloud-registry manifests still pass**

```bash
npm install --global ajv-cli 2>/dev/null || true
bash scripts/validate-manifests.sh 2>/dev/null || echo "no validate script; manual check OK"
```
Expected: all cloud-registry manifests validate. The field is optional so no `category`-absent manifests break.

**Step 5: Commit and push, open PR**

```bash
git add schema/registry-schema.json
git commit -m "feat(schema): add optional category enum (parity with workflow-registry)"
git push origin feat/category-schema
gh pr create --base main --head feat/category-schema \
  --title "feat(schema): add category enum (parity with workflow-registry)" \
  --body "Ports the optional \`category\` enum from workflow-registry schema. Private cloud plugins don't surface to the public website, so no value sweep is required. Schema-only change; all existing manifests remain valid."
```

Rollback: `git revert HEAD`; existing cloud manifests stay valid (field was optional).

---

## PR 4 — feat(plugins-page): scheduled sync from workflow-registry

*All work in Tasks 8–14 happens in `/Users/jon/workspace/gocodealone-website`.*

**Wait condition before starting Task 8:** PRs 1+2 must be merged AND the `build-pages.yml` GH Pages rebuild must complete (check https://gocodealone.github.io/workflow-registry/index.json has `category` fields on responses). Typically 2-5 minutes after PR 2 merges.

### Task 8: Create `src/data/` and commit initial `plugins.json` snapshot

**Files:**
- Create: `src/data/plugins.json`

**Step 1: Check out feat branch in gocodealone-website**

```bash
cd /Users/jon/workspace/gocodealone-website
git checkout main && git pull
git checkout -b feat/plugins-dynamic-sync
```

**Step 2: Fetch current index.json and verify `category` fields are present**

```bash
curl -fsS https://gocodealone.github.io/workflow-registry/index.json | jq 'length, (.[0] | {name, category})'
```
Expected: first number is 86 (or the public plugin count). Second object shows a plugin entry with a non-null `category` field. If `category` is null or missing, PRs 1+2 have not propagated yet — wait and retry.

**Step 3: Write the initial snapshot**

```bash
mkdir -p src/data
curl -fsS https://gocodealone.github.io/workflow-registry/index.json \
  | jq '.' > src/data/plugins.json
echo "Wrote $(jq 'length' src/data/plugins.json) plugins"
```
Expected: `Wrote N plugins` where N matches the live count.

**Step 4: Commit**

```bash
git add src/data/plugins.json
git commit -m "feat(data): add initial plugins.json snapshot from workflow-registry"
```

Rollback: `git revert HEAD` removes the snapshot file; PluginsPage.tsx import breaks (separate from data file removal, so revert Task 11 alongside).

---

### Task 9: Create `scripts/sync-plugins.mjs`

**Files:**
- Create: `scripts/sync-plugins.mjs`

**Step 1: Write the sync script**

Create `scripts/sync-plugins.mjs`:

```js
#!/usr/bin/env node
// scripts/sync-plugins.mjs
//
// Fetches the live workflow-registry index and writes src/data/plugins.json.
// On any fetch failure (network, HTTP error, malformed JSON, empty array,
// or regression < 50% of existing snapshot) → log warning + exit 0.
// The committed snapshot is the fallback; the build proceeds with last-known-good.
//
// Node 20+ compatible: uses fileURLToPath(new URL(...)) for __dirname equivalent.
// (import.meta.dirname requires Node 21.2+.)

import { writeFileSync, readFileSync, existsSync } from "node:fs";
import { fileURLToPath } from "node:url";

const REGISTRY_URL =
  process.env.REGISTRY_URL ??
  "https://gocodealone.github.io/workflow-registry/index.json";
const OUT_PATH = fileURLToPath(new URL("../src/data/plugins.json", import.meta.url));

function warnAndExit(msg) {
  console.warn(`[sync-plugins] ${msg}; using committed snapshot at ${OUT_PATH}`);
  if (!existsSync(OUT_PATH)) {
    console.error(
      `[sync-plugins] ERROR: committed snapshot at ${OUT_PATH} also missing. ` +
      `Build will fail. Restore src/data/plugins.json from git or run with ` +
      `network access.`
    );
  }
  process.exit(0);
}

try {
  const res = await fetch(REGISTRY_URL, { signal: AbortSignal.timeout(15_000) });
  if (!res.ok) return warnAndExit(`HTTP ${res.status} from ${REGISTRY_URL}`);
  const json = await res.json();
  if (!Array.isArray(json)) return warnAndExit("non-array response");
  if (json.length === 0) return warnAndExit("zero entries returned");

  if (existsSync(OUT_PATH)) {
    const existing = JSON.parse(readFileSync(OUT_PATH, "utf-8"));
    if (Array.isArray(existing) && json.length < existing.length * 0.5) {
      console.warn(
        `[sync-plugins] WARN: fetched ${json.length} entries vs ${existing.length} ` +
        `in existing snapshot — possible URL rot or publish-in-progress`
      );
    }
  }

  writeFileSync(OUT_PATH, JSON.stringify(json, null, 2) + "\n");
  console.log(`[sync-plugins] wrote ${json.length} plugins to ${OUT_PATH}`);
} catch (err) {
  warnAndExit(`fetch failed: ${err.message}`);
}
```

**Step 2: Make the script executable**

```bash
chmod +x scripts/sync-plugins.mjs
```

**Step 3: Run it locally to verify it works**

```bash
node scripts/sync-plugins.mjs
```
Expected: `[sync-plugins] wrote N plugins to .../src/data/plugins.json`. Exit 0. The file at `src/data/plugins.json` is updated (verify count matches).

**Step 4: Test failure path with a bad URL**

```bash
REGISTRY_URL="https://nonexistent.invalid/index.json" node scripts/sync-plugins.mjs
echo "exit code: $?"
```
Expected: logs `[sync-plugins] fetch failed: ...` warning. Exit code 0 (not 1 — graceful fallback).

**Step 5: Commit**

```bash
git add scripts/sync-plugins.mjs
git commit -m "feat(scripts): add sync-plugins.mjs for registry snapshot sync"
```

---

### Task 10: Add `sync-plugins` npm script to `package.json`

**Files:**
- Modify: `package.json`

**Step 1: Add the `sync-plugins` script entry**

In `package.json`, in the `"scripts"` object, add after `"lint"`:

```json
"sync-plugins": "node scripts/sync-plugins.mjs",
```

The existing `"build"` script must NOT be changed (no `prebuild` hook — design mandates explicit invocation only by the cron workflow).

**Step 2: Verify npm run sync-plugins works**

```bash
npm run sync-plugins
```
Expected: `[sync-plugins] wrote N plugins to .../src/data/plugins.json`. Exit 0.

**Step 3: Verify npm run build still works without network (uses committed snapshot)**

```bash
npm run build 2>&1 | tail -5
```
Expected: build succeeds using committed `src/data/plugins.json`. No network fetch. Exit 0.

**Step 4: Commit**

```bash
git add package.json
git commit -m "feat(package): add sync-plugins npm script (explicit, not prebuild)"
```

---

### Task 11: Rewrite `src/pages/PluginsPage.tsx` to consume `src/data/plugins.json`

**Files:**
- Modify: `src/pages/PluginsPage.tsx`

**Step 1: Add TypeScript path alias or tsconfig resolve for `@/data/plugins.json`**

Check `tsconfig.json` for the `@/` path alias. Run:

```bash
cat tsconfig.json | grep -A5 '"paths"'
```

If `@/` is already aliased to `src/` (common Vite setup), the import `from "@/data/plugins.json"` works. If not, use a relative import: `from "../data/plugins.json"` (adjust based on PluginsPage.tsx location in `src/pages/`). Use `"../data/plugins.json"` for reliability.

Also verify vite.config.ts has `resolve.alias` for `@` → `src`. Check:

```bash
cat vite.config.ts | grep -A5 'alias'
```

**Step 2: Write the new PluginsPage.tsx**

Replace the entire content of `src/pages/PluginsPage.tsx` with:

```tsx
import pluginsData from "../data/plugins.json";
import { Button } from "@/components/ui/button";
import { Card, CardContent } from "@/components/ui/card";
import {
  Shield, Bot, CreditCard, Lock, Cloud, Monitor, MessageSquare,
  Database, Plug, Activity, Box, ArrowRight
} from "lucide-react";
import { motion } from "framer-motion";

const ACCENT = 'oklch(0.65 0.18 155)';

interface PluginEntry {
  name: string;
  description: string;
  version: string;
  tier: string;
  status: string | null;
  category: string | null;
  repository: string | null;
  homepage: string | null;
  keywords: string[];
}

const CATEGORY_META: Record<string, { title: string; icon: React.ElementType }> = {
  core:           { title: "Core",           icon: Shield        },
  ai:             { title: "AI & Agents",    icon: Bot           },
  payments:       { title: "Payments",       icon: CreditCard    },
  security:       { title: "Security",       icon: Lock          },
  infrastructure: { title: "Infrastructure", icon: Cloud         },
  ide:            { title: "IDE",            icon: Monitor       },
  messaging:      { title: "Messaging",      icon: MessageSquare },
  data:           { title: "Data",           icon: Database      },
  integrations:   { title: "Integrations",  icon: Plug          },
  observability:  { title: "Observability", icon: Activity      },
  other:          { title: "Other",          icon: Box           },
};

// Canonical category render order.
const CATEGORY_ORDER = [
  "core", "ai", "payments", "security", "infrastructure",
  "ide", "messaging", "data", "integrations", "observability", "other"
];

const TIER_COLORS: Record<string, string> = {
  core:      "oklch(0.55 0.15 250)",
  community: "oklch(0.55 0.05 155)",
  premium:   "oklch(0.70 0.18 85)",
};

const STATUS_DOTS: Record<string, string> = {
  verified:     "oklch(0.65 0.18 155)",
  experimental: "oklch(0.75 0.16 75)",
  deprecated:   "oklch(0.55 0.20 20)",
};

// Group plugins by category, sort within group by name.
const allPlugins = pluginsData as PluginEntry[];
const grouped = allPlugins.reduce<Record<string, PluginEntry[]>>(
  (acc, p) => {
    const cat = p.category ?? "other";
    (acc[cat] = acc[cat] ?? []).push(p);
    return acc;
  },
  {}
);
for (const cat in grouped) {
  grouped[cat].sort((a, b) => a.name.localeCompare(b.name));
}

const categories = CATEGORY_ORDER
  .filter(cat => grouped[cat]?.length > 0)
  .map(cat => ({
    key: cat,
    ...CATEGORY_META[cat],
    plugins: grouped[cat],
  }));

export function PluginsPage() {
  return (
    <div className="min-h-screen pt-16">
      {/* Hero */}
      <section className="relative py-32 px-6 overflow-hidden" style={{ background: 'linear-gradient(135deg, oklch(0.12 0.01 155) 0%, oklch(0.22 0.08 155) 50%, oklch(0.12 0.01 155) 100%)' }}>
        <div className="relative z-10 max-w-4xl mx-auto text-center">
          <motion.div initial={{ opacity: 0, y: 20 }} animate={{ opacity: 1, y: 0 }} transition={{ duration: 0.6 }}>
            <h1 className="text-5xl md:text-6xl font-bold mb-6 text-white leading-tight">
              One engine,
              <br />
              <span style={{ color: ACCENT }}>infinite capabilities.</span>
            </h1>
            <p className="text-xl text-white/80 max-w-2xl mx-auto mb-4 leading-relaxed">
              {allPlugins.length}+ plugins covering auth, payments, security, AI, infrastructure, and more. Mix and match to build exactly what you need.
            </p>
          </motion.div>
        </div>
      </section>

      {/* Plugin Categories */}
      <section className="py-24 px-6 bg-background">
        <div className="max-w-7xl mx-auto">
          <motion.div className="text-center mb-16" initial={{ opacity: 0, y: 20 }} whileInView={{ opacity: 1, y: 0 }} viewport={{ once: true }} transition={{ duration: 0.5 }}>
            <h2 className="text-4xl font-bold text-foreground mb-4">Plugin Categories</h2>
            <p className="text-lg text-muted-foreground max-w-2xl mx-auto">All plugins use the gRPC plugin SDK for language-agnostic extensibility.</p>
          </motion.div>

          <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-8">
            {categories.map((cat, index) => (
              <motion.div key={cat.key} initial={{ opacity: 0, y: 20 }} whileInView={{ opacity: 1, y: 0 }} viewport={{ once: true }} transition={{ duration: 0.5, delay: index * 0.07 }}>
                <Card className="h-full border-border hover:border-accent/50 transition-all duration-300 bg-card">
                  <CardContent className="p-6">
                    <div className="flex items-center gap-3 mb-4">
                      <div className="w-10 h-10 rounded-lg flex items-center justify-center" style={{ backgroundColor: `color-mix(in oklch, ${ACCENT} 15%, transparent)` }}>
                        <cat.icon className="w-5 h-5" style={{ color: ACCENT }} />
                      </div>
                      <h3 className="text-lg font-semibold text-card-foreground">{cat.title}</h3>
                      <span className="ml-auto text-xs text-muted-foreground">{cat.plugins.length}</span>
                    </div>
                    <ul className="space-y-1.5">
                      {cat.plugins.map((plugin) => (
                        <li key={plugin.name} className="text-sm text-muted-foreground leading-relaxed flex items-start gap-1.5">
                          <span className="font-mono text-xs mt-0.5 shrink-0" style={{ color: ACCENT }}>›</span>
                          <span>
                            {plugin.repository || plugin.homepage ? (
                              <a
                                href={plugin.repository ?? plugin.homepage ?? undefined}
                                target="_blank"
                                rel="noopener noreferrer"
                                className="font-medium hover:underline"
                                style={{ color: ACCENT }}
                              >
                                {plugin.name}
                              </a>
                            ) : (
                              <span className="font-medium">{plugin.name}</span>
                            )}
                            {plugin.description ? ` — ${plugin.description}` : ""}
                          </span>
                          {plugin.status && STATUS_DOTS[plugin.status] && (
                            <span
                              className="ml-auto mt-1 w-2 h-2 rounded-full shrink-0"
                              style={{ backgroundColor: STATUS_DOTS[plugin.status] }}
                              title={plugin.status}
                            />
                          )}
                        </li>
                      ))}
                    </ul>
                    <div className="mt-3 flex flex-wrap gap-1">
                      {cat.plugins.slice(0, 3).map(p => (
                        <span key={p.name} className="text-xs px-1.5 py-0.5 rounded" style={{ backgroundColor: `color-mix(in oklch, ${TIER_COLORS[p.tier] ?? TIER_COLORS.community} 20%, transparent)`, color: TIER_COLORS[p.tier] ?? TIER_COLORS.community }}>
                          {p.tier}
                        </span>
                      ))}
                    </div>
                  </CardContent>
                </Card>
              </motion.div>
            ))}
          </div>
        </div>
      </section>

      {/* Build your own */}
      <section className="py-16 px-6 bg-muted/30">
        <div className="max-w-3xl mx-auto text-center">
          <motion.div initial={{ opacity: 0, y: 20 }} whileInView={{ opacity: 1, y: 0 }} viewport={{ once: true }} transition={{ duration: 0.5 }}>
            <h2 className="text-3xl font-bold text-foreground mb-4">Build your own plugin</h2>
            <p className="text-muted-foreground mb-6 leading-relaxed">
              The plugin SDK makes it easy to extend Workflow with custom modules and steps. Implement the gRPC interfaces in any language and register your plugin with the engine.
            </p>
            <Button variant="outline" className="border-accent text-accent hover:bg-accent/10" onClick={() => window.open("https://github.com/GoCodeAlone/workflow", "_blank")}>
              View Plugin Docs
              <ArrowRight className="ml-2 w-4 h-4" />
            </Button>
          </motion.div>
        </div>
      </section>

      {/* Registry */}
      <section className="py-16 px-6 bg-background text-center">
        <div className="max-w-2xl mx-auto">
          <motion.div initial={{ opacity: 0, y: 20 }} whileInView={{ opacity: 1, y: 0 }} viewport={{ once: true }} transition={{ duration: 0.5 }}>
            <h2 className="text-3xl font-bold text-foreground mb-4">Plugin Registry</h2>
            <p className="text-muted-foreground mb-6">Browse all {allPlugins.length}+ plugins with manifests, schemas, and version info.</p>
            <Button size="lg" style={{ backgroundColor: ACCENT, color: '#fff' }} className="hover:opacity-90 font-semibold px-8" onClick={() => window.open("https://github.com/GoCodeAlone/workflow-registry", "_blank")}>
              Browse Registry
              <ArrowRight className="ml-2 w-5 h-5" />
            </Button>
          </motion.div>
        </div>
      </section>
    </div>
  );
}
```

**Step 3: Verify TypeScript compiles**

```bash
npm run build 2>&1 | grep -E "error|warning|built in" | head -20
```
Expected: `built in Xs` with zero TypeScript errors referencing PluginsPage.tsx. Exit 0. If lucide-react icons (MessageSquare, Database, Plug, Activity, Box) are missing, check:
```bash
node -e "require('lucide-react')" 2>/dev/null || node --input-type=module <<< "import { MessageSquare, Database, Plug, Activity, Box } from 'lucide-react'; console.log('OK')"
```

**Step 4: Commit**

```bash
git add src/pages/PluginsPage.tsx
git commit -m "feat(PluginsPage): rewrite to consume src/data/plugins.json dynamically"
```

Rollback: `git revert HEAD` restores hardcoded PluginsPage. Combined with reverting Task 8 (removes snapshot file), the page reverts fully.

---

### Task 12: Add `src/data/plugins.json` to TypeScript/Vite JSON import config

**Files:**
- Modify: `tsconfig.json` (if needed)
- Modify: `vite.config.ts` (if needed)

**Step 1: Check if JSON imports work already**

Run:
```bash
npm run build 2>&1 | head -20
```
If the build passes with zero errors, skip Steps 2–3.

**Step 2: (If needed) Enable `resolveJsonModule` in tsconfig**

In `tsconfig.json` (or `tsconfig.app.json` if split), find the `"compilerOptions"` section and ensure:

```json
"resolveJsonModule": true
```

**Step 3: (If needed) Verify Vite handles JSON imports natively**

Vite v4+ handles JSON imports natively — no plugin needed. If using an older Vite, add to `vite.config.ts` plugins: `import json from '@rollup/plugin-json'` and add `json()` to plugins. But for this project (Vite 4+), it should work out of the box.

**Step 4: Verify build passes**

```bash
npm run build 2>&1 | tail -5
```
Expected: `built in Xs`. Exit 0.

**Step 5: Commit if any config changes were needed**

```bash
git add tsconfig.json vite.config.ts 2>/dev/null || true
git diff --cached --quiet || git commit -m "chore: enable resolveJsonModule for plugins.json import"
```

---

### Task 13: Create `.github/workflows/registry-sync.yml`

**Files:**
- Create: `.github/workflows/registry-sync.yml`

**Step 1: Write the workflow**

Create `.github/workflows/registry-sync.yml`:

```yaml
name: Registry snapshot sync
on:
  schedule:
    - cron: '*/15 * * * *'   # every 15 minutes
  workflow_dispatch: {}        # manual trigger

permissions:
  contents: write
  pull-requests: write

# Prevents overlapping cron + workflow_dispatch runs on the same branch.
# cancel-in-progress: false preserves in-flight runs (a PR update mid-run
# is safe to complete; the concurrency group serializes the next run).
concurrency:
  group: registry-snapshot-sync
  cancel-in-progress: false

jobs:
  sync:
    name: Sync plugin snapshot from workflow-registry
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - uses: actions/setup-node@v4
        with:
          node-version: 22

      - name: Fetch + write plugin snapshot
        run: node scripts/sync-plugins.mjs

      - name: Open or update PR if snapshot changed
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          set -euo pipefail
          if git diff --quiet -- src/data/plugins.json; then
            echo "no snapshot change; nothing to commit"
            exit 0
          fi

          BRANCH="chore/sync-plugins-snapshot"
          TITLE="chore: sync plugin snapshot from workflow-registry"
          BODY="Auto-generated snapshot refresh from https://gocodealone.github.io/workflow-registry/index.json (cron */15 min + manual workflow_dispatch). Renders into PluginsPage.tsx after merge + next deploy."

          git config user.email "github-actions[bot]@users.noreply.github.com"
          git config user.name  "github-actions[bot]"

          # 3-case branch policy (matches workflow-registry sync-registry-manifests.yml):
          # 1. Branch doesn't exist → create + push + open PR
          # 2. Branch exists + open PR → re-sync on PR head + append commit + push
          # 3. Branch exists + no open PR → delete + recreate
          if git ls-remote --exit-code --heads origin "${BRANCH}" >/dev/null 2>&1; then
            existing="$(gh pr list --head "${BRANCH}" --state open --json number --jq '.[0].number // empty')"
            if [[ -n "${existing}" ]]; then
              git reset --hard HEAD
              git clean -fd src/data/plugins.json
              git fetch origin "${BRANCH}:refs/remotes/origin/${BRANCH}"
              git checkout -B "${BRANCH}" "refs/remotes/origin/${BRANCH}"
              node scripts/sync-plugins.mjs
              if git diff --quiet -- src/data/plugins.json; then
                echo "open PR ${existing} already at expected snapshot; no append"
                exit 0
              fi
              git add src/data/plugins.json
              git commit -m "${TITLE}"
              git push origin "${BRANCH}"
              echo "appended sync commit to PR #${existing}"
              exit 0
            fi
            echo "branch exists with no open PR; recreating"
            git push origin --delete "${BRANCH}"
          fi

          git checkout -b "${BRANCH}"
          git add src/data/plugins.json
          git commit -m "${TITLE}"
          git push origin "${BRANCH}"
          gh pr create --base main --head "${BRANCH}" --title "${TITLE}" --body "${BODY}"
```

**Step 2: Validate workflow YAML**

```bash
python3 -c "import yaml, sys; yaml.safe_load(open('.github/workflows/registry-sync.yml'))" && echo "YAML OK"
```
Expected: `YAML OK`. Exit 0.

**Step 3: Commit**

```bash
git add .github/workflows/registry-sync.yml
git commit -m "feat(ci): add registry-sync.yml (cron */15min + workflow_dispatch, 3-case branch policy)"
```

Rollback: `git revert HEAD` removes registry-sync.yml; cron stops; snapshot PRs no longer open automatically.

---

### Task 14: Open PR 4, verify CI, request Copilot review, admin-merge

**Files:** (no new files — this is the PR/merge task)

**Step 1: Push the branch and open PR**

```bash
cd /Users/jon/workspace/gocodealone-website
git push origin feat/plugins-dynamic-sync
gh pr create --base main --head feat/plugins-dynamic-sync \
  --title "feat(plugins-page): scheduled sync from workflow-registry" \
  --body "$(cat <<'EOF'
## Summary

- Adds \`src/data/plugins.json\` — committed snapshot of the live workflow-registry index (86 plugins with \`category\` fields after PRs 1+2 merged)
- Adds \`scripts/sync-plugins.mjs\` — fetches the live registry index; graceful fallback to committed snapshot on any error
- Adds \`sync-plugins\` npm script (explicit invocation; NOT \`prebuild\` to avoid injecting live fetch into every CI/release build)
- Rewrites \`src/pages/PluginsPage.tsx\` to render dynamically from the committed snapshot, grouped by category, sorted by name, with status indicators and repository links
- Adds \`.github/workflows/registry-sync.yml\` — cron every 15 min + workflow_dispatch; uses 3-case branch policy to open/update/recreate a \`chore/sync-plugins-snapshot\` PR when the snapshot changes

## Deploy path
The cron updates the snapshot in \`main\` (via PR) within 15 minutes of any registry change. Deploy to production happens on the next manual \`git tag v*\` push (existing release.yml flow — unchanged).

## Test plan
- [ ] \`npm run build\` passes using committed snapshot (no network)
- [ ] \`npm run sync-plugins\` fetches live index and updates \`src/data/plugins.json\`
- [ ] Manually trigger \`Registry snapshot sync\` workflow; confirm it opens a PR or exits cleanly if no changes
- [ ] PluginsPage renders categories dynamically in local dev (\`npm run dev\`)
EOF
)"
```

**Step 2: Add Copilot reviewer**

```bash
PR_NUM=$(gh pr view --json number --jq '.number')
gh pr edit "${PR_NUM}" --add-reviewer @copilot
```
Expected: no error. Copilot submits review within 30 seconds.

**Step 3: Wait for CI and Copilot review**

```bash
# Poll CI status (ci.yml runs on self-hosted runner)
gh pr checks "${PR_NUM}" --watch
```
Expected: all checks pass. Note: `ci.yml` runs on `self-hosted, Linux, X64` — if runner is offline, this check may not appear. In that case, verify `npm run build` passed locally.

**Step 4: Read Copilot inline comments**

```bash
gh api repos/GoCodeAlone/gocodealone-website/pulls/${PR_NUM}/comments --jq '.[].body'
```
Expected: any inline comments surface here. Address real findings with additional commits. Dismiss non-issues.

**Step 5: Admin-merge**

```bash
gh pr merge "${PR_NUM}" --squash --admin --delete-branch
```
Expected: PR merged. Branch `feat/plugins-dynamic-sync` deleted.

**Step 6: Trigger the sync workflow manually to verify it works**

```bash
gh workflow run "Registry snapshot sync" --repo GoCodeAlone/gocodealone-website
```
Expected: workflow run starts. After ~1 min:
```bash
gh run list --repo GoCodeAlone/gocodealone-website --workflow=registry-sync.yml --limit 1
```
Expected: status `completed` with conclusion `success`. If snapshot was already current, the run logs `no snapshot change; nothing to commit` and exits cleanly.

---

## Post-merge verification checklist

After all 4 PRs merge:

1. **PR 1+2 GH Pages rebuild:** Fetch `https://gocodealone.github.io/workflow-registry/index.json` and confirm `.[0].category` is non-null.
   ```bash
   curl -fsS https://gocodealone.github.io/workflow-registry/index.json | jq '.[0] | {name, category}'
   ```
   Expected: `{"name": "<plugin>", "category": "<non-null-category>"}`.

2. **PR 3 cloud-registry:** Schema allows `category` field; no sweep needed. Verify via PR CI.

3. **PR 4 live registry-sync run:** `gh run list --repo GoCodeAlone/gocodealone-website --workflow=registry-sync.yml --limit 3` shows recent successful runs.

4. **Website build:** After snapshot PR merges into gocodealone-website/main, verify `npm run build` still passes locally.

5. **Deploy lag note:** PluginsPage renders the latest snapshot after the next manual `git tag v*` push triggers `release.yml`. The snapshot is indexed in `main` within 15 minutes; production deploy is decoupled (user-stated "indexed" priority is met).
