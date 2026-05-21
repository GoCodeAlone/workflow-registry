# Build-Index Extended-Allowlist Design — G3

**Date:** 2026-05-21
**Status:** Revised after adversarial review + user redirect (allowlist intent restored)
**Scope:** `scripts/build-index.sh` summary projection
**Tracking issue:** GoCodeAlone/workflow-registry#80

## Goal

Extend `v1/index.json` to carry the fields downstream consumers actually need (status, IaC provider metadata, plugin-provided CLI commands, required-secret names, homepage, assets) **while preserving the existing jq projection as a security allowlist**. External plugin manifests are partially untrusted — the projection prevents arbitrary fields from leaking into the public bulk-download surface.

## Decision: stay with the allowlist (Option A)

Round-1 design (now rejected) proposed inlining the full manifest. Two reasons that fails:

1. **Allowlist intent.** The existing projection is a deliberate safelist. Inlining echoes every schema-valid field, including ones a third-party plugin author could populate. The registry hosts community-tier manifests; the public `v1/index.json` is a bulk-download artifact (GH Pages, ~74 plugins). Field-level review at projection time is the design guarantee that nothing surprising goes out.
2. **Specific exposures blocked.** Adversarial review surfaced two concrete leaks the allowlist prevents:
   - `checksums` (schema-defined per-version SHA-256 map) — fine in per-plugin manifest, surprising in bulk index.
   - `downloads` (per-version URL+SHA list) — stale relative to `build-versions.sh`'s live `latest.json`. Inlining into index creates a parallel, stale install-source.

Allowlist stays; we add explicit fields.

## Allowlisted summary shape (v2)

| Field | Type | Added? | Why |
|---|---|---|---|
| `name` | string (dir name) | unchanged | dir-name override, identity |
| `description` | string | unchanged | search |
| `version` | string | unchanged | display |
| `type` | string | unchanged | filter (external/internal) |
| `tier` | string | unchanged | filter (verified/community) |
| `license` | string | unchanged | display |
| `author` | string | unchanged | display |
| `keywords` | []string | unchanged | search |
| `private` | bool | unchanged | display |
| `repository` | string | unchanged | display |
| `homepage` | string | **new** | display (distinct from repository) |
| `minEngineVersion` | string | unchanged | compat filter |
| `status` | string | **new** | filter (verified/experimental/deprecated) |
| `capabilities.moduleTypes` | []string | unchanged | filter |
| `capabilities.stepTypes` | []string | unchanged | filter |
| `capabilities.triggerTypes` | []string | unchanged | filter |
| `capabilities.workflowHandlers` | []string | unchanged | filter |
| `capabilities.wiringHooks` | []string | unchanged | filter |
| `capabilities.iacProvider.name` | string | **new** | filter (IaC providers by short name) |
| `capabilities.iacProvider.resourceTypes` | []string | **new** | filter ("plugins managing infra.dns") |
| `capabilities.cliCommands[].name` | []{name, description} | **new** | filter ("plugins providing wfctl <X>") |
| `capabilities.migrationDrivers` | []string | **new** | filter (migration plugins) |
| `iacProvider.computePlanVersion` | string | **new** | filter (v2-compatible IaC plugins) |
| `required_secrets` | []{name, sensitive, description, prompt} | **new** | UX ("which plugins need credentials"); `wfctl plugin search` already fetches per-plugin manifest for setup, but surfacing this in the index lets `plugin search --needs-secret X` work without N round-trips |
| `assets` | {ui: bool, config: bool} | **new** | UI hints |
| `dependencies` | []{name, minVersion, maxVersion} | **new** | install-order resolver may want this without per-plugin fetch |

Explicitly NOT added (per security/correctness analysis):

| Field | Reason |
|---|---|
| `downloads` | Conflicts with `build-versions.sh`'s `latest.json` as the install-source-of-truth; inlining the manifest's static (potentially stale) list creates a parallel install path that drifts from reality. |
| `checksums` | Per-version SHA map. Belongs in `latest.json`/`versions.json` next to the actual download list, not the bulk index. |
| `contracts` | wfctl-internal; not a search/filter axis. |
| `serviceMethods` | Not yet in `registry-schema.json`. Deferred — needs schema extension first. |
| `portIntrospect` | Not in schema. Same deferral. |
| `configProvider` | Not in schema. Same deferral. |
| `buildHooks` | wfctl-internal build-time hook list. Not user-facing search. |

## Components

| File | Change |
|---|---|
| `scripts/build-index.sh` | Extend the jq projection to include the new allowlisted fields. Add `REPO_ROOT` env override (`REPO_ROOT="${REPO_ROOT:-$(cd "${SCRIPT_DIR}/.." && pwd)}"`) so tests can point it at a fixture dir. |
| `tests/test-build-index.sh` (new) | Bash + jq harness; tmp fixture dir; asserts field presence, dir-name override, sort order, and security-relevant *omissions* (downloads/checksums/contracts must NOT appear in the index). |
| `tests/fixtures/plugins/foo-iac/manifest.json` (new) | IaC-flavored fixture with required_secrets + iacProvider + cliCommands + a manifest-`name` that differs from dir name (validates override). |
| `tests/fixtures/plugins/bar-simple/manifest.json` (new) | Minimal manifest exercising the default values + status. |
| `.github/workflows/validate.yml` | Add a step running `bash tests/test-build-index.sh` so CI catches projection drift. |

`build-versions.sh` and the per-plugin `v1/plugins/<name>/manifest.json` copies stay unchanged — both already operate at full-manifest fidelity, which is correct for those surfaces. Only `v1/index.json` is allowlisted.

## Data flow

