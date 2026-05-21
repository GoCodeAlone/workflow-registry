# Build-Index Inline-Manifest Design — G3

**Date:** 2026-05-21
**Status:** Draft → adversarial review
**Scope:** `scripts/build-index.sh` summary projection
**Tracking issue:** GoCodeAlone/workflow-registry#80

## Goal

`v1/index.json` should carry every field downstream consumers might need without each new field requiring a build-index.sh edit. Replace the enumerated jq projection with full-manifest inline, keeping the existing `name = directory-name` override.

## Current behavior

`scripts/build-index.sh` lines 38-58 project each plugin manifest into a fixed-shape summary that omits: `status`, top-level `iacProvider`, `capabilities.iacProvider`, `capabilities.cliCommands`, `capabilities.buildHooks`, `capabilities.migrationDrivers`, `capabilities.portIntrospect`, `capabilities.configProvider`, `capabilities.serviceMethods`, `required_secrets`, `assets`, `downloads`, `homepage`.

Consumers (`wfctl plugin search`, future UI views) read this index to filter/sort plugins. Missing fields = consumers fall back to per-plugin manifest fetches or feature is unavailable.

## Approach

Inline the full manifest as the summary. The only mutation kept is the `name = directory-name` override:

```jq
. + {name: $dir_name}
```

Per-plugin `v1/plugins/<name>/manifest.json` copies stay as-is (already pass-through). The two outputs are now identical except for the array vs object wrapper.

## Components

| File | Change |
|---|---|
| `scripts/build-index.sh` | Replace the 21-line projection block with the 1-line inline expression. Comment cites #80 + this design doc. |
| `tests/test-build-index.sh` (new) | Bash + jq test harness. Sets up tmp fixture, runs build-index.sh, asserts presence/order/override invariants. |
| `tests/fixtures/plugins/<name>/manifest.json` (new) | Two fixture plugins exercising the field-presence assertions: one IaC-style with `required_secrets` + `iacProvider`, one simple. |

## Data flow

```
plugins/<name>/manifest.json
  ↓ (find + jq + name-override)
v1/index.json[]                    ← contains full manifest per plugin
v1/plugins/<name>/manifest.json    ← per-plugin copy (unchanged)
  ↓ (GH Pages publish)
https://gocodealone.github.io/workflow-registry/v1/index.json
  ↓ (HTTP fetch)
wfctl plugin search   |   future UI   |   etc.
```

## Tests

`tests/test-build-index.sh`:
1. Create a tmp dir with `plugins/foo/manifest.json` + `plugins/bar/manifest.json` (one IaC with required_secrets, one simple).
2. Run `bash scripts/build-index.sh` against the tmp dir (script must accept `REPO_ROOT` env or `--plugins-dir` to be testable; currently hardcoded to `$(dirname $0)/..`).
3. Read the generated `v1/index.json`.
4. Assertions:
   - Index is a sorted array by `.name`.
   - Both plugins appear; `name` matches dir basename even if manifest `name` differs.
   - IaC plugin entry carries `required_secrets`, `iacProvider`, `capabilities.iacProvider`.
   - Simple plugin entry carries `status` when source did.
   - Per-plugin `v1/plugins/<name>/manifest.json` copies exist + byte-identical to sources.

Test invocation will need a `REPO_ROOT` override in the script OR a wrapper that `cd`s into the tmp dir.

## Assumptions

| # | Claim | Risk if false |
|---|---|---|
| A1 | Index payload at full-manifest scale (74 × ~2KB ≈ 150KB; HTTP/2 + gzip ≈ 30KB) stays acceptable. | Future-proofing: split summary/full indices if it grows past ~500KB. |
| A2 | No downstream consumer rejects unknown fields. JSON consumers typically project at read time. | If a strict consumer breaks: pin its parsing model OR re-introduce a stricter `index-summary.json` alongside the full index. |
| A3 | jq + bash available on every GHA runner that runs `build-pages.yml`. Already true. | n/a |

## Rollback

Pure-static-asset rebuild. To revert:

1. Revert this PR.
2. Next push to `main` (or `repository_dispatch`) rebuilds `v1/index.json` to the old shape automatically.

No persistent state, no migration, no client-side schema cache. Blast radius limited to GH Pages contents.

## Self-challenge findings

1. **Laziest alternative**: enumerate the missing fields in the existing projection. Trade-off: every future capability field needs a code edit. Inline is structurally simpler and future-proof.
2. **Fragile assumption**: A2 — could a strict consumer reject unknown fields? Mitigation noted; cheap to address if it surfaces.
3. **YAGNI sweep**: nothing in this design solves anything beyond #80's stated scope. No new fields invented.

## References

- workflow-registry#80 — the gap report.
- Current script: `scripts/build-index.sh` lines 38-58.
- Related workstream: workflow-registry#79 (auto-bump on plugin release) consumes the same index path.
