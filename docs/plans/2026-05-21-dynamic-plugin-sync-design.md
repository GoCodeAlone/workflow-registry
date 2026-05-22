# Dynamic Plugin Sync — gocodealone-website ← workflow-registry

**Date:** 2026-05-21
**Scope:** Make `gocodealone-website`'s `PluginsPage.tsx` reflect `workflow-registry` plugin list dynamically. Adds `category` field to manifest schema; sweeps existing manifests with category assignments; adds a scheduled workflow in gocodealone-website that fetches the live registry index and commits the snapshot when it changes; rewrites PluginsPage to consume the snapshot. (Round-1 adversarial review pivoted off cross-repo dispatch — see Round-1 fixes section.)
**User direction (verbatim):** "Use superpower skills. Option B, so we can ensure the results are indexed. Add a category field to the manifest. Then perform a registry sweep. Proceed autonomously until complete."

## Goal

Today `PluginsPage.tsx` is a hardcoded list of 6 categories × ~20 plugin strings. After this design lands: plugin metadata (categorized by `category` field on the manifest) flows from the upstream plugin repo → workflow-registry → GH Pages index.json → committed website snapshot → rendered page.

**Indexing lag target (user priority):** registry snapshot in `gocodealone-website/main` reflects plugin manifest changes within ~15 minutes (cron interval). **Deploy lag** (snapshot in main → live website) follows the website's existing release.yml tag-push flow; deploys land on the next manual tag push. This separation is the round-1 pivot — the dispatch-driven sub-5-minute lag idea hit two Critical findings (deploy path TBD; cross-repo token unverified), so the design retreats to a cron-based indexing model that meets the user's stated "indexed" priority without requiring the deploy pipeline rework.

## Architecture (round-1 revised)

```
plugin tag (already wired via G1+G2)
   ↓ repository_dispatch [plugin-release]
workflow-registry  sync-registry-manifests.yml      (G2, already wired)
   ↓ merge to main
workflow-registry  build-pages.yml                  (unchanged from existing)
   └─ scripts/build-index.sh → v1/index.json with new `category` field (PR 1+2)
      ↓ deploy to GH Pages

(NO cross-repo dispatch from workflow-registry — round-1 C-1 + C-2 fix)

gocodealone-website  .github/workflows/registry-sync.yml  (PR 4 — new, cron-driven)
   triggers: schedule cron */15 minutes + workflow_dispatch
   ├─ run scripts/sync-plugins.mjs (fetches /index.json + writes src/data/plugins.json)
   ├─ if git diff --quiet src/data/plugins.json: exit clean (no change)
   └─ else: commit + push to main (file-only change, no tag, no release)
      ↓ ci.yml triggers on push (lint + build only, no deploy — that's release.yml's job on tag push)

(Deploy to live website happens on next manual `git tag v*` push that fires release.yml.
The snapshot is INDEXED in main as soon as cron picks it up; deploy is decoupled.
"Indexed" was the user-stated priority; sub-5-min deploy lag was author interpretation.)

      ↓ prebuild: scripts/sync-plugins.mjs                 (PR 4)
         ├─ fetch https://gocodealone.github.io/workflow-registry/index.json
         ├─ write src/data/plugins.json (overwrites committed snapshot)
         └─ if fetch fails: log warning + exit 0 (last-committed snapshot is the fallback)
      ↓ src/pages/PluginsPage.tsx imports src/data/plugins.json (PR 4)
         ├─ groups by `category`
         ├─ sorts within group by `name`
         └─ renders cards with name, description, version, tier, status, repository link
```

## PR layout (4 PRs, sequenced — round-1 dropped PR 4 cross-repo dispatch)

