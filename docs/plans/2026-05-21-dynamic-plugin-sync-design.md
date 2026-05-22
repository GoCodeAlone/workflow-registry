# Dynamic Plugin Sync — gocodealone-website ← workflow-registry

**Date:** 2026-05-21
**Scope:** Make `gocodealone-website`'s `PluginsPage.tsx` reflect `workflow-registry` plugin list dynamically at build time. Adds `category` field to manifest schema; sweeps existing manifests with category assignments; wires repository_dispatch from registry's build-pages.yml to gocodealone-website on every publish; rewrites PluginsPage to consume a build-generated snapshot.
**User direction (verbatim):** "Use superpower skills. Option B, so we can ensure the results are indexed. Add a category field to the manifest. Then perform a registry sweep. Proceed autonomously until complete."

## Goal

Today `PluginsPage.tsx` is a hardcoded list of 6 categories × ~20 plugin strings. After this design lands: plugin metadata (categorized by `category` field on the manifest) flows from the upstream plugin repo → workflow-registry → GH Pages index.json → committed website snapshot → rendered page, with auto-rebuild on every plugin release. Lag target: ~2-5 minutes from plugin tag to website-visible.

## Architecture

```
plugin tag (already wired via G1+G2)
   ↓ repository_dispatch [plugin-release]
workflow-registry  sync-registry-manifests.yml      (G2, already wired)
   ↓ merge to main
workflow-registry  build-pages.yml                  (PR 4 — adds post-deploy dispatch)
   ├─ scripts/build-index.sh → v1/index.json with new `category` field (PR 1+2)
   ├─ deploy to GH Pages
   └─ dispatch [registry-updated] → gocodealone-website (PR 4)
gocodealone-website  .github/workflows/registry-sync.yml  (PR 5 — new)
   └─ rebuild + redeploy via existing release.yml path
      ↓ prebuild: scripts/sync-plugins.mjs                 (PR 5)
         ├─ fetch https://gocodealone.github.io/workflow-registry/index.json
         ├─ write src/data/plugins.json (overwrites committed snapshot)
         └─ if fetch fails: log warning + exit 0 (use last-committed snapshot)
      ↓ src/pages/PluginsPage.tsx imports src/data/plugins.json (PR 5)
         ├─ groups by `category`
         ├─ sorts within group by `name`
         └─ renders cards with name, description, version, tier, status, repository link
```

## PR layout (5 PRs, sequenced)

| # | Repo | Title | Notes |
|---|---|---|---|
| 1 | workflow-registry | feat(schema): add `category` enum + project to v1/index.json | Schema change + G3 projection + drift-guard markers + test-build-index assertions + fixture updates. Existing manifests without `category` validate fine (optional field). |
| 2 | workflow-registry | feat(registry): categorize all plugin manifests | Sweep ~80 manifests. Programmatically derived from keywords / capabilities / repo names; hand-tuned where ambiguous. One large diff but mechanical. |
| 3 | workflow-cloud-registry | feat(schema): add `category` enum (parity) | Schema-only port; no value sweep. Private plugins don't surface to public site; this just keeps schemas aligned for future private-side consumers. |
| 4 | workflow-registry | ci(build-pages): dispatch registry-updated to gocodealone-website | Post-`deploy` job step that fires `repository_dispatch` with `event_type: registry-updated` and `client_payload: {sha}`. Uses existing `secrets.repo_dispatch_token` (same lowercase secret already shared with G1). |
| 5 | gocodealone-website | feat(plugins-page): build-time sync from workflow-registry | `scripts/sync-plugins.mjs` + `prebuild` script wired into `package.json` + `PluginsPage.tsx` rewrite + `.github/workflows/registry-sync.yml` listening for `repository_dispatch: [registry-updated]` + initial `src/data/plugins.json` snapshot committed for fallback. |

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

Category taxonomy (10 + "other"):

