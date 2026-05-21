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
| `private` | bool | unchanged | display (also gates index inclusion — see Private filter section) |
| `repository` | string | unchanged | display |
| `homepage` | string | **new** | display (distinct from repository) |
| `source` | string | **new** | Go module path; lets `wfctl plugin install` skip a per-plugin fetch when resolving source-build flow |
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
| `path` | wfctl-internal build metadata (subpackage path within the source repo). Not a user-facing search axis; `source` alone is enough for source-build resolution. |
| `serviceMethods` | Not yet in `registry-schema.json`. Deferred — needs schema extension first. |
| `portIntrospect` | Not in schema. Same deferral. |
| `configProvider` | Not in schema. Same deferral. |
| `buildHooks` | wfctl-internal build-time hook list. Not user-facing search. |

(`contracts` was incorrectly listed in the round-2 example as an exclusion — it is NOT in `registry-schema.json` and therefore needs no marker. Removed.)

## Components

| File | Change |
|---|---|
| `scripts/build-index.sh` | Extend the jq projection to include the new allowlisted fields. Add `REPO_ROOT` env override (`REPO_ROOT="${REPO_ROOT:-$(cd "${SCRIPT_DIR}/.." && pwd)}"`) so tests can point it at a fixture dir. Add structured-comment markers `# G3-include: <field>` / `# G3-exclude: <field> — <reason>` so the schema-drift validator can parse them. |
| `tests/test-build-index.sh` (new) | Bash + jq harness; tmp fixture dir; asserts field presence, dir-name override, sort order, and security-relevant *omissions* (downloads/checksums/contracts must NOT appear in the index). |
| `tests/test-schema-allowlist-coverage.sh` (new) | **Drift check**: parses `registry-schema.json`'s top-level + `capabilities.*` property names; compares against build-index.sh's `G3-include`/`G3-exclude` markers; fails when a schema field is neither included nor explicitly excluded. Output: "schema field <X> has no allow/exclude decision in build-index.sh; add `# G3-include: <X>` or `# G3-exclude: <X> — <reason>`". |
| `tests/fixtures/plugins/foo-iac/manifest.json` (new) | IaC-flavored fixture with required_secrets + iacProvider + cliCommands + a manifest-`name` that differs from dir name (validates override). |
| `tests/fixtures/plugins/bar-simple/manifest.json` (new) | Minimal manifest exercising the default values + status. |
| `.github/workflows/validate.yml` | Add a NEW `validate-index-projection` job (ubuntu-latest, jq pre-installed, no Node setup needed) running both `bash tests/test-build-index.sh` and `bash tests/test-schema-allowlist-coverage.sh`. Keeps the bash/jq tests architecturally separate from the existing Node-based `validate-manifests` job. |

`build-versions.sh` and the per-plugin `v1/plugins/<name>/manifest.json` copies stay unchanged — both already operate at full-manifest fidelity, which is correct for those surfaces. Only `v1/index.json` is allowlisted.

## Private-plugin filter

**Decision (resolves round-2 A4):** `private: true` plugins are skipped entirely from the public `v1/index.json` array. Their per-plugin `v1/plugins/<name>/manifest.json` copy still publishes (consistent with current behavior — those URLs are how authenticated wfctl consumers fetch private-plugin metadata), but they don't appear in the public bulk listing.

Why: the bulk index is the broadest-reach surface. With `required_secrets[]` now in the allowlist, any future private plugin that declares secrets would surface its secret-name list to the entire internet on next build. Filtering at the `find` loop level eliminates the concern permanently and simplifies future allowlist evolution — we no longer have to ask "is this field safe for private plugins to expose publicly?" for every new field.

Five plugins are `private: true` today (agent, authz-ui, cloud-ui, security, workflow-plugin-auth). None currently declare `required_secrets`, so the filter is invisible to today's consumers. The behavior change is forward-looking: future private-plugin authors don't need to remember to omit secrets to avoid disclosure.

Implementation: jq `select(.private != true)` filter inside the `find` loop, before the projection. Test fixture must include a `private: true` manifest and assert it's absent from the index.

## Schema-allowlist drift guard (per user redirect)

The risk this mitigates: someone extends `registry-schema.json` with a new field (e.g. adds `serviceMethods` to capabilities) without making a decision about whether it lands in the public bulk index. Without a forcing function, the new field is silently allowed-by-schema but invisibly excluded-by-projection — or, worse, inlined later without an exclusion review.

**Mechanism:**

1. Every property name allowed by `registry-schema.json` must appear in `build-index.sh` as either:
   - `# G3-include: <field>` — covered by the jq projection.
   - `# G3-exclude: <field> — <reason>` — intentionally not surfaced.