| # | Repo | Title | Notes |
|---|---|---|---|
| 1 | workflow-registry | feat(schema): add `category` enum + project to v1/index.json | Schema change + G3 projection + drift-guard markers + test-build-index assertions + fixture updates. Existing manifests without `category` validate fine (optional field). |
| 2 | workflow-registry | feat(registry): categorize all plugin manifests | Sweep ~80 manifests. Explicit dir-name → category mapping (round-1 I-1 expanded the heuristic with 25+ additional mappings). Single large diff but mechanical. |
| 3 | workflow-cloud-registry | feat(schema): add `category` enum (parity) | Schema-only port; no value sweep. Private plugins don't surface to public site. |
| 4 | gocodealone-website | feat(plugins-page): scheduled sync from workflow-registry | `scripts/sync-plugins.mjs` + `prebuild` npm script + `PluginsPage.tsx` rewrite + `.github/workflows/registry-sync.yml` (cron */15min + workflow_dispatch) that commits the snapshot if changed. Initial `src/data/plugins.json` snapshot committed for fallback. NO cross-repo dispatch; NO `repo_dispatch_token` consumed. |

PRs 1 + 2 could merge in either order: PR 1 enables the field, PR 2 populates it. Schema accepts manifests with or without `category` so PRs are independently revertible.

## Schema change

`schema/registry-schema.json` adds (top-level property, optional):

```json
"category": {
  "type": "string",
  "enum": ["core", "ai", "payments", "security", "infrastructure", "ide",
           "messaging", "data", "integrations", "observability", "other"],
  "description": "Coarse-grained category for UI grouping (e.g. the gocodealone-website plugins page). Optional — manifests without a category render under 'other'."
}
```

Category taxonomy (10 + "other") — round-1 revised assignments:

| Category | Plugins (dir name in `plugins/` under workflow-registry) |
|---|---|
| `core` | admin, auth, authz, authz-ui, bento, pipelinesteps, cms, approval, rooms, template, platform, marketplace, infra (engine-level), http, api, statemachine, scheduler, configprovider, openapi, ci-generator, cicd, license, compute, modularcompat, messaging-core, product-capture, ratchet, cloud-ui |
| `ai` | agent, mcp, ai |
| `payments` | payments |
| `security` | waf, security, sandbox, supply-chain, data-protection, security-scanner, policy, audit-chain (security-first per round-1 acknowledgment) |
| `infrastructure` | aws, gcp, azure, digitalocean, tofu, namecheap, hover, k8s, kubernetes-deploy, eventbus (IaC-provisioning primary — round-1 I-2 fix), gameserver, cloud, actors |
| `ide` | (reserved — no current plugins) |
| `messaging` | slack, discord, twilio, turnio, websocket, ws-auth, broker, dlq |
| `data` | vectorstore, datastores, storage, eventstore, timeline, atlas-migrate, data-engineering |
| `integrations` | github, gitlab, salesforce, monday, openlms, launchdarkly, okta, steam, teams, sso, analytics, featureflags, erp, crm |
| `observability` | datadog (round-1 M-1 fix), audit |
| `other` | (fallback for unclear; ideally empty after sweep) |

Each plugin gets exactly one category. Two intentional taxonomy calls:

- **`eventbus` → `infrastructure`** (not messaging): the plugin's primary use-case is IaC-provisioning durable cluster infrastructure (NATS/Kafka/Kinesis brokers). The `messaging` category is reserved for client-side integration plugins (slack/discord/twilio/etc) that produce/consume from existing brokers.
- **`audit-chain` → `security`** (not observability): hash-chained tamper-evident audit logging is a compliance/security primary, with observability as secondary. The plain `audit` plugin (general logging) lives in `observability`.

## G3 allowlist projection (PR 1)

In `scripts/build-index.sh`, after `status:`, add:

```jq
status:           (.status // null),
category:         (.category // null),
```

Drift-guard markers:

```bash
# G3-include: category
```

`tests/test-build-index.sh` adds an assertion that foo-iac fixture (which gets `"category": "infrastructure"`) surfaces it:

```bash
assert_jq "foo-iac category" '.[] | select(.name=="foo-iac") | .category' '"infrastructure"'
```

`tests/test-schema-allowlist-coverage.sh` auto-detects the new schema field via existing schema_props traversal; the new `G3-include: category` marker satisfies it without script change.

## Manifest sweep (PR 2)

Round-1 I-1 fix: replace the heuristic-only approach with an **explicit dir-name → category mapping table** authored directly in the categorization script. The table covers every plugin dir under `plugins/` AS-OF the round-1 inventory. New plugins added after this PR will surface as "unmapped" via the script's dry-run mode and require an explicit table addition (caught in CI via a check that flags `category: null` in any plugin's manifest).