| Category | Examples |
|---|---|
| `core` | admin, auth, authz, bento, pipelinesteps |
| `ai` | agent, mcp |
| `payments` | payments |
| `security` | waf, security, sandbox, supply-chain, data-protection, audit, audit-chain |
| `infrastructure` | aws, gcp, azure, digitalocean, tofu, ci-generator, hover, namecheap, compute, infra |
| `ide` | (currently no plugins; reserved for vscode/jetbrains extensions if registered) |
| `messaging` | eventbus, slack, discord, twilio, websocket, ws-auth, broker, turnio |
| `data` | vectorstore, datastores, datalake, datawarehouse, datapool, migrations, migration |
| `integrations` | github, gitlab, salesforce, monday, openlms, launchdarkly, datadog, okta, steam, teams, sso, analytics |
| `observability` | audit-chain (duplicate-of-security candidate), audit, security-scanner |
| `other` | fallback for unclear plugins |

Each plugin gets exactly one category. When a plugin spans two buckets (e.g. audit-chain = security + observability), pick the primary intent — security audit-chains are security-first.

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

Generate categorization programmatically from heuristics:

1. If `capabilities.iacProvider` present OR `capabilities.iacStateBackends` non-empty → `infrastructure`
2. If repo/dir name matches `^(workflow-plugin-)?(audit|supply-chain|waf|security|sandbox|data-protection)$` → `security`
3. If `capabilities.moduleTypes` contains `payments.provider` → `payments`
4. If `capabilities.moduleTypes` contains `eventbus.*` OR `messaging.*` OR matches `(slack|discord|turnio|twilio|broker|websocket|ws-auth)` → `messaging`
5. If matches `(vectorstore|datastore|datalake|datawarehouse|datapool|migration|migrations)` → `data`
6. If matches `(agent|mcp)` → `ai`
7. If matches `(github|gitlab|salesforce|monday|openlms|launchdarkly|datadog|okta|steam|teams|sso|analytics)` → `integrations`
8. If matches `(admin|auth$|authz|bento|pipelinesteps|cms|broker|approval|rooms|template|platform|marketplace|infra|cicd|compute|ci-generator|tofu|namecheap|hover|aws|gcp|azure|digitalocean|template-private|product-capture|messaging-core)$` → assign per the table above
9. Default → `other`

The PR includes a `scripts/categorize-manifests.sh` helper that runs this categorization but the actual category writes go into the manifest JSONs themselves (not derived at build time — derived once, committed). Reviewers can hand-tune ambiguous cases in the same PR.

## Build-pages dispatch (PR 4)

Append a new job to `.github/workflows/build-pages.yml` after `deploy`:

```yaml
  notify-website:
    name: Notify gocodealone-website
    needs: deploy
    runs-on: ubuntu-latest
    permissions:
      contents: read
    steps:
      - name: Trigger website rebuild
        uses: peter-evans/repository-dispatch@28959ce8df70de7be546dd1250a005dd32156697  # v4
        with:
          token: ${{ secrets.repo_dispatch_token }}
          repository: GoCodeAlone/gocodealone-website
          event-type: registry-updated
          client-payload: |-
            {"sha": "${{ github.sha }}", "ref": "${{ github.ref_name }}"}
```

The `--allow-no-entry-points` learning applies to wfctl, not here. Cross-repo dispatch via `peter-evans/repository-dispatch@v4` SHA-pinned per security hardening.

## Website prebuild + rewrite (PR 5)

`scripts/sync-plugins.mjs`:

```js
#!/usr/bin/env node
// Fetches https://gocodealone.github.io/workflow-registry/index.json
// and writes src/data/plugins.json (overwrites committed snapshot).
// On fetch failure: logs warning + exits 0 (build proceeds with last-committed snapshot).

import { writeFileSync, readFileSync } from "node:fs";
import { join } from "node:path";

const REGISTRY_URL =
  process.env.REGISTRY_URL ??
  "https://gocodealone.github.io/workflow-registry/index.json";
const OUT_PATH = join(import.meta.dirname ?? ".", "..", "src", "data", "plugins.json");

try {
  const res = await fetch(REGISTRY_URL, { signal: AbortSignal.timeout(15_000) });
  if (!res.ok) {
    console.warn(`[sync-plugins] HTTP ${res.status}; using committed snapshot`);
    process.exit(0);
  }
  const json = await res.json();
  if (!Array.isArray(json)) {
    console.warn("[sync-plugins] non-array response; using committed snapshot");
    process.exit(0);
  }
  writeFileSync(OUT_PATH, JSON.stringify(json, null, 2) + "\n");
  console.log(`[sync-plugins] wrote ${json.length} plugins to ${OUT_PATH}`);
} catch (err) {
  console.warn(`[sync-plugins] fetch failed: ${err.message}; using committed snapshot`);
  process.exit(0);
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

## Website registry-sync workflow (PR 5)

`.github/workflows/registry-sync.yml`:

```yaml
name: Registry sync rebuild
on:
  repository_dispatch:
    types: [registry-updated]
  workflow_dispatch: {}