2. Coverage scope:
   - **Top-level properties** (e.g., `name`, `version`, `source`, `path`).
   - **`capabilities.*` direct children** (e.g., `moduleTypes`, `iacProvider`, `cliCommands`).
   - **One level into the three sub-objects that matter** for the index:
     - `capabilities.iacProvider.*` (name, resourceTypes, supportedCanonicalKeys).
     - `capabilities.cliCommands[].items.*` (name, description, flags_passthrough, subcommands).
     - top-level `iacProvider.*` (computePlanVersion).
   - Anything deeper is full pass-through inside whatever container is included — and the container's inclusion is itself the deliberate decision.
3. Bidirectional check: drift guard ALSO asserts every `G3-include`/`G3-exclude` marker corresponds to a real schema property — catches phantom markers (e.g., the round-2 `contracts` example).
4. `tests/test-schema-allowlist-coverage.sh` extracts both sets via jq + grep; fails with: "schema field <X> has no allow/exclude decision in build-index.sh" OR "build-index.sh marker `<X>` does not correspond to a schema property — remove it".
5. CI runs the test on every PR.

**Why structured comments not a separate file:** the build script and the allowlist live in the same file. Keeping the markers inline means there's no "the file said X but the script said Y" failure mode.

**Example marker placement in `build-index.sh`:**

```bash
# Allowlisted summary projection — see docs/plans/2026-05-21-build-index-...md
# Every schema-allowed field must appear here as G3-include OR G3-exclude.
# tests/test-schema-allowlist-coverage.sh enforces this on CI.
#
# G3-include: name
# G3-include: description
# G3-include: version
# G3-include: source
# G3-include: status
# G3-include: required_secrets
# G3-exclude: downloads — stale relative to build-versions.sh latest.json
# G3-exclude: checksums — belongs in versions.json, not bulk index
# G3-exclude: path — wfctl-internal subpackage path, not user-facing
# G3-include: capabilities.iacProvider
# G3-include: capabilities.iacProvider.name
# G3-include: capabilities.iacProvider.resourceTypes
# G3-include: capabilities.iacProvider.supportedCanonicalKeys
# G3-include: capabilities.cliCommands
# G3-include: capabilities.cliCommands.name
# G3-include: capabilities.cliCommands.description
# G3-include: capabilities.cliCommands.flags_passthrough
# G3-include: capabilities.cliCommands.subcommands
# G3-include: iacProvider.computePlanVersion
# ...

summary="$(jq --arg dir_name "${plugin_name}" '{
  ...
}' "${manifest}")"
```

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
- Simple fixture entry has `status` from the fixture; `required_secrets` is absent when the source manifest omitted the key entirely. Semantics: `(.required_secrets // empty)` drops the field iff the source has no key at all OR has `null`. If a manifest explicitly sets `"required_secrets": []`, the empty array IS preserved (a deliberate "this plugin needs no secrets" signal differs from "this plugin's manifest predates the secrets convention"). Tests cover all three cases: key-absent → omitted; `null` → omitted; `[]` → preserved as `[]`.
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

## Surfaced doubts after revisions (closed)

1. **A4 — `private: true` handling**: **RESOLVED** — Private-plugin filter section above commits to filtering them out of the index entirely. No future secret-name disclosure risk.

2. **Schema parity for new fields**: **RESOLVED** — `iacProvider.computePlanVersion`, `capabilities.iacProvider.name|resourceTypes|supportedCanonicalKeys`, `capabilities.cliCommands` all verified present in `registry-schema.json`.

3. **`status` enum**: **RESOLVED** — schema enum is exactly `verified | experimental | deprecated`, matching the design assumption.

## Adversarial review round 2 — findings addressed

| Round-2 finding | Severity | Resolution |
|---|---|---|
| `source`/`path` missing allow/exclude decisions | Critical | `source` added to allowlist (Go module path; useful for source-build install resolution); `path` added to exclusion table (wfctl-internal subpackage path, not user-facing). |
| Sub-property scope gap (capabilities.iacProvider.*, cliCommands sub-fields) | Important | Drift guard explicitly extended to one level deeper for the three relevant sub-objects (iacProvider, cliCommands, top-level iacProvider). Allowlist now enumerates each sub-field. |
| `private: true` + `required_secrets` disclosure | Important | New Private-plugin filter section: `select(.private != true)` at the find loop excludes private plugins from the public index entirely. Per-plugin manifest copies still publish for authenticated consumers. |
| Phantom `contracts` marker | Important | Removed from example. Drift guard now bidirectional: every marker MUST correspond to a real schema property, catching phantom entries automatically. |
| CI step placement underspecified | Minor | New dedicated `validate-index-projection` job; bash/jq isolated from the Node-based `validate-manifests` job. |
| jq `// empty` semantics ambiguity | Minor | Three cases enumerated: key-absent → omitted; `null` → omitted; explicit `[]` → preserved as `[]`. Tests cover all three. |
| Doubt #2 (cliCommands schema status) | Minor | Resolved: schema defines it (lines 109-142); removed from open-doubts list. |

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