Workflow:

1. `scripts/categorize-manifests.sh --dry-run` prints which plugins would get which category, listing any unmapped ones EXPLICITLY. Author runs this locally first, tunes the mapping table, re-runs until output is clean.
2. `scripts/categorize-manifests.sh --apply` writes `"category": "<value>"` into each `plugins/<name>/manifest.json` per the mapping table.
3. Commit + PR.

The mapping table lives as a constant array in the bash script — one mapping per line, easy to read in the PR diff:

**CATEGORY_MAP authored against the actual 86-dir plugin inventory** (round-2 I-1 fix — verified via `gh api repos/GoCodeAlone/workflow-registry/contents/plugins --jq '.[]|select(.type=="dir")|.name'`). One entry per real dir; no dead keys:

```bash
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
```

86 entries matching 86 real plugin dirs. Round-1's draft had dead keys (data-protection, datalake, gameserver, sandbox, supply-chain, waf, etc — these are plugin REPO names but not dir names in the registry; the dirs are namespaced differently). Round-2 I-1 fix: walked actual `plugins/` directory and authored 1:1 mapping. No omissions, no dead keys.

If a plugin dir is added to the registry without a matching CATEGORY_MAP entry → script writes `category: null` → CI assertion fails ("plugin <name> missing category in CATEGORY_MAP — add it to scripts/categorize-manifests.sh"). Forces future plugin additions to consciously assign a category.

**Round-3 I-3 fix — wire the CI assertion explicitly.** Schema validation allows `category: null` (the field is optional in the JSON schema). To actually enforce category coverage on PRs, PR 2 ALSO adds a new validate.yml step:

```yaml
- name: Validate every plugin has a category assigned
  run: |
    bash scripts/categorize-manifests.sh --check
```

Where `categorize-manifests.sh --check` mode reads each `plugins/*/manifest.json` and exits non-zero if any has `.category` missing or null. Without this wiring the assertion only exists in the design narrative; the round-3 fix makes it real.

## Build-pages dispatch (DROPPED — round-1 C-1 + C-2 fix)

Originally PR 4 of the 5-PR plan. Reviewer surfaced two Critical findings:

- **C-1 (deploy path TBD):** gocodealone-website's release.yml triggers only on `push: tags: ["v*"]` and packages a tarball into a GH release. A dispatch-driven `registry-sync.yml` cannot trigger a deploy without either auto-tagging (noisy) or refactoring release.yml into a reusable `workflow_call`. The reusable-workflow refactor was out of scope for the autonomous mandate.
- **C-2 (token unverified):** `secrets.repo_dispatch_token` was assumed shared from G1, but G1 wires the token INTO workflow-registry, not OUT FROM it. workflow-registry has no outbound dispatch secret today. Adding one requires a separate infra-secret PR not in the original scope.

**Pivot:** drop the dispatch entirely. Replace with a scheduled cron job IN gocodealone-website (PR 4 in the revised plan) that runs `sync-plugins.mjs`, commits the snapshot if changed, and pushes to main. The website's existing release.yml continues to handle deploys on manual tag push (unchanged). The user's stated priority — "ensure results are indexed" — is met: the data lands in `main` within 15 minutes of any registry change. Sub-5-minute deploy lag (author's gloss) is sacrificed; "indexed" (user's actual word) is preserved.

## Website prebuild + cron sync (PR 4 — formerly PR 5)

`scripts/sync-plugins.mjs`:

```js
#!/usr/bin/env node
// Fetches the live registry index and writes src/data/plugins.json.
// On any fetch failure (network, HTTP error, malformed JSON, empty array,
// or fewer entries than the existing snapshot — likely a publish-in-progress
// state) → log a clear warning + exit 0. The committed snapshot is the
// fallback; the build proceeds with last-known-good.
//
// Round-1 M-3 fix: use fileURLToPath(new URL(...)) for Node 20 compat
// (import.meta.dirname requires Node 21.2+).

import { writeFileSync, readFileSync, existsSync } from "node:fs";
import { fileURLToPath } from "node:url";

const REGISTRY_URL =
  process.env.REGISTRY_URL ??
  "https://gocodealone.github.io/workflow-registry/index.json";
const OUT_PATH = fileURLToPath(new URL("../src/data/plugins.json", import.meta.url));

function warnAndExit(msg) {
  console.warn(`[sync-plugins] ${msg}; using committed snapshot at ${OUT_PATH}`);
  // Round-1 M-2: if the committed snapshot is also missing, the build
  // would fail downstream. Emit a louder warning so the failure mode is
  // obvious in logs.
  if (!existsSync(OUT_PATH)) {
    console.error(
      `[sync-plugins] ERROR: committed snapshot at ${OUT_PATH} also missing. ` +
      `Build will fail. Restore src/data/plugins.json from git or run with ` +
      `network access.`
    );
    // Still exit 0 so the build attempts itself (CI logs will show the import
    // error from PluginsPage.tsx which is more diagnostic).
  }
  process.exit(0);
}

try {
  const res = await fetch(REGISTRY_URL, { signal: AbortSignal.timeout(15_000) });
  if (!res.ok) return warnAndExit(`HTTP ${res.status} from ${REGISTRY_URL}`);
  const json = await res.json();
  if (!Array.isArray(json)) return warnAndExit("non-array response");
  if (json.length === 0) return warnAndExit("zero entries returned");

  // Round-1 I-3 partial mitigation: if the fetched index has fewer entries
  // than the existing snapshot, warn loudly (URL-rot or publish-in-progress).
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

`package.json` `scripts` (round-2 I-2 fix — no `prebuild`):

```json
"sync-plugins": "node scripts/sync-plugins.mjs",
"build": "tsc -b --noCheck && vite build"
```

The `sync-plugins` script is explicit, NOT auto-invoked by `npm run build`. This means:
- Local + CI builds use the committed `src/data/plugins.json` unchanged.
- The `release.yml` tag-triggered build deploys the snapshot that was committed in main (no surprise live fetch).
- Only the cron workflow runs `npm run sync-plugins` explicitly.

Round-1 used `prebuild`, which would have made every `npm run build` invocation (incl. CI on every PR + release builds) silently refetch the live index and potentially deploy a different snapshot than committed. Round-2 I-2 fix decouples this.

`src/data/plugins.json` (committed snapshot of current index.json at PR-merge time).

`src/pages/PluginsPage.tsx` rewrite:

```tsx
import pluginsData from "@/data/plugins.json";

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

const CATEGORY_META = {
  core:           { title: "Core",           icon: Shield      },
  ai:             { title: "AI & Agents",    icon: Bot         },
  payments:       { title: "Payments",       icon: CreditCard  },
  security:       { title: "Security",       icon: Lock        },
  infrastructure: { title: "Infrastructure", icon: Cloud       },
  ide:            { title: "IDE",            icon: Monitor     },
  messaging:      { title: "Messaging",      icon: MessageSquare },
  data:           { title: "Data",           icon: Database    },
  integrations:   { title: "Integrations",   icon: Plug        },
  observability:  { title: "Observability",  icon: Activity    },
  other:          { title: "Other",          icon: Box         },
};

// Group plugins by category, sort within group by name.
const grouped = (pluginsData as PluginEntry[]).reduce<Record<string, PluginEntry[]>>(
  (acc, p) => {
    const cat = p.category ?? "other";
    (acc[cat] = acc[cat] ?? []).push(p);
    return acc;
  },
  {}
);
for (const cat in grouped) grouped[cat].sort((a, b) => a.name.localeCompare(b.name));
```

Card renders: name, description, version badge (small), tier badge (color-coded), status indicator (verified=green/experimental=yellow/deprecated=red, omitted if null), repository link.

The hero text "49+ plugins" becomes dynamic: `{pluginsData.length}+ plugins`.

The existing "Browse Registry" CTA at the bottom stays unchanged (points to workflow-registry repo on GitHub).

## Website registry-sync workflow (PR 4 — formerly PR 5)

**Round-2 C-1 fix:** gocodealone-website's main branch has an active ruleset requiring PR + last-push-approval for any change. Direct `git push origin main` from a cron is blocked. Switch to PR-based opening (matches workflow-registry's existing `sync-registry-manifests.yml` pattern for chore/sync-* PRs).

`.github/workflows/registry-sync.yml`:

```yaml
name: Registry snapshot sync
on:
  schedule:
    - cron: '*/15 * * * *'   # every 15 minutes
  workflow_dispatch: {}        # manual trigger

