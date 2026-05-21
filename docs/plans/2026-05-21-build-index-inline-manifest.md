# Build-Index Extended-Allowlist Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Extend `scripts/build-index.sh`'s jq projection to surface `status`, `homepage`, `source`, `iacProvider.*`, `cliCommands`, `migrationDrivers`, `required_secrets`, `assets`, `dependencies` in `v1/index.json`. Add a private-plugin filter + a schema-drift CI guard so future schema additions can't sneak past the allowlist.

**Architecture:** Single script change (build-index.sh) + two new bash/jq tests + two fixture manifests + one new CI job. Layered enforcement: `tests/test-build-index.sh` (primary, jq projection contract) + `tests/test-schema-allowlist-coverage.sh` (informational, schema↔markers drift guard).

**Tech Stack:** Bash, jq, GitHub Actions. No language runtime additions.

**Base branch:** main

**Working branch:** feat/build-index-extended-summary (already created in `_worktrees/g3-build-index`)

**Design doc:** `docs/plans/2026-05-21-build-index-inline-manifest-design.md`

---

## Scope Manifest

**PR Count:** 1
**Tasks:** 8
**Estimated Lines of Change:** ~350 (informational; not enforced)

**Out of scope:**
- Auto-bump on plugin release (separate workstream — workflow-registry#79 / G2)
- Notify-registry step in plugin release workflows (G1)
- `serviceMethods` / `portIntrospect` / `configProvider` — these are NOT in `registry-schema.json` yet; defer until a separate schema-extension PR
- Schema or `build-versions.sh` changes — both stay untouched

**PR Grouping:**

| PR # | Title | Tasks | Branch |
|------|-------|-------|--------|
| 1 | Extend v1/index.json allowlist + add schema-drift guard | Task 1, Task 2, Task 3, Task 4, Task 5, Task 6, Task 7, Task 8 | feat/build-index-extended-summary |

**Status:** Locked 2026-05-21T06:34:11Z

---

### Task 1: Add `REPO_ROOT` env override + extend allowlist (additive fields, no IaC yet)

**Files:**
- Modify: `scripts/build-index.sh:12,40-59`

**Step 1: Write the failing test (placeholder — formal test in Task 5)**

This task is the source-edit foundation; the assertion-driven test arrives in Task 5. Verify locally by running:

```bash
cd /tmp && rm -rf bi-smoke && mkdir -p bi-smoke/plugins/foo/{,..} && \
cat > bi-smoke/plugins/foo/manifest.json <<'EOF'
{"name":"foo","version":"1.0.0","author":"x","description":"x","type":"external","tier":"community","license":"MIT","status":"verified","homepage":"https://x","source":"github.com/x/y"}
EOF
REPO_ROOT=/tmp/bi-smoke bash <repo>/scripts/build-index.sh
jq '.[0] | has("status") and has("homepage") and has("source")' /tmp/bi-smoke/v1/index.json
```

Expected: `true`. Before Task 1 edits land, it returns `false`.

**Step 2: Edit `scripts/build-index.sh`**

Replace line 12:

```bash
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
```

with:

```bash
REPO_ROOT="${REPO_ROOT:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
```

Replace the jq projection (lines 40-59) with the v2 allowlist (top-level fields only — IaC, cliCommands, required_secrets land in Tasks 2-4):

```bash
  summary="$(jq --arg dir_name "${plugin_name}" '{
    name:             $dir_name,
    description:      (.description // ""),
    version:          (.version // ""),
    type:             (.type // ""),
    tier:             (.tier // ""),
    status:           (.status // null),
    license:          (.license // ""),
    author:           (.author // ""),
    keywords:         (.keywords // []),
    private:          (.private // false),
    homepage:         (.homepage // null),
    source:           (.source // null),
    repository:       (.repository // null),
    minEngineVersion: (.minEngineVersion // null),
    assets:           (.assets // null),
    dependencies:     (.dependencies // []),
    capabilities: {
      moduleTypes:      (.capabilities.moduleTypes      // []),
      stepTypes:        (.capabilities.stepTypes        // []),
      triggerTypes:     (.capabilities.triggerTypes     // []),
      workflowHandlers: (.capabilities.workflowHandlers // []),
      wiringHooks:      (.capabilities.wiringHooks      // []),
      migrationDrivers: (.capabilities.migrationDrivers // [])
    }
  }' "${manifest}")"
```

**Step 3: Smoke-run locally**

Run the bash one-liner above. Expected: `true`.

**Step 4: Commit**

```bash
git add scripts/build-index.sh
git commit -m "feat(build-index): add REPO_ROOT override + top-level allowlist fields"
```

---

### Task 2: Extend allowlist with IaC provider sub-fields (capabilities.iacProvider + top-level iacProvider)

**Files:**
- Modify: `scripts/build-index.sh` (the jq object literal from Task 1)

**Step 1: Edit the jq projection**

Inside the `capabilities: { … }` block, after `migrationDrivers`, add:

```jq
      iacProvider: (
        if .capabilities.iacProvider == null then null
        else {
          name:                   (.capabilities.iacProvider.name // null),
          resourceTypes:          (.capabilities.iacProvider.resourceTypes // []),
          supportedCanonicalKeys: (.capabilities.iacProvider.supportedCanonicalKeys // [])
        }
        end
      )
```

After the `capabilities: { … }` block (still inside the outer object), add a top-level `iacProvider` mirror:

```jq
    iacProvider: (
      if .iacProvider == null then null
      else {
        name:               (.iacProvider.name // null),
        resourceTypes:      (.iacProvider.resourceTypes // []),
        computePlanVersion: (.iacProvider.computePlanVersion // null)
      }
      end
    )
```

**Step 2: Smoke-run**

```bash
cat > /tmp/bi-smoke/plugins/foo/manifest.json <<'EOF'
{"name":"foo","version":"1.0.0","author":"x","description":"x","type":"external","tier":"community","license":"MIT","capabilities":{"iacProvider":{"name":"hover","resourceTypes":["infra.dns"],"supportedCanonicalKeys":["zone","record"]}},"iacProvider":{"computePlanVersion":"v2"}}
EOF
REPO_ROOT=/tmp/bi-smoke bash <repo>/scripts/build-index.sh
jq '.[0].capabilities.iacProvider' /tmp/bi-smoke/v1/index.json
jq '.[0].iacProvider' /tmp/bi-smoke/v1/index.json
```

Expected: capabilities.iacProvider shows `name`, `resourceTypes`, `supportedCanonicalKeys`; top-level `iacProvider` shows `computePlanVersion`. Both non-null.

**Step 3: Commit**

```bash
git add scripts/build-index.sh
git commit -m "feat(build-index): allowlist iacProvider sub-fields (capabilities + top-level)"
```

---

### Task 3: Extend allowlist with cliCommands sub-fields

**Files:**
- Modify: `scripts/build-index.sh`

**Step 1: Edit projection**

Inside `capabilities: { … }`, after `iacProvider`, add:

```jq
      cliCommands: (
        [(.capabilities.cliCommands // [])[] | {
          name:              (.name // null),
          description:       (.description // null),
          flags_passthrough: (.flags_passthrough // false),
          subcommands:       (.subcommands // [])
        }]
      )
```

(Mapping over the array materializes only the four schema-allowed sub-fields per item; anything else a manifest declares inside `cliCommands[]` is dropped.)

**Step 2: Smoke-run**

```bash
cat > /tmp/bi-smoke/plugins/foo/manifest.json <<'EOF'
{"name":"foo","version":"1.0.0","author":"x","description":"x","type":"external","tier":"community","license":"MIT","capabilities":{"cliCommands":[{"name":"dns","description":"Manage DNS","flags_passthrough":true,"subcommands":[{"name":"sync","description":"sync"}],"undocumented_field":"leak"}]}}
EOF
REPO_ROOT=/tmp/bi-smoke bash <repo>/scripts/build-index.sh
jq '.[0].capabilities.cliCommands[0] | keys_unsorted' /tmp/bi-smoke/v1/index.json
```

Expected: `["name","description","flags_passthrough","subcommands"]`. The `undocumented_field` is absent.

**Step 3: Commit**

```bash
git add scripts/build-index.sh
git commit -m "feat(build-index): allowlist cliCommands sub-fields with per-item projection"
```

---

### Task 4: Allowlist required_secrets + add private-plugin filter

**Files:**
- Modify: `scripts/build-index.sh:28-68` (the find loop body)

**Step 1: Add `required_secrets` to projection (conditional-merge pattern — C-1 fix)**

`(.required_secrets // empty)` is unsafe inside the jq object literal: when the source key is absent or `null`, the entire enclosing object is dropped (jq treats `empty` at any field position as "produce no output"). 72 of 74 live manifests lack `required_secrets`, so this would crash `build-index.sh` on the next dispatch run with `invalid JSON text passed to --argjson` — silently regressing the GH Pages index. Verified empirically by running `echo '{"name":"x"}' | jq '{name:.name, x:(.x // empty)}'` (produces no output).

Use a conditional-merge appended outside the main object literal, with per-item allowlist on `required_secrets[]` (mirrors Task 3's `cliCommands` treatment so unexpected sub-fields can't leak):

The full Task 4 projection (final shape, supersedes Tasks 1-3 — see I-2 fix below):

```jq
({
    name:             $dir_name,
    description:      (.description // ""),
    version:          (.version // ""),
    type:             (.type // ""),
    tier:             (.tier // ""),
    status:           (.status // null),
    license:          (.license // ""),
    author:           (.author // ""),
    keywords:         (.keywords // []),
    private:          (.private // false),
    homepage:         (.homepage // null),
    source:           (.source // null),
    repository:       (.repository // null),
    minEngineVersion: (.minEngineVersion // null),
    assets:           (.assets // null),
    dependencies:     (.dependencies // []),
    capabilities: {
      moduleTypes:      (.capabilities.moduleTypes      // []),
      stepTypes:        (.capabilities.stepTypes        // []),
      triggerTypes:     (.capabilities.triggerTypes     // []),
      workflowHandlers: (.capabilities.workflowHandlers // []),
      wiringHooks:      (.capabilities.wiringHooks      // []),
      migrationDrivers: (.capabilities.migrationDrivers // []),
      iacProvider: (
        if .capabilities.iacProvider == null then null
        else {
          name:                   (.capabilities.iacProvider.name // null),
          resourceTypes:          (.capabilities.iacProvider.resourceTypes // []),
          supportedCanonicalKeys: (.capabilities.iacProvider.supportedCanonicalKeys // [])
        }
        end
      ),
      cliCommands: (
        [(.capabilities.cliCommands // [])[] | {
          name:              (.name // null),
          description:       (.description // null),
          flags_passthrough: (.flags_passthrough // false),
          subcommands:       (.subcommands // [])
        }]
      )
    },
    iacProvider: (
      if .iacProvider == null then null
      else {
        name:               (.iacProvider.name // null),
        resourceTypes:      (.iacProvider.resourceTypes // []),
        computePlanVersion: (.iacProvider.computePlanVersion // null)
      }
      end
    )
  }
  +
  (
    if (.required_secrets // null) == null then {}
    else { required_secrets: [.required_secrets[] | {
      name:        (.name // null),
      sensitive:   (.sensitive // false),
      description: (.description // null),
      prompt:      (.prompt // null)
    }]}
    end
  )
)
```

Three-case semantics:
- key absent → conditional yields `{}`, merge is a no-op, no `required_secrets` key on entry.
- explicit `null` → same (`(.required_secrets // null) == null` is true).
- explicit `[]` → conditional yields `{required_secrets: []}` (the array map over an empty array is `[]`), merged into entry as deliberate "needs no secrets" signal.
- non-empty array → each item projected to the four schema-defined sub-fields (name, sensitive, description, prompt); unexpected sub-fields dropped.

**Step 2: Restructure the find loop for the private filter (full final inline body — I-2 fix)**

The current loop body (lines 28-68) does `summaries+=` then `cp`. Restructure so `cp` runs unconditionally and `summaries+=` is gated by the `private` flag. The projection below is the COMPLETE jq expression from Step 1 — do NOT use a placeholder, expand it inline:

```bash
while IFS= read -r manifest; do
  plugin_name="$(basename "$(dirname "${manifest}")")"

  # Validate readable JSON.
  if ! jq empty "${manifest}" 2>/dev/null; then
    echo "warning: skipping invalid JSON at ${manifest}" >&2
    continue
  fi

  # ALWAYS copy per-plugin manifest, including for private:true.
  # Authenticated wfctl consumers of /v1/plugins/<name>/manifest.json
  # depend on this endpoint working for private plugins too.
  dest_dir="${OUT_DIR}/plugins/${plugin_name}"
  mkdir -p "${dest_dir}"
  cp "${manifest}" "${dest_dir}/manifest.json"
  echo "  copied plugins/${plugin_name}/manifest.json"

  # Private plugins: do NOT append to the public bulk index.
  is_private="$(jq -r '.private // false' "${manifest}")"
  if [[ "${is_private}" == "true" ]]; then
    echo "  skipped (private) plugins/${plugin_name}/"
    continue
  fi

  # G3 markers go here — see Task 6.

  summary="$(jq --arg dir_name "${plugin_name}" '({
    name:             $dir_name,
    description:      (.description // ""),
    version:          (.version // ""),
    type:             (.type // ""),
    tier:             (.tier // ""),
    status:           (.status // null),
    license:          (.license // ""),
    author:           (.author // ""),
    keywords:         (.keywords // []),
    private:          (.private // false),
    homepage:         (.homepage // null),
    source:           (.source // null),
    repository:       (.repository // null),
    minEngineVersion: (.minEngineVersion // null),
    assets:           (.assets // null),
    dependencies:     (.dependencies // []),
    capabilities: {
      moduleTypes:      (.capabilities.moduleTypes      // []),
      stepTypes:        (.capabilities.stepTypes        // []),
      triggerTypes:     (.capabilities.triggerTypes     // []),
      workflowHandlers: (.capabilities.workflowHandlers // []),
      wiringHooks:      (.capabilities.wiringHooks      // []),
      migrationDrivers: (.capabilities.migrationDrivers // []),
      iacProvider: (
        if .capabilities.iacProvider == null then null
        else {
          name:                   (.capabilities.iacProvider.name // null),
          resourceTypes:          (.capabilities.iacProvider.resourceTypes // []),
          supportedCanonicalKeys: (.capabilities.iacProvider.supportedCanonicalKeys // [])
        }
        end
      ),
      cliCommands: (
        [(.capabilities.cliCommands // [])[] | {
          name:              (.name // null),
          description:       (.description // null),
          flags_passthrough: (.flags_passthrough // false),
          subcommands:       (.subcommands // [])
        }]
      )
    },
    iacProvider: (
      if .iacProvider == null then null
      else {
        name:               (.iacProvider.name // null),
        resourceTypes:      (.iacProvider.resourceTypes // []),
        computePlanVersion: (.iacProvider.computePlanVersion // null)
      }
      end
    )
  }
  +
  (
    if (.required_secrets // null) == null then {}
    else { required_secrets: [.required_secrets[] | {
      name:        (.name // null),
      sensitive:   (.sensitive // false),
      description: (.description // null),
      prompt:      (.prompt // null)
    }]}
    end
  ))' "${manifest}")"
  summaries="$(echo "${summaries}" | jq --argjson s "${summary}" '. + [$s]')"
done < <(find "${PLUGINS_DIR}" -name "manifest.json" | sort)
```

(The jq expression above is identical to Step 1's. It's repeated here so the loop body is copy-paste safe and runs standalone, per round-2 M-NEW-1.)

**Step 3: Smoke-run with four fixtures (one private, one with absent `required_secrets` — covers the C-1 regression)**

```bash
mkdir -p /tmp/bi-smoke/plugins/{public-iac,public-simple,public-no-secrets,private-foo}
cat > /tmp/bi-smoke/plugins/public-iac/manifest.json <<'EOF'
{"name":"public-iac","version":"1.0.0","author":"x","description":"x","type":"external","tier":"community","license":"MIT","required_secrets":[{"name":"HOVER_USER","sensitive":false},{"name":"HOVER_PASS","sensitive":true}]}
EOF
cat > /tmp/bi-smoke/plugins/public-simple/manifest.json <<'EOF'
{"name":"public-simple","version":"1.0.0","author":"x","description":"x","type":"external","tier":"community","license":"MIT","required_secrets":[]}
EOF
cat > /tmp/bi-smoke/plugins/public-no-secrets/manifest.json <<'EOF'
{"name":"public-no-secrets","version":"1.0.0","author":"x","description":"x","type":"external","tier":"community","license":"MIT"}
EOF
cat > /tmp/bi-smoke/plugins/private-foo/manifest.json <<'EOF'
{"name":"private-foo","version":"1.0.0","author":"x","description":"x","type":"external","tier":"community","license":"MIT","private":true,"required_secrets":[{"name":"PRIVATE_KEY","sensitive":true}]}
EOF
REPO_ROOT=/tmp/bi-smoke bash <repo>/scripts/build-index.sh

# 3 public entries; private absent
jq 'length' /tmp/bi-smoke/v1/index.json   # 3
jq 'map(.name)' /tmp/bi-smoke/v1/index.json  # ["public-iac","public-no-secrets","public-simple"]

# per-plugin manifest copies for all four
for p in public-iac public-simple public-no-secrets private-foo; do
  test -f /tmp/bi-smoke/v1/plugins/$p/manifest.json && echo "$p cp ok"
done

# required_secrets three-case:
jq '.[] | select(.name=="public-iac") | .required_secrets | length' /tmp/bi-smoke/v1/index.json   # 2
jq '.[] | select(.name=="public-simple") | .required_secrets' /tmp/bi-smoke/v1/index.json         # []
jq '.[] | select(.name=="public-no-secrets") | has("required_secrets")' /tmp/bi-smoke/v1/index.json  # false
```

Expected: 3 public entries; `private-foo` absent; all 4 per-plugin copies present; `public-iac.required_secrets` is a 2-item array of allowlisted sub-fields; `public-simple.required_secrets` is `[]`; `public-no-secrets` entry has NO `required_secrets` key.

**Step 4: Commit**

```bash
git add scripts/build-index.sh
git commit -m "feat(build-index): allowlist required_secrets + skip private plugins from public index"
```

**Rollback:** Revert this commit. Next push to `main` (or repository_dispatch) rebuilds `v1/index.json` to the prior shape. Pure static rebuild, no state, no migrations.

---

### Task 5: Add `tests/test-build-index.sh` (primary projection contract)

**Files:**
- Create: `tests/test-build-index.sh`
- Create: `tests/fixtures/plugins/foo-iac/manifest.json`
- Create: `tests/fixtures/plugins/bar-simple/manifest.json`
- Create: `tests/fixtures/plugins/baz-private/manifest.json`
- Create: `tests/fixtures/plugins/qux-no-secrets/manifest.json`

**Step 1: Write the fixtures**

`tests/fixtures/plugins/foo-iac/manifest.json`:

```json
{
  "name": "workflow-plugin-foo-overrideme",
  "version": "1.2.3",
  "author": "Test",
  "description": "IaC fixture with all the new allowlist fields populated.",
  "type": "external",
  "tier": "community",
  "status": "verified",
  "license": "MIT",
  "homepage": "https://example.com/foo",
  "source": "github.com/example/foo",
  "repository": "https://github.com/example/foo",
  "minEngineVersion": "0.60.0",
  "keywords": ["dns", "iac"],
  "capabilities": {
    "moduleTypes": ["iac.provider.foo"],
    "iacProvider": {
      "name": "foo",
      "resourceTypes": ["infra.dns", "infra.dns_delegation"],
      "supportedCanonicalKeys": ["zone", "record"]
    },
    "cliCommands": [
      {
        "name": "foo",
        "description": "Manage foo DNS",
        "flags_passthrough": true,
        "subcommands": [{"name": "sync", "description": "Sync zone"}]
      }
    ],
    "migrationDrivers": ["foo-migrate"]
  },
  "iacProvider": {
    "name": "foo",
    "resourceTypes": ["infra.dns"],
    "computePlanVersion": "v2"
  },
  "required_secrets": [
    {"name": "FOO_USER", "sensitive": false, "description": "Foo username"},
    {"name": "FOO_PASS", "sensitive": true, "description": "Foo password"}
  ],
  "assets": {"ui": false, "config": true},
  "dependencies": [{"name": "workflow-plugin-bar", "minVersion": "1.0.0"}],
  "checksums": {"1.2.3": "deadbeef"},
  "downloads": [{"os": "linux", "arch": "amd64", "url": "https://x/y"}],
  "contracts": [{"name": "fake-contract"}],
  "extra_undocumented_field": "should_not_leak"
}
```

`tests/fixtures/plugins/bar-simple/manifest.json`:

```json
{
  "name": "bar-simple",
  "version": "0.1.0",
  "author": "Test",
  "description": "Minimal manifest exercising defaults; required_secrets is an explicit empty array.",
  "type": "external",
  "tier": "community",
  "status": "experimental",
  "license": "Apache-2.0",
  "required_secrets": []
}
```

`tests/fixtures/plugins/baz-private/manifest.json`:

```json
{
  "name": "baz-private",
  "version": "0.1.0",
  "author": "Test",
  "description": "Private fixture — must be absent from the index but present in per-plugin manifest copy.",
  "type": "external",
  "tier": "community",
  "license": "MIT",
  "private": true,
  "required_secrets": [{"name": "BAZ_SECRET", "sensitive": true}]
}
```

`tests/fixtures/plugins/qux-no-secrets/manifest.json`:

```json
{
  "name": "qux-no-secrets",
  "version": "0.1.0",
  "author": "Test",
  "description": "Manifest with no required_secrets key at all — exercises the absent-key case that caused C-1.",
  "type": "external",
  "tier": "community",
  "license": "MIT"
}
```

**Step 2: Write the test harness**

`tests/test-build-index.sh`:

```bash
#!/usr/bin/env bash
# tests/test-build-index.sh
#
# Primary projection contract for scripts/build-index.sh. Asserts which
# fields the v1/index.json allowlist surfaces and which it filters out.
# Exits non-zero on any assertion failure.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT_REAL="$(cd "${SCRIPT_DIR}/.." && pwd)"
FIXTURE_DIR="${SCRIPT_DIR}/fixtures"

if ! command -v jq &>/dev/null; then
  echo "error: jq required" >&2
  exit 1
fi

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

# Stage fixtures under a fake REPO_ROOT.
mkdir -p "${tmp}/plugins"
cp -R "${FIXTURE_DIR}/plugins/." "${tmp}/plugins/"

# Run the real build script against the fixture root.
REPO_ROOT="${tmp}" bash "${REPO_ROOT_REAL}/scripts/build-index.sh" >/dev/null

INDEX="${tmp}/v1/index.json"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_jq() {
  local desc="$1" expr="$2" expected="$3"
  local actual
  actual="$(jq -c "${expr}" "${INDEX}")"
  if [[ "${actual}" != "${expected}" ]]; then
    fail "${desc}: expected ${expected}, got ${actual}"
  fi
}

# === Structural assertions ===
assert_jq "index has 3 entries (private filtered)" 'length' '3'
assert_jq "names sorted ascending" 'map(.name)' '["bar-simple","foo-iac","qux-no-secrets"]'

# === Dir-name override ===
assert_jq "foo-iac name comes from dir not manifest" \
  '.[] | select(.name == "foo-iac") | .name' '"foo-iac"'

# === Must-be-present (allowlisted new fields) ===
assert_jq "foo-iac status" '.[] | select(.name=="foo-iac") | .status' '"verified"'
assert_jq "foo-iac homepage" '.[] | select(.name=="foo-iac") | .homepage' '"https://example.com/foo"'
assert_jq "foo-iac source" '.[] | select(.name=="foo-iac") | .source' '"github.com/example/foo"'
assert_jq "foo-iac assets" '.[] | select(.name=="foo-iac") | .assets' '{"ui":false,"config":true}'
assert_jq "foo-iac dependencies len" '.[] | select(.name=="foo-iac") | .dependencies | length' '1'
assert_jq "foo-iac capabilities.iacProvider.name" \
  '.[] | select(.name=="foo-iac") | .capabilities.iacProvider.name' '"foo"'
assert_jq "foo-iac capabilities.iacProvider.resourceTypes" \
  '.[] | select(.name=="foo-iac") | .capabilities.iacProvider.resourceTypes' \
  '["infra.dns","infra.dns_delegation"]'
assert_jq "foo-iac capabilities.iacProvider.supportedCanonicalKeys" \
  '.[] | select(.name=="foo-iac") | .capabilities.iacProvider.supportedCanonicalKeys' \
  '["zone","record"]'
assert_jq "foo-iac capabilities.cliCommands[0].name" \
  '.[] | select(.name=="foo-iac") | .capabilities.cliCommands[0].name' '"foo"'
assert_jq "foo-iac capabilities.cliCommands[0].flags_passthrough" \
  '.[] | select(.name=="foo-iac") | .capabilities.cliCommands[0].flags_passthrough' 'true'
assert_jq "foo-iac capabilities.cliCommands[0].subcommands[0].name" \
  '.[] | select(.name=="foo-iac") | .capabilities.cliCommands[0].subcommands[0].name' '"sync"'
assert_jq "foo-iac capabilities.migrationDrivers" \
  '.[] | select(.name=="foo-iac") | .capabilities.migrationDrivers' '["foo-migrate"]'
assert_jq "foo-iac iacProvider.computePlanVersion" \
  '.[] | select(.name=="foo-iac") | .iacProvider.computePlanVersion' '"v2"'
assert_jq "foo-iac required_secrets has 2 items" \
  '.[] | select(.name=="foo-iac") | .required_secrets | length' '2'

# === Empty-array preservation ===
assert_jq "bar-simple required_secrets preserved as []" \
  '.[] | select(.name=="bar-simple") | .required_secrets' '[]'
assert_jq "bar-simple status" \
  '.[] | select(.name=="bar-simple") | .status' '"experimental"'

# === Absent-key omission (C-1 regression coverage) ===
assert_jq "qux-no-secrets is present in index" \
  'map(.name) | contains(["qux-no-secrets"])' 'true'
if jq -e '.[] | select(.name=="qux-no-secrets") | has("required_secrets")' "${INDEX}" >/dev/null; then
  fail "qux-no-secrets should have no required_secrets key (manifest omits it); C-1 regression"
fi

# === required_secrets per-item allowlist (extras dropped) ===
assert_jq "required_secrets[0] item has exactly 4 known keys" \
  '.[] | select(.name=="foo-iac") | .required_secrets[0] | keys_unsorted | sort' \
  '["description","name","prompt","sensitive"]'

# === Per-item allowlist on cliCommands (extras dropped) ===
assert_jq "cliCommands item has exactly 4 known keys" \
  '.[] | select(.name=="foo-iac") | .capabilities.cliCommands[0] | keys_unsorted | sort' \
  '["description","flags_passthrough","name","subcommands"]'

# === Security: excluded fields MUST NOT appear ===
for excluded_field in downloads checksums contracts extra_undocumented_field path serviceMethods portIntrospect configProvider; do
  if jq -e ".[] | select(.name==\"foo-iac\") | has(\"${excluded_field}\")" "${INDEX}" >/dev/null; then
    fail "G3 allowlist regression: index leaked excluded field '${excluded_field}'; remove from build-index.sh projection or extend allowlist explicitly"
  fi
done

# === capabilities.buildHooks must not appear ===
if jq -e '.[] | select(.name=="foo-iac") | .capabilities | has("buildHooks")' "${INDEX}" >/dev/null; then
  fail "G3 allowlist regression: capabilities.buildHooks leaked into index"
fi

# === Private plugin handling: ABSENT from index, PRESENT as per-plugin copy ===
if jq -e '.[] | select(.name=="baz-private")' "${INDEX}" >/dev/null; then
  fail "private plugin baz-private leaked into public index"
fi
test -f "${tmp}/v1/plugins/baz-private/manifest.json" || \
  fail "private plugin baz-private per-plugin manifest copy missing"
test -f "${tmp}/v1/plugins/foo-iac/manifest.json" || fail "foo-iac per-plugin manifest copy missing"
test -f "${tmp}/v1/plugins/bar-simple/manifest.json" || fail "bar-simple per-plugin manifest copy missing"
test -f "${tmp}/v1/plugins/qux-no-secrets/manifest.json" || fail "qux-no-secrets per-plugin manifest copy missing"

# === Byte-identity for per-plugin manifest copies (per design spec line 249) ===
# Future refactor that swaps raw `cp` for a jq-projected write would break
# wfctl plugin install (which depends on full-fidelity per-plugin manifests).
for f in foo-iac bar-simple baz-private qux-no-secrets; do
  cmp --silent "${FIXTURE_DIR}/plugins/$f/manifest.json" "${tmp}/v1/plugins/$f/manifest.json" \
    || fail "per-plugin manifest copy for $f is not byte-identical to source"
done

echo "OK — test-build-index.sh passed"
```

**Step 3: Run + verify the test passes**

```bash
chmod +x tests/test-build-index.sh
bash tests/test-build-index.sh
```

Expected: `OK — test-build-index.sh passed`. Exit code 0.

**Step 4: Verify test FAILS when projection is broken (sanity check)**

Temporarily remove `status:` line from the jq projection in `scripts/build-index.sh`. Re-run the test. Expected: `FAIL: foo-iac status: expected "verified", got null`. Restore the line. Re-run. Expected: PASS. Do NOT commit the temporary break.

**Step 5: Commit**

```bash
git add tests/test-build-index.sh tests/fixtures/
git commit -m "test(build-index): primary projection contract — assert present/absent allowlist"
```

---

### Task 6: Add G3-include/G3-exclude marker comments to `build-index.sh`

**Files:**
- Modify: `scripts/build-index.sh` (add comment block above the jq projection)

**Step 1: Insert marker block**

Immediately before the `summary="$(jq ...` line, insert (use dot-qualified schema-relative names per the design's Marker format convention):

```bash
  # Allowlisted summary projection — see docs/plans/2026-05-21-build-index-inline-manifest-design.md.
  # Every schema-allowed field below must appear here as G3-include OR G3-exclude.
  # tests/test-schema-allowlist-coverage.sh enforces this on every PR.
  # Marker format: dot-qualified, schema-relative (e.g. capabilities.iacProvider.name).
  #
  # G3-include: name
  # G3-include: version
  # G3-include: author
  # G3-include: description
  # G3-include: source
  # G3-include: type
  # G3-include: tier
  # G3-include: status
  # G3-include: license
  # G3-include: minEngineVersion
  # G3-include: keywords
  # G3-include: homepage
  # G3-include: repository
  # G3-include: private
  # G3-include: assets
  # G3-include: dependencies
  # G3-include: required_secrets
  # G3-include: capabilities
  # G3-include: capabilities.moduleTypes
  # G3-include: capabilities.stepTypes
  # G3-include: capabilities.triggerTypes
  # G3-include: capabilities.workflowHandlers
  # G3-include: capabilities.wiringHooks
  # G3-include: capabilities.migrationDrivers
  # G3-include: capabilities.iacProvider
  # G3-include: capabilities.iacProvider.name
  # G3-include: capabilities.iacProvider.resourceTypes
  # G3-include: capabilities.iacProvider.supportedCanonicalKeys
  # G3-include: capabilities.cliCommands
  # G3-include: capabilities.cliCommands.name
  # G3-include: capabilities.cliCommands.description
  # G3-include: capabilities.cliCommands.flags_passthrough
  # G3-include: capabilities.cliCommands.subcommands
  # G3-include: iacProvider
  # G3-include: iacProvider.name
  # G3-include: iacProvider.resourceTypes
  # G3-include: iacProvider.computePlanVersion
  #
  # G3-exclude: path — wfctl-internal subpackage path, not user-facing
  # G3-exclude: downloads — stale relative to build-versions.sh latest.json
  # G3-exclude: checksums — belongs in versions.json next to download list
  # G3-exclude: capabilities.buildHooks — wfctl-internal build-time hook list
```

**Step 2: Smoke-run** (the markers are comments; behavior unchanged)

```bash
bash tests/test-build-index.sh
```

Expected: PASS.

**Step 3: Commit**

```bash
git add scripts/build-index.sh
git commit -m "docs(build-index): G3-include/G3-exclude markers for schema-drift guard"
```

---

### Task 7: Add `tests/test-schema-allowlist-coverage.sh` (informational drift guard)

**Files:**
- Create: `tests/test-schema-allowlist-coverage.sh`

**Step 1: Write the script**

`tests/test-schema-allowlist-coverage.sh`:

```bash
#!/usr/bin/env bash
# tests/test-schema-allowlist-coverage.sh
#
# Bidirectional drift guard between schema/registry-schema.json and the
# G3-include/G3-exclude markers in scripts/build-index.sh.
#
# Forward (schema → markers): every schema property in the in-scope set
#   must have a decision marker. Catches: someone added a field to the
#   schema, forgot to triage it for the public index.
# Reverse (markers → schema): every marker must correspond to a real
#   schema property. Catches: phantom markers for fields that don't exist.
#
# In-scope properties:
#   - Top-level properties of the schema
#   - capabilities.* direct children
#   - capabilities.iacProvider.* (name, resourceTypes, supportedCanonicalKeys)
#   - capabilities.cliCommands.items.* (name, description, flags_passthrough, subcommands)
#   - iacProvider.* (top-level — name, resourceTypes, computePlanVersion)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SCHEMA="${REPO_ROOT}/schema/registry-schema.json"
BUILD_SCRIPT="${REPO_ROOT}/scripts/build-index.sh"

if ! command -v jq &>/dev/null; then
  echo "error: jq required" >&2
  exit 1
fi

# Per round-2 M-NEW-2: explicit input-file existence guard. Without this,
# a missing or moved schema file silently produces empty schema_props
# output and the script exits 0 (false-pass).
if [[ ! -f "${SCHEMA}" ]]; then
  echo "error: schema file not found at ${SCHEMA}" >&2
  exit 1
fi
if [[ ! -f "${BUILD_SCRIPT}" ]]; then
  echo "error: build script not found at ${BUILD_SCRIPT}" >&2
  exit 1
fi

# Extract schema property paths in dot-qualified form. Each nested path
# uses `// {}` so a future schema refactor (e.g. switching iacProvider to
# a $ref) returns an empty container instead of jq's "null has no keys"
# error — which is then caught by the line-count guard below.
schema_props() {
  jq -r '
    [
      ((.properties // {}) | keys[]),
      ((.properties.capabilities.properties // {}) | keys[] | "capabilities." + .),
      ((.properties.capabilities.properties.iacProvider.properties // {}) | keys[] | "capabilities.iacProvider." + .),
      ((.properties.capabilities.properties.cliCommands.items.properties // {}) | keys[] | "capabilities.cliCommands." + .),
      ((.properties.iacProvider.properties // {}) | keys[] | "iacProvider." + .)
    ] | .[]
  ' "${SCHEMA}" | sort -u
}

# Extract marker decisions from build script.
marker_decisions() {
  grep -E '^[[:space:]]*#[[:space:]]*G3-(include|exclude):' "${BUILD_SCRIPT}" \
    | sed -E 's/^[[:space:]]*#[[:space:]]*G3-(include|exclude):[[:space:]]*([^[:space:]]+).*/\2/' \
    | sort -u
}

schema_set="$(mktemp)"
marker_set="$(mktemp)"
trap 'rm -f "${schema_set}" "${marker_set}"' EXIT

schema_props > "${schema_set}"
marker_decisions > "${marker_set}"

# Per round-2 I-NEW-1: explicit empty-output guard. `func > file` does
# NOT reliably propagate the function's non-zero exit through `set -e`
# (empirically verified). Without this guard, a jq parse error or
# null-key crash produces an empty schema_set and the forward-trace loop
# silently iterates zero times, returning OK — defeating the drift
# guard's purpose on the day it would matter most.
if [[ ! -s "${schema_set}" ]]; then
  echo "FAIL: schema_props() produced no output — schema structure may have changed (path traversal hit a null), or jq failed silently" >&2
  exit 1
fi
if [[ ! -s "${marker_set}" ]]; then
  echo "FAIL: no G3-include/G3-exclude markers found in ${BUILD_SCRIPT}; was Task 6 applied?" >&2
  exit 1
fi

fail=0

# Forward trace: schema → markers.
while IFS= read -r prop; do
  if ! grep -Fxq "${prop}" "${marker_set}"; then
    echo "FAIL: schema field '${prop}' has no allow/exclude decision in build-index.sh; add '# G3-include: ${prop}' or '# G3-exclude: ${prop} — <reason>'" >&2
    fail=1
  fi
done < "${schema_set}"

# Reverse trace: markers → schema.
while IFS= read -r marker; do
  if ! grep -Fxq "${marker}" "${schema_set}"; then
    echo "FAIL: build-index.sh marker '${marker}' does not correspond to a schema property — remove it (or fix typo)" >&2
    fail=1
  fi
done < "${marker_set}"

if [[ "${fail}" -ne 0 ]]; then
  exit 1
fi

echo "OK — test-schema-allowlist-coverage.sh passed ($(wc -l < "${schema_set}" | tr -d ' ') schema props ↔ $(wc -l < "${marker_set}" | tr -d ' ') markers)"
```

**Step 2: Run + verify**

```bash
chmod +x tests/test-schema-allowlist-coverage.sh
bash tests/test-schema-allowlist-coverage.sh
```

Expected: `OK — test-schema-allowlist-coverage.sh passed (NN schema props ↔ NN markers)`. Exit 0.

**Step 3: Sanity-check both failure modes**

a. Forward-trace failure: add a fake property to the schema temporarily:

```bash
jq '.properties.fakeProp = {"type":"string"}' schema/registry-schema.json > /tmp/sch.json && mv /tmp/sch.json schema/registry-schema.json
bash tests/test-schema-allowlist-coverage.sh
# Expected: FAIL: schema field 'fakeProp' has no allow/exclude decision...
git checkout schema/registry-schema.json
```

b. Reverse-trace failure: add a phantom marker temporarily:

```bash
sed -i.bak 's|# G3-include: name|# G3-include: name\n  # G3-include: fakeMarker|' scripts/build-index.sh
bash tests/test-schema-allowlist-coverage.sh
# Expected: FAIL: build-index.sh marker 'fakeMarker' does not correspond...
mv scripts/build-index.sh.bak scripts/build-index.sh
```

c. Silent-pass guard (round-2 I-NEW-1 regression coverage): temporarily mangle the schema path to make jq return empty:

```bash
cp schema/registry-schema.json schema/registry-schema.json.bak
echo '{}' > schema/registry-schema.json
bash tests/test-schema-allowlist-coverage.sh
# Expected: FAIL: schema_props() produced no output...
# (NOT: "OK — passed (0 schema props ↔ N markers)")
mv schema/registry-schema.json.bak schema/registry-schema.json
```

Re-run final pass — expected: PASS, exit 0. Do NOT commit any of the three temporary breaks.

**Step 4: Commit**

```bash
git add tests/test-schema-allowlist-coverage.sh
git commit -m "test(build-index): bidirectional schema↔allowlist drift guard"
```

---

### Task 8: Wire the two tests into `.github/workflows/validate.yml`

**Files:**
- Modify: `.github/workflows/validate.yml`

**Step 1: Read the current workflow**

```bash
cat .github/workflows/validate.yml
```

Determine the existing job structure (validate-manifests is Node-based per the design).

**Step 2: Add a new `validate-index-projection` job**

Append (or insert as a parallel job to `validate-manifests`) — exact YAML to add:

```yaml
  validate-index-projection:
    name: Validate v1/index.json allowlist projection
    runs-on: ubuntu-latest
    permissions:
      contents: read
    steps:
      - uses: actions/checkout@v4

      - name: Install jq (Ubuntu ships with it but verify)
        run: |
          if ! command -v jq >/dev/null; then
            sudo apt-get update && sudo apt-get install -y jq
          fi
          jq --version

      - name: Run primary projection contract
        run: bash tests/test-build-index.sh

      - name: Run schema↔allowlist drift guard
        run: bash tests/test-schema-allowlist-coverage.sh
```

**Step 3: Validate YAML syntax**

```bash
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/validate.yml'))"
```

Expected: no output (parses cleanly).

**Step 4: Run all CI scripts locally one more time end-to-end**

```bash
bash tests/test-build-index.sh
bash tests/test-schema-allowlist-coverage.sh
```

Expected: both pass.

**Step 5: Commit + push**

```bash
git add .github/workflows/validate.yml
git commit -m "ci: run build-index projection + schema-drift tests on every PR"
git push -u origin feat/build-index-extended-summary
```

**Verification (runtime-launch class — CI workflow change):**

Per the verification-per-change-class rule, a CI-workflow change is verified by the change running on an actual PR. Open the PR (`gh pr create`); confirm the new `validate-index-projection` job appears in the PR check list and passes. If it doesn't pass on the PR, that's the trigger for fixing it before merge — not a separate task.

**Rollback:** Revert the PR. CI returns to prior shape. No artifact state, no production impact.

---

## Verification summary

| Task | Change class | Verification |
|---|---|---|
| 1 | Internal-logic (script edit) | smoke jq one-liner + Task 5 test |
| 2 | Internal-logic (script edit) | smoke jq one-liner + Task 5 test |
| 3 | Internal-logic (script edit) | smoke jq one-liner + Task 5 test |
| 4 | Internal-logic (script edit) | 3-fixture smoke + Task 5 test |
| 5 | New test | `bash tests/test-build-index.sh` returns 0 |
| 6 | Documentation comments | drift guard from Task 7 catches inconsistencies |
| 7 | New test | `bash tests/test-schema-allowlist-coverage.sh` returns 0 + sanity-check both failure modes |
| 8 | CI workflow | YAML parses + both scripts pass locally; PR-run is the final verification |

## Rollback (overall)

Single revert PR returns `v1/index.json` to the prior shape on next push. No client-side cache to expire, no migrations, no state. Blast radius bounded to GH Pages contents.