```
plugins/<name>/manifest.json
  ↓ (build-index.sh: jq allowlist projection + name override)
v1/index.json[]              ← bulk index, security-allowlisted
  ↓
v1/plugins/<name>/manifest.json   ← per-plugin copy, full pass-through
  ↓
v1/plugins/<name>/latest.json     ← built by build-versions.sh from live GH releases
  ↓ (GH Pages)
https://gocodealone.github.io/workflow-registry/v1/...
  ↓
wfctl plugin search       (uses index.json + per-plugin manifest)
wfctl plugin install      (uses latest.json + per-plugin manifest)
```

## Tests

`tests/test-build-index.sh`:

1. Stage two fixture manifests under a tmp `plugins/foo-iac/manifest.json` + `plugins/bar-simple/manifest.json`. The IaC fixture's manifest `.name` is `"workflow-plugin-foo-overrideme"` to validate dir-name override.
2. Run `REPO_ROOT="$tmp" bash scripts/build-index.sh`.
3. Read the generated `$tmp/v1/index.json`.

Field-presence assertions:
- IaC fixture entry has `required_secrets`, `iacProvider.computePlanVersion`, `capabilities.iacProvider.name`, `capabilities.iacProvider.resourceTypes`, `capabilities.cliCommands`, `status`, `assets`.
- Simple fixture entry has `status` from the fixture; `required_secrets` is absent (since the source didn't declare any) — the field SHOULD be omitted not present-with-empty (`null`-tolerant `// empty` jq pattern).
- Both entries' `name` equals the dir name, NOT the manifest's `.name`.
- Array sorted ascending by `.name`.

Security-allowlist assertions (the part that catches projection drift):
- IaC fixture's source manifest carries a synthetic `downloads`, `checksums`, `contracts`, and an unknown top-level field `"foo": "bar"`.
- After build, none of those four keys appear in the index entry.
- Test-failure message: "G3 allowlist regression: index leaked field <foo>; remove from build-index.sh projection or extend allowlist explicitly".

Per-plugin manifest copies (full pass-through):
- `$tmp/v1/plugins/foo-iac/manifest.json` is byte-identical to the source.

## Assumptions

| # | Claim | Risk if false |
|---|---|---|
| A1 | The jq projection is the right granularity for the allowlist (vs a separate JSON schema validator). | Adding fields means editing the script + tests, not a schema. Acceptable; the script IS the schema. |
| A2 | `wfctl plugin search` filters use the index summary (not per-plugin manifest fetches) for the new fields. | If wfctl already fetches per-plugin for these queries, the new fields are redundant. Cheap to verify before merge by grepping wfctl source. |
| A3 | No downstream consumer reads `downloads` from `v1/index.json` today (they'd already be broken since it's currently dropped). | Confirmed by the projection's current shape — `downloads` has never been in the index. |
| A4 | Adding `required_secrets` (names + descriptions, not values) to a public index is acceptable. Plugin authors are expected to declare secrets they need; the *values* are never in any manifest or index. | If a plugin author considered their secret-name list private (unusual but possible for a private plugin), the field surfaces in the public index. Mitigation: `private: true` plugins are already excluded from the public index? **TBD: verify.** |

## Rollback

Pure static rebuild. To revert:

1. Revert this PR.
2. Next push to `main` (or repository_dispatch) rebuilds `v1/index.json` to the prior shape automatically.

No persistent state, no client-side schema cache to expire, no migration. Blast radius: GH Pages contents.

## Surfaced doubts after revisions

1. **A4 — `private: true` handling**: design doesn't verify whether `private: true` plugins land in the public index at all. If they do, broadcasting their secret-name list to the world is inadvertent disclosure. Need to check `scripts/build-index.sh` behavior for `private: true` AND extend the test fixture to cover it.

2. **Schema parity for new fields**: the design depends on `iacProvider.computePlanVersion`, `capabilities.iacProvider.name|resourceTypes`, `capabilities.cliCommands` being defined in `registry-schema.json`. Confirmed for the first three; `cliCommands` schema status needs verification before merge.

3. **`status` enum**: design assumes `status` is one of `verified|experimental|deprecated`. The schema's actual enum needs to match this assumption; if `status` is a freeform string, search-by-status semantics are weaker than the table suggests.

## Adversarial review round 1 — findings addressed

| Round-1 finding | Resolution |
|---|---|
| `checksums` exposure (Critical) | Resolved by reverting to allowlist; `checksums` explicitly NOT added (see exclusion table). |
| `downloads` stale-data hazard (Critical) | Resolved by reverting to allowlist; `downloads` explicitly NOT added; `build-versions.sh`'s `latest.json` remains the authoritative source. |
| `REPO_ROOT` test override gap (Important) | Added to Components table: `scripts/build-index.sh` will accept `${REPO_ROOT:-...}` env override. |
| `portIntrospect`/`configProvider`/`serviceMethods` schema gap (Important) | Resolved: these three are explicitly deferred (see exclusion table) pending a separate schema extension PR. The design no longer claims to address them. |
| A1 payload claim overstated gzip ratio (Minor) | Moot — no longer inlining the full manifest. Allowlist payload is similar to current size. |
| `homepage` vs `repository` field clarity (Minor) | Addressed: `homepage` explicit row in the allowlist table. |
| `dependencies` field omission (Minor) | Addressed: `dependencies` explicitly added to the allowlist. |
| Per-plugin manifest copy vs index byte-identity (Minor) | Moot — design no longer claims byte-identity. |

## References

- workflow-registry#80 — the gap report.
- Current script: `scripts/build-index.sh` lines 38-58.
- Sibling script (full-fidelity, no allowlist): `scripts/build-versions.sh`.
- Related workstream: workflow-registry#79 (auto-bump on plugin release) operates on the same source manifests but a different output (`build-versions.sh`'s `latest.json`).
- User clarification: jq projection is intentional security — external plugins are partially untrusted.