permissions:
  contents: write
  pull-requests: write

# Round-3 fix: concurrency group matches workflow-registry#84 pattern.
# Prevents an overlapping workflow_dispatch from racing the cron-triggered
# run on the same chore/sync-plugins-snapshot branch.
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
          BODY="Auto-generated snapshot refresh from https://gocodealone.github.io/workflow-registry/index.json (cron + manual workflow_dispatch). Renders into PluginsPage.tsx after merge + next deploy."

          git config user.email "github-actions[bot]@users.noreply.github.com"
          git config user.name  "github-actions[bot]"

          # Re-run / existing-branch handling matches the 3-case pattern
          # from workflow-registry#84's sync-registry-manifests.yml:
          # 1. Branch doesn't exist → create + push + open PR
          # 2. Branch exists + open PR → re-sync on PR head + amend commit + push
          # 3. Branch exists + no open PR → delete + recreate
          if git ls-remote --exit-code --heads origin "${BRANCH}" >/dev/null 2>&1; then
            existing="$(gh pr list --head "${BRANCH}" --state open --json number --jq '.[0].number // empty')"
            if [[ -n "${existing}" ]]; then
              # Update existing PR: discard working tree, fetch branch, re-sync onto its head.
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

The PR uses the workflow's default `GITHUB_TOKEN`, which has push access to non-default branches AND can create PRs (via `pull-requests: write` permission). The ruleset blocks direct push to main but not PR creation. Round-3 fix: removed the `gh pr merge --auto` call — the reference `sync-registry-manifests.yml` in workflow-registry doesn't call auto-merge either; the repo's auto-merge configuration (if globally enabled) handles it natively, otherwise the PR awaits review per the user's manual-merge fallback acceptance.

The website's existing `release.yml` (triggered on tag push) handles deploy. After the snapshot PR merges, deploy lands on the next manual tag push — same as today.

## Fields PluginsPage consumes

Beyond the rendering use:

| Field | Use |
|---|---|
| `category` | Group bucket assignment |
| `name` | Card title (dir-name override from G3) |
| `description` | Card body |
| `version` | Small badge |
| `tier` | Color-coded badge (core=blue, community=gray, premium=gold) |
| `status` | Indicator (verified=green dot, experimental=yellow, deprecated=red, null=no indicator) |
| `repository` | "View on GitHub" link |
| `homepage` | Fallback for link if repository null |
| `keywords` | (Optional) chip list for searchable tags — MVP may omit |

Other fields available from index.json are unused for now (`capabilities`, `dependencies`, `iacProvider`, `assets`, `required_secrets`, `source`, `minEngineVersion`). Future iterations can surface them.

## Assumptions (round-1 revised)

