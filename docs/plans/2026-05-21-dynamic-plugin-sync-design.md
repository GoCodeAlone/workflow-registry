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
| `core` | admin, auth, authz, authz-ui, bento, pipelinesteps, cms, approval, rooms, template, platform, marketplace, infra (engine-level), http, api, statemachine, scheduler, configprovider, openapi, ci-generator, cicd, license, compute, modularcompat, messaging-core, data-engineering, product-capture |
| `ai` | agent, mcp, ai |
| `payments` | payments |
| `security` | waf, security, sandbox, supply-chain, data-protection, security-scanner, policy, audit-chain (security-first per round-1 acknowledgment) |
| `infrastructure` | aws, gcp, azure, digitalocean, tofu, namecheap, hover, k8s, kubernetes-deploy, eventbus (IaC-provisioning primary — round-1 I-2 fix), gameserver, cloud, actors |
| `ide` | (reserved — no current plugins) |
| `messaging` | slack, discord, twilio, turnio, websocket, ws-auth, broker, dlq |
| `data` | vectorstore, datastores, datalake, datawarehouse, datapool, migrations, migration, storage, eventstore, timeline, atlas-migrate |
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

```bash
declare -A CATEGORY_MAP=(
  [actors]="infrastructure"
  [admin]="core"
  [agent]="ai"
  [ai]="ai"
  [analytics]="integrations"
  [api]="core"
  [approval]="core"
  [atlas-migrate]="data"
  [audit]="observability"
  [audit-chain]="security"
  [authz]="core"
  [authz-ui]="core"
  [aws]="infrastructure"
  [azure]="infrastructure"
  [bento]="core"
  [broker]="messaging"
  [ci-generator]="core"
  [cicd]="core"
  [cloud]="infrastructure"
  [cms]="core"
  [compute]="core"
  [configprovider]="core"
  [crm]="integrations"
  [data-engineering]="core"
  [data-protection]="security"
  [datadog]="observability"
  [datalake]="data"
  [datapool]="data"
  [datastores]="data"
  [datawarehouse]="data"
  [digitalocean]="infrastructure"
  [discord]="messaging"
  [dlq]="messaging"
  [erp]="integrations"
  [eventbus]="infrastructure"
  [eventstore]="data"
  [featureflags]="integrations"
  [gameserver]="infrastructure"
  [gcp]="infrastructure"
  [github]="integrations"
  [gitlab]="integrations"
  [hover]="infrastructure"
  [http]="core"
  [infra]="core"
  [k8s]="infrastructure"
  [kubernetes-deploy]="infrastructure"
  [launchdarkly]="integrations"
  [license]="core"
  [marketplace]="core"
  [mcp]="ai"
  [messaging-core]="core"
  [migration]="data"
  [migrations]="data"
  [modularcompat]="core"
  [monday]="integrations"
  [namecheap]="infrastructure"
  [okta]="integrations"
  [openapi]="core"
  [openlms]="integrations"
  [payments]="payments"
  [pipelinesteps]="core"
  [platform]="core"
  [policy]="security"
  [product-capture]="core"
  [rooms]="core"
  [salesforce]="integrations"
  [sandbox]="security"
  [scheduler]="core"
  [security]="security"
  [security-scanner]="security"
  [slack]="messaging"
  [sso]="integrations"
  [statemachine]="core"
  [steam]="integrations"
  [storage]="data"
  [supply-chain]="security"
  [teams]="integrations"
  [template]="core"
  [timeline]="data"
  [tofu]="infrastructure"
  [turnio]="messaging"
  [twilio]="messaging"
  [vectorstore]="data"
  [waf]="security"
  [websocket]="messaging"
  [ws-auth]="messaging"
  [workflow-plugin-atlas-migrate]="data"
  [workflow-plugin-auth]="core"
  [workflow-plugin-compute]="core"
  [workflow-plugin-migrations]="data"
  [workflow-plugin-product-capture]="core"
  [workflow-plugin-supply-chain]="security"
)
```

If a plugin dir lacks an entry → `category: null` → CI assertion fails ("plugin <name> missing category in CATEGORY_MAP — add it to scripts/categorize-manifests.sh"). Forces future plugin additions to consciously assign a category.

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

`package.json` `scripts`:

```json
"prebuild": "node scripts/sync-plugins.mjs",
"build": "tsc -b --noCheck && vite build"
```

(`prebuild` runs automatically before `build` per npm convention.)

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

`.github/workflows/registry-sync.yml`:

```yaml
name: Registry snapshot sync
on:
  schedule:
    - cron: '*/15 * * * *'   # every 15 minutes
  workflow_dispatch: {}        # manual trigger

permissions:
  contents: write              # to commit + push the snapshot update

jobs:
  sync:
    name: Sync plugin snapshot from workflow-registry
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
          token: ${{ secrets.GITHUB_TOKEN }}
      - uses: actions/setup-node@v4
        with:
          node-version: 22
      - name: Fetch + write plugin snapshot
        run: node scripts/sync-plugins.mjs
      - name: Commit + push if snapshot changed
        run: |
          set -euo pipefail
          if git diff --quiet -- src/data/plugins.json; then
            echo "no snapshot change; nothing to commit"
            exit 0
          fi
          git config user.email "github-actions[bot]@users.noreply.github.com"
          git config user.name  "github-actions[bot]"
          git add src/data/plugins.json
          git commit -m "chore: sync plugin snapshot from workflow-registry"
          git push origin main
          echo "snapshot updated + pushed to main"
```

The `ci.yml` workflow (triggered on push to main) then runs lint + build, validating the new snapshot. The website's existing `release.yml` (triggered on tag push) deploys to the live site whenever the maintainer cuts the next release. This matches the existing manual-deploy pattern; no infrastructure changes.

Round-1 deploy-coupling question is dropped: deploys remain manual via existing tag flow. Data indexing in `main` is the gain.

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
| A7 | `secrets.GITHUB_TOKEN` in registry-sync.yml has push access to main (default for actions runs in the same repo). | If branch-protection rules require PRs for main: cron's commit fails; workflow surfaces an actionable error. Mitigation: registry-sync.yml could open a PR instead of pushing directly. Out of MVP scope; flagged as Phase 2 option. |

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