permissions:
  contents: write    # so the snapshot can be auto-committed if desired (not in MVP)

jobs:
  rebuild:
    name: Rebuild + redeploy
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: '20'
      - run: npm ci
      - run: npm run build  # invokes prebuild → sync-plugins.mjs → vite build
      # Deploy step: TBD — mirror existing release.yml deploy commands.
```

This is the minimum scaffold. Real deploy step depends on website's hosting (GH Pages? Vercel? Custom?). The release.yml in the repo already deploys; this new workflow either calls into release.yml's logic or replicates it. Decided at PR 5 write time after reading release.yml.

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

## Assumptions

| # | Claim | Risk if false |
|---|---|---|
| A1 | `https://gocodealone.github.io/workflow-registry/index.json` is reachable from GitHub Actions runners during the website build (server-side fetch — CORS not relevant) | Build falls back to committed snapshot; warns; ships stale data until next push |
| A2 | `secrets.repo_dispatch_token` (org-level secret) has `repo` scope including `gocodealone-website` (private repo per `package.json` "private": true) | Dispatch fails silently; website doesn't rebuild on registry change. Mitigation: existing cron / push-triggered rebuild still works if added or manually fired |
| A3 | The 10-category enum (+ `other` fallback) covers ~80 current plugins. Authors of new plugins know which category to pick. | "other" grows over time; future schema PR adds more enum values |
| A4 | gocodealone-website's existing release.yml deploy path can be re-invoked from registry-sync.yml (either via workflow_call or by duplicating its steps). Confirmed at PR 5 time. | If release.yml is not reusable, registry-sync.yml duplicates the steps |
| A5 | Programmatic categorization from keywords / capabilities catches ~70-80% of cases cleanly. The remaining 20-30% are hand-tuned during PR 2 review. | More hand-tuning needed than expected; PR 2 grows in scope |
| A6 | Adding an optional schema field with a constrained enum does not break any existing manifest validation (manifests without `category` validate; manifests with unknown values rejected) | If existing manifests had a stray `category` key with non-enum value, validation breaks. Mitigation: PR 1 includes a pre-sweep validation pass to flag any pre-existing key |

## Top 3 doubts (surfaced from self-challenge)

1. **Category taxonomy chosen unilaterally** — 10 buckets may not match user's mental model exactly. The website's existing 6 buckets (Core/AI/Payments/Security/Infrastructure/IDE) could be the desired final shape with the new 4 buckets folded in. Best resolved by landing PR 1 (schema only, no semantic impact) and seeing PR 2 categorization in review.
2. **~80 manifest edits in a single sweep PR** = large diff. Reviewers can scan; risk is hand-tuning judgment calls. Acceptable per "proceed autonomously" mandate; revert is single-PR.
3. **registry-sync.yml deploy step depends on website's release.yml shape** — won't fully know until PR 5 starts. Could result in either reuse via `workflow_call` (clean) or step duplication (more code but simpler).

## Rollback

Each PR independently revertible:
- PR 1: revert removes `category` from schema; existing manifests stay valid (optional field).
- PR 2: revert removes categorizations from all manifests; G3 projection emits `category: null` for each.
- PR 3: revert removes schema field from cloud-registry; private-registry consumers unaffected.
- PR 4: revert removes dispatch step; website doesn't rebuild on registry change but otherwise unaffected.
- PR 5: revert restores hardcoded PluginsPage.tsx + removes prebuild script + drops registry-sync.yml.

No persistent state, no migrations, no client-side cache to expire.

## References

- Live index.json: https://gocodealone.github.io/workflow-registry/index.json
- Current PluginsPage.tsx: `src/pages/PluginsPage.tsx` (gocodealone-website)
- G2 dispatch handler: workflow-registry#84 (merged 2026-05-21)
- G3 allowlist projection: workflow-registry#82 (merged 2026-05-21)
- Schema hotfix: workflow-registry#85 (merged 2026-05-21)
- G1 plugin notify sweep: 42 public + 8 private plugin repos (merged 2026-05-21)