| # | Claim | Risk if false |
|---|---|---|
| A1 | `https://gocodealone.github.io/workflow-registry/index.json` is reachable from GitHub Actions runners during the cron sync run (server-side fetch — CORS not relevant). Verified once during design phase. | Build falls back to committed snapshot; warns; ships stale data until next sync. Round-1 I-3 partial fix: sync script warns loudly if fetched entries < 50% of existing snapshot. |
| A2 | (round-1 dropped — cross-repo dispatch no longer used) | n/a |
| A3 | The 10-category enum (+ `other` fallback) covers ~80 current plugins. The explicit dir-name mapping in `scripts/categorize-manifests.sh` is authoritative; new plugins added after PR 2 surface as `category: null` and a CI assertion forces an explicit mapping. | New plugin author writes a manifest, doesn't update the script → CI fails the PR; author adds the mapping. Forcing-function works. |
| A4 | gocodealone-website's existing release.yml deploy path stays unchanged. The cron in registry-sync.yml only updates the snapshot in main; deploys happen on the next manual `git tag v*` push as today. | If user expected sub-5-min deploy lag: design pivot makes that out of scope. User's stated word was "indexed", which is met. |
| A5 | Explicit dir-name → category mapping is the source of truth; no heuristics. Authors maintain the mapping when adding plugins. Round-1 I-1 fix. | Mapping requires manual maintenance; CI assertion catches unmapped plugins immediately. |
| A6 | Adding an optional schema field with a constrained enum does not break any existing manifest validation (manifests without `category` validate; manifests with unknown values rejected by ajv) | If existing manifests had a stray `category` key with non-enum value, validation breaks. Mitigation: PR 1 includes a pre-sweep `ajv validate` pass on all current manifests to catch any pre-existing key. |
| A7 | `secrets.GITHUB_TOKEN` in registry-sync.yml can open + push to a feat branch + create PRs (default for in-repo Actions runs with `pull-requests: write`). | Verified resolved by round-2 C-1 PR-based pattern; the assumption stands. Round-3 cleanup: PR-based flow IS the current design, NOT a Phase 2 option. The direct-push concern (round-1 implicit) was addressed in round-2 by adopting the workflow-registry's sync-registry-manifests.yml 3-case branch policy. |
| A8 | `github-actions[bot]` is on the gocodealone-website main-branch ruleset bypass list OR the repo has auto-merge globally enabled OR a maintainer reviews the bot's PR within the 15-minute indexing window. | If none of the above: snapshot PRs queue waiting for human review; the "indexed in 15 min" goal degrades to "PR opened in 15 min, merged when a human acts." Per user clarification ("as long as the scheduled run can be manually executed, that's fine"), the manual-merge fallback is acceptable. Verification of which case is active happens at PR 4 open; not blocking. |

## Top 3 doubts (round-1 revised)

1. **Category taxonomy chosen unilaterally** — 10 buckets may not match user's mental model exactly. PR 1 (schema only, no semantic impact) is safe to land alone; PR 2 categorization decisions surface in review.
2. **~80 manifest edits in a single sweep PR** = large diff but mechanical. The explicit dir-name mapping (round-1 I-1 fix) is reviewable line-by-line in the script's CATEGORY_MAP table.
3. **Cron lag (15 min) is the new floor on snapshot indexing** — deploy lag is whatever the user's manual release cadence is. User's actual word was "indexed", so the design targets that. If sub-5-min deploy lag re-surfaces as a need, Phase-2 work would refactor release.yml into a workflow_call and chain it from registry-sync.yml on snapshot changes.

## Rollback (round-1 revised — 4 PRs)

Each PR independently revertible:
- PR 1: revert removes `category` from schema; existing manifests stay valid (optional field).
- PR 2: revert removes categorizations from all manifests; G3 projection emits `category: null` for each.
- PR 3: revert removes schema field from cloud-registry; private-registry consumers unaffected.
- PR 4: revert restores hardcoded PluginsPage.tsx + removes prebuild script + drops registry-sync.yml. The cron stops; next deploy reverts to the hardcoded list.

No persistent state, no migrations, no client-side cache to expire.

## Round-3 adversarial review fixes (PASS verdict; pre-implementation cleanups)

Round-3 verdict was PASS with zero Critical + 3 Important findings flagged as pre-implementation document/wiring cleanups:

| Finding | Severity | Resolution |
|---|---|---|
| I-1: A7 narrative stale (described direct-push as MVP + PR-based as Phase 2; reality is PR-based IS the design) | Important (doc) | Rewrote A7 to reflect PR-based flow as the current design; added new A8 for the auto-merge-bypass conditional. |
| I-2: auto-merge bypass exemption unverified | Important | Acknowledged in A8 as "PR opened in 15 min, merged when human acts" fallback per user's "scheduled run can be manually executed" approval. Removed the `gh pr merge --auto` invocation since the reference workflow doesn't use it; repo-level auto-merge config (if enabled) handles it natively. |
| I-3: "CI assertion" for category:null not wired into validate.yml | Important | Added explicit validate.yml step in PR 2: `bash scripts/categorize-manifests.sh --check`. Script's `--check` mode exits non-zero on any plugin missing a category. The forcing-function is now real, not aspirational. |
| M-1: narrative table contradicted CATEGORY_MAP on `data-engineering` | Minor | Fixed narrative table: `data-engineering` is now under `data`; `ratchet` + `cloud-ui` added under `core`. CATEGORY_MAP remains authoritative. |
| Concurrency block missing on registry-sync.yml | Round-3 option 2 | Added `concurrency: group: registry-snapshot-sync, cancel-in-progress: false` matching reference pattern. |

