# Dispatch-Triggered Single-Plugin Sync Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Make the existing `repository_dispatch: [plugin-release]` listener actually filter the sync to one plugin when fired (vs scanning all). Closes G2 / workflow-registry#79 Piece 2.

**Architecture:** Single workflow file edit. Branch on `${{ github.event_name }}` to switch between cron-all-plugins and dispatch-single-plugin paths. The `client_payload.plugin` value is passed via env var, NOT inline interpolated (prevents script injection). Job-level `concurrency:` group serialises same-plugin dispatches.

**Tech Stack:** GitHub Actions YAML. No language runtime.

**Base branch:** main

**Working branch:** feat/dispatch-sync (worktree `_worktrees/g2-dispatch-sync`)

**Design doc:** `docs/plans/2026-05-21-dispatch-sync-design.md`

## Current-state corrections (from round-1 plan-phase review)

Three findings revised the plan baseline (verified against the actual file):

1. **`repository_dispatch: types: [plugin-release, workflow-release]` already exists** on the workflow. No new `on:` trigger needed; the listener is in place. The plan adds *filter logic*, not a new event.
2. **Existing sync step runs THREE scripts**: `sync-versions.sh --fix` + `sync-core-manifests.sh --fix` + `generate-readme.sh`, and diff-checks `plugins README.md`. The single-plugin path keeps `sync-versions.sh --fix --plugin <name>` + `generate-readme.sh` (README reflects the new manifest), and *skips* `sync-core-manifests.sh` (that script syncs engine-plugin manifests sourced from a separate `_workflow` checkout and is irrelevant to a single external-plugin dispatch).
3. **Script-injection risk**: inline `${{ github.event.client_payload.plugin }}` rendered into bash is exploitable. Use env-var pattern (`env: PLUGIN_INPUT: …` then `"${PLUGIN_INPUT}"` in bash) per [GitHub's documented mitigation](https://docs.github.com/en/actions/security-for-github-actions/security-guides/security-hardening-for-github-actions#using-an-intermediate-environment-variable).

---

## Scope Manifest

**PR Count:** 1
**Tasks:** 4
**Estimated Lines of Change:** ~55 (informational)

**Out of scope:**
- Plugin-side `notify-registry` step (= G1, separate workstream / sweep across N plugin repos)
- Changes to `build-pages.yml` (already accepts dispatch + rebuilds; manifest-update path is `sync-registry-manifests.yml` only)
- Changes to `sync-versions.sh` (already supports `--plugin <name>` filter at line 22-29)
- Modifications to the cron / all-plugin path (it stays bit-identical for cron firings)
- `workflow-release` dispatch handling (existing event type, separate consumer; this PR only touches the `plugin-release` filter path)

**PR Grouping:**

| PR # | Title | Tasks | Branch |
|------|-------|-------|--------|
| 1 | sync-registry-manifests: filter to single plugin on dispatch | Task 1, Task 2, Task 3, Task 4 | feat/dispatch-sync |

**Status:** Draft

---

### Task 1: Add `workflow_dispatch.inputs.plugin` + job-level concurrency group + conditional `_workflow` checkout + Go setup

**Files:**
- Modify: `.github/workflows/sync-registry-manifests.yml`

**Step 1: Extend `workflow_dispatch:`**

Replace the bare `workflow_dispatch:` line:

```yaml
  workflow_dispatch:
```

with:

```yaml
  workflow_dispatch:
    inputs:
      plugin:
        description: 'Plugin directory name (optional; if set, syncs only that plugin)'
        required: false
        default: ''
```

This lets a human exercise the single-plugin path from the Actions UI without a real release.

**Step 2: Add a job-level `concurrency` block**

Above `runs-on: ubuntu-latest` inside the `sync:` job, insert:

```yaml
    concurrency:
      group: sync-${{ github.event.client_payload.plugin || github.event.inputs.plugin || 'all' }}
      cancel-in-progress: false
```

The group key is the plugin name when filtered, or `all` for cron/full runs. Same-plugin concurrent dispatches now serialise at the Actions scheduler level — the second run waits for the first to finish before starting. Different-plugin dispatches run in parallel.

**Step 3: Add `if:` guards to the `_workflow` checkout + Go setup steps (Option 2 from round-3 review)**

Both steps only exist to support `sync-core-manifests.sh` on the cron / full-run path. On a dispatch path (real-time, latency-sensitive), they waste ~30-45 s of runner time. Add a guard.

Modify the existing two steps:

```yaml
      - name: Check out workflow
        if: github.event_name != 'repository_dispatch' && github.event.inputs.plugin == ''
        uses: actions/checkout@v4
        with:
          repository: GoCodeAlone/workflow
          path: _workflow

      - name: Set up Go
        if: github.event_name != 'repository_dispatch' && github.event.inputs.plugin == ''
        uses: actions/setup-go@v5
        with:
          go-version: '1.26'
          cache-dependency-path: _workflow/go.sum
```

The dispatch path bypasses both. The cron path (`event_name == 'schedule'`) keeps both. The workflow_dispatch path runs them only when no plugin input is set (i.e. the user wanted a full-run from the UI).

**Step 4: Validate YAML**

```bash
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/sync-registry-manifests.yml'))"
```

Expected: silent, exit 0.

**Step 5: Commit**

```bash
git add .github/workflows/sync-registry-manifests.yml
git commit -m "ci(sync-registry): workflow_dispatch plugin input + concurrency group + skip _workflow on dispatch"
```

---

### Task 2: Add `Resolve plugin filter` step with env-var-sanitised input

**Files:**
- Modify: `.github/workflows/sync-registry-manifests.yml`

**Step 1: Insert new step BEFORE "Detect and update drifted manifests"**

After the "Set up Go" step, insert:

```yaml
      - name: Resolve plugin filter from event
        id: filter
        # Per round-1 C-1: do NOT inline ${{ ... }} into bash. Read from env.
        env:
          PLUGIN_FROM_DISPATCH: ${{ github.event.client_payload.plugin }}
          PLUGIN_FROM_INPUT:    ${{ github.event.inputs.plugin }}
          EVENT_NAME:           ${{ github.event_name }}
        run: |
          set -euo pipefail
          plugin=""
          case "${EVENT_NAME}" in
            repository_dispatch)
              plugin="${PLUGIN_FROM_DISPATCH}"
              ;;
            workflow_dispatch)
              plugin="${PLUGIN_FROM_INPUT}"
              ;;
          esac
          # Defensive validation: only allow [A-Za-z0-9._-]+, no path separators.
          # Belt-and-suspenders even though concurrency group already ate the
          # raw value (Actions sanitises keys; runner bash is the threat
          # surface).
          if [[ -n "${plugin}" ]]; then
            if [[ ! "${plugin}" =~ ^[A-Za-z0-9._-]+$ ]]; then
              echo "::warning::rejecting plugin name '${plugin}' (invalid characters)"
              echo "skip=1" >> "$GITHUB_OUTPUT"
              echo "plugin=" >> "$GITHUB_OUTPUT"
              exit 0
            fi
            if [[ ! -d "plugins/${plugin}" ]]; then
              echo "::warning::plugin '${plugin}' has no directory under plugins/; skipping"
              echo "skip=1" >> "$GITHUB_OUTPUT"
              echo "plugin=" >> "$GITHUB_OUTPUT"
              exit 0
            fi
          fi
          echo "plugin=${plugin}" >> "$GITHUB_OUTPUT"
          echo "skip=0" >> "$GITHUB_OUTPUT"
```

Three defensive layers, in order:

1. `env:` extraction → expression-layer sanitisation; the value never enters the bash source as a literal.
2. Regex whitelist `^[A-Za-z0-9._-]+$` → command-substitution/shell-meta chars rejected even though they couldn't reach bash via the env path.
3. `[[ -d plugins/${plugin} ]]` → must be a known plugin; unknown names warn-and-skip rather than failing the workflow run (a misfire from a not-yet-registered plugin should not break the registry).

Note on concurrency group key (per round-2 M-2): the `concurrency:` block evaluates `${{ github.event.client_payload.plugin || ... || 'all' }}` server-side as an opaque string. Actions does NOT sanitise the key — it locks against the literal string. A malformed payload produces an unusual-looking group key but no execution effect at that layer. The bash step here IS the real sanitisation boundary; the concurrency block only serialises by whatever key it gets.

**Step 2: Validate YAML**

```bash
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/sync-registry-manifests.yml'))"
```

Expected: silent, exit 0.

**Step 3: Commit**

```bash
git add .github/workflows/sync-registry-manifests.yml
git commit -m "ci(sync-registry): resolve plugin filter via env-var (anti-injection)"
```

---

### Task 3: Branch sync step + PR step on filter, preserve cron path

**Files:**
- Modify: `.github/workflows/sync-registry-manifests.yml`

**Step 1: Replace "Detect and update drifted manifests" step body**

Existing body runs three scripts unconditionally. Replace with a branching version:

```yaml
      - name: Detect and update drifted manifests
        if: steps.filter.outputs.skip != '1'
        id: sync
        env:
          PLUGIN: ${{ steps.filter.outputs.plugin }}
        run: |
          set -euo pipefail
          if [[ -n "${PLUGIN}" ]]; then
            echo "syncing single plugin: ${PLUGIN}"
            scripts/sync-versions.sh --fix --plugin "${PLUGIN}"
            # Skip sync-core-manifests.sh on filter path — that script
            # syncs engine plugins sourced from the _workflow checkout
            # and is irrelevant to an external-plugin dispatch.
            scripts/generate-readme.sh
          else
            echo "syncing all plugins (cron / full run)"
            scripts/sync-versions.sh --fix
            WORKFLOW_REPO="$GITHUB_WORKSPACE/_workflow" scripts/sync-core-manifests.sh --fix
            scripts/generate-readme.sh
          fi
          if git diff --quiet -- plugins README.md; then
            echo "changed=0" >> "$GITHUB_OUTPUT"
          else
            echo "changed=1" >> "$GITHUB_OUTPUT"
          fi
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          PLUGIN:   ${{ steps.filter.outputs.plugin }}
```

Note: keep BOTH env entries — `GH_TOKEN` for `gh` calls inside the script, `PLUGIN` for the branching. (YAML accepts duplicate `env:` keys per step but it's cleaner to merge — fix below.)

Actually, merge to a single `env:` block:

```yaml
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          PLUGIN:   ${{ steps.filter.outputs.plugin }}
```

Place it ONCE, after the `run:` block. Drop the duplicate.

**Step 2: Replace "Open PR if manifests changed" step body**

```yaml
      - name: Open PR if manifests changed
        # I-5 (round-3): the && skip guard is REQUIRED. Without it, a
        # skip=1 filter result causes the sync step to be skipped, which
        # leaves steps.sync.outputs.changed as the empty string. The
        # naked `!= '0'` check is true for empty strings, so the PR step
        # would run with PLUGIN="", fall into the cron-path else branch,
        # and crash on `git commit` with "nothing to commit". Belt-and-
        # suspenders: mirror the sync step's own skip guard here.
        if: steps.sync.outputs.changed != '0' && steps.filter.outputs.skip != '1'
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          PLUGIN:   ${{ steps.filter.outputs.plugin }}
        run: |
          set -euo pipefail
          DATE=$(date +%Y-%m-%d)

          if [[ -n "${PLUGIN}" ]]; then
            # Dispatch / single-plugin path. Concurrency group already
            # ensures only one run executes per plugin at a time, so the
            # branch-collision race is structurally eliminated. Branch
            # name still includes the plugin-version for clarity.
            version="$(jq -r '.version' "plugins/${PLUGIN}/manifest.json")"
            version="${version#v}"   # belt-and-suspenders strip in case .version is v-prefixed
            BRANCH="chore/sync-${PLUGIN}-v${version}"
            TITLE="chore: sync ${PLUGIN} to v${version}"
            BODY="Triggered by repository_dispatch (event_type=plugin-release) for plugin '${PLUGIN}'. Updates \`plugins/${PLUGIN}/manifest.json\` to match the latest GitHub release. Auto-generated by sync-registry-manifests workflow. Refs GoCodeAlone/workflow-registry#79."
          else
            # Cron / full-run path — unchanged from prior behaviour.
            BRANCH="chore/sync-registry-manifests-${DATE}"
            TITLE="chore: sync registry manifests to latest plugin releases (${DATE})"
            BODY="Registry drift check detected plugin release, workflow core plugin, or README index changes. Auto-generated by sync-registry-manifests workflow. Closes GoCodeAlone/workflow-registry#37."
          fi

          git config user.email "github-actions[bot]@users.noreply.github.com"
          git config user.name  "github-actions[bot]"

          # Re-run / stale-branch handling (per round-2 I-4):
          # The concurrency group serialises same-plugin runs at the
          # scheduler level, so two simultaneous dispatches can't both
          # be in this step. But a developer can manually re-run a
          # previously-failed workflow run via the Actions UI, in which
          # case the branch from the failed run may still exist on the
          # remote. Detect that and reset it cleanly here, BEFORE the
          # local checkout + push, instead of letting `git push` fail
          # non-fast-forward.
          if git ls-remote --exit-code --heads origin "${BRANCH}" >/dev/null 2>&1; then
            echo "branch ${BRANCH} exists on remote (likely a previous failed run); resetting it"
            git push origin --delete "${BRANCH}"
          fi

          git checkout -b "${BRANCH}"
          git add plugins/ README.md
          git commit -m "${TITLE}"
          git push origin "${BRANCH}"

          # Reuse existing PR if one is open (e.g. branch was deleted +
          # recreated; closed-then-reopened scenario is rare but covered).
          existing="$(gh pr list --head "${BRANCH}" --state open --json number --jq '.[0].number // empty')"
          if [[ -n "${existing}" ]]; then
            echo "PR #${existing} already open for ${BRANCH}; new commit pushed."
            exit 0
          fi
          gh pr create --base main --head "${BRANCH}" --title "${TITLE}" --body "${BODY}"
```

**Step 3: Validate YAML**

```bash
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/sync-registry-manifests.yml'))"
```

Expected: silent, exit 0.

**Step 4: Sanity check that cron path is unchanged**

`diff` the cron path block against the original step body:

```bash
git diff main -- .github/workflows/sync-registry-manifests.yml | grep -E "sync-core-manifests|generate-readme" || echo "no cron-path regression"
```

Expected: both lines still present in the `else` branch (cron path); no surprising deletions.

**Step 5: Commit**

```bash
git add .github/workflows/sync-registry-manifests.yml
git commit -m "ci(sync-registry): single-plugin sync + dispatch-shaped PR"
```

**Rollback:** revert the PR. No persistent state.

---

### Task 4: Push branch + open PR + add Copilot + manual workflow_dispatch validation

**Files:**
- None (CI / PR / validation actions only)

**Step 1: Push branch**

```bash
git push -u origin feat/dispatch-sync
```

**Step 2: Open PR**

```bash
gh pr create \
  --base main \
  --title "ci(sync-registry): single-plugin sync on plugin-release dispatch (G2 / #79 Piece 2)" \
  --body "$(cat <<'EOF'
## Summary

The existing `sync-registry-manifests.yml` workflow already listens on `repository_dispatch: [plugin-release]` (since #37), but does a full scan-all sweep regardless of trigger. This PR adds filter logic so a `client_payload.plugin=<name>` dispatch syncs only that plugin and opens a plugin-scoped PR. Closes G2 / refs #79.

## Mechanism

- New `workflow_dispatch.inputs.plugin` lets humans exercise the single-plugin path from the Actions UI.
- New `Resolve plugin filter from event` step reads `client_payload.plugin` (or input) via env var (no inline `${{ ... }}` in bash — anti-injection), validates against a `[A-Za-z0-9._-]+` whitelist + `plugins/<name>/` directory existence, sets a step output.
- Sync step branches on the filter: filtered → `sync-versions.sh --fix --plugin <name>` + `generate-readme.sh`. Cron / full → unchanged (three-script sweep).
- PR step uses a plugin+version branch + title on the filtered path; cron path keeps the date-based branch shape.
- Job-level `concurrency: group: sync-<plugin-or-all>` serialises same-plugin dispatches at the Actions scheduler level.

## Security

`client_payload.plugin` is passed via `env:`, not inline-interpolated. A malicious dispatcher cannot inject shell commands. The plugin name is also regex-validated before any filesystem reference.

## Validation

- YAML parses.
- Manual workflow_dispatch with `plugin=hover` (in-sync at v0.2.0) will execute the filter path → no changes → no PR opens.

## Scope

This is **G2 / Piece 2** of #79. **G1 / Piece 1** (plugin repos firing the dispatch) is a separate workstream sweeping the notify step across plugin release.yml files.
EOF
)"
```

**Step 3: Add Copilot reviewer**

```bash
PR=$(gh pr view --json number --jq '.number')
gh pr edit "$PR" --add-reviewer @copilot
```

**Step 4: Manual workflow_dispatch smoke (no-op path)**

After CI passes — and BEFORE merge — fire the workflow against the PR branch with `plugin=hover` (in sync at v0.2.0). Confirm the workflow runs the single-plugin path and exits cleanly without opening a PR.

```bash
gh workflow run sync-registry-manifests.yml --ref feat/dispatch-sync -f plugin=hover
sleep 60
gh run list --workflow sync-registry-manifests.yml --branch feat/dispatch-sync --limit 1 --json status,conclusion,databaseId
```

Expected: `status: completed, conclusion: success`. Then check the run log for `syncing single plugin: hover` and absence of any new `chore/sync-hover-*` branch.

**Step 5: Report back**

Print PR number + URL + manual-dispatch run conclusion + the relevant log line.

**Verification (CI workflow change):** the change runs on the PR through GitHub Actions infrastructure; the manual dispatch is the runtime-launch-validation step.

**Rollback:** revert the PR. No state.

---

## Verification summary

| Task | Change class | Verification |
|---|---|---|
| 1 | CI YAML edit | YAML parse + Task 4 dispatch |
| 2 | CI YAML edit | YAML parse + Task 4 dispatch + step.outputs visible in run log |
| 3 | CI YAML edit | YAML parse + Task 4 dispatch + cron-path diff sanity |
| 4 | CI / PR | Manual workflow_dispatch returns `success`; run log shows `syncing single plugin: hover` |

## Rollback (overall)

Single PR revert. The new filter + concurrency are additive; reverting removes them. No persistent state.