## Round-2 adversarial review fixes

| Finding | Severity | Resolution |
|---|---|---|
| C-1: gocodealone-website main has active ruleset blocking GITHUB_TOKEN direct push | Critical | Switched from `git push origin main` to PR-based commit pattern (matches workflow-registry#84's sync-registry-manifests.yml three-case branch policy). Cron opens/updates `chore/sync-plugins-snapshot` PR; auto-merge attempted; falls back to manual review if disabled. |
| I-1: CATEGORY_MAP missing 8 real plugin dirs + had 14 dead keys | Important | Re-authored CATEGORY_MAP against actual 86-dir inventory (gh api list). All 86 real dirs mapped; no dead keys. |
| I-2: `prebuild` injects live fetch into every CI/release build → snapshot drift between commit and deploy | Important | Renamed npm script from `prebuild` to `sync-plugins` (not auto-invoked). Only the cron workflow runs it explicitly. Local + CI + release builds use the committed snapshot unchanged. |
| M-1: `release.yml` references non-existent `checkout@v5` + `setup-node@v6` | Minor | Pre-existing defect in website's release.yml; flagged for separate fix PR (out of this design's scope). |
| M-2: 50% regression threshold too coarse | Minor | Accepted as round-2 caveat. The committed snapshot is the actual safety net; this is a "WARN" log only, not a fail gate. |

## Round-1 adversarial review fixes

Original design (10-min commit 0d7c9d7b) hit 2 Critical + 3 Important + 3 Minor. Resolutions:

| Finding | Severity | Resolution |
|---|---|---|
| C-1: deploy path TBD | Critical | Dropped cross-repo dispatch entirely. Cron-driven commits in gocodealone-website; deploys remain on the existing manual tag-push flow. Re-targets "indexed" (user's actual word) rather than sub-5-min deploy lag (author's gloss). |
| C-2: `repo_dispatch_token` absent from workflow-registry | Critical | No-op now that dispatch is dropped. Cron uses default `secrets.GITHUB_TOKEN` for the in-repo push. |
| I-1: heuristic coverage gap | Important | Replaced heuristic-only with explicit dir-name → category mapping table in `scripts/categorize-manifests.sh`. CI assertion fails if any plugin has `category: null` after sweep. Forces new plugins to add an explicit mapping. |
| I-2: eventbus → messaging mismatch | Important | Reassigned eventbus → infrastructure (IaC-provisioning primary). Documented in taxonomy table. |
| I-3: GH Pages URL unverified | Important | Sync script now warns loudly if fetched entries < 50% of existing snapshot (suggests URL rot or publish-in-progress). Initial URL verified during design phase. |
| M-1: datadog category | Minor | Reassigned datadog → observability. |
| M-2: prebuild silent fallback if snapshot file missing | Minor | Sync script emits a louder error log if committed snapshot is also missing. Still exits 0 (build attempts and surfaces the import error). |
| M-3: `import.meta.dirname` Node 21.2+ | Minor | Replaced with `fileURLToPath(new URL(...))` for portable Node 18+ compatibility. |

Two findings were Warns (not Findings) — both addressed by acknowledgment:
- Reviewer's Option 1 (cron commit) — adopted as the chosen approach.
- "Single large sweep PR reviewability" — explicit dir-name mapping makes the diff line-by-line reviewable.

## References

- Live index.json: https://gocodealone.github.io/workflow-registry/index.json
- Current PluginsPage.tsx: `src/pages/PluginsPage.tsx` (gocodealone-website)
- G2 dispatch handler: workflow-registry#84 (merged 2026-05-21)
- G3 allowlist projection: workflow-registry#82 (merged 2026-05-21)
- Schema hotfix: workflow-registry#85 (merged 2026-05-21)
- G1 plugin notify sweep: 42 public + 8 private plugin repos (merged 2026-05-21)
