# Dispatch-Triggered Single-Plugin Sync Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add `repository_dispatch: [plugin-release]` event handling to `sync-registry-manifests.yml` so plugin tags trigger immediate single-plugin sync + PR. Closes G2 / workflow-registry#79 Piece 2.

**Architecture:** Single workflow file edit. Branch on `${{ github.event_name }}` to switch between cron-all-plugins and dispatch-single-plugin paths. Script (`scripts/sync-versions.sh`) already supports `--plugin <name>`; no script change needed.

**Tech Stack:** GitHub Actions YAML. No language runtime.

**Base branch:** main

**Working branch:** feat/dispatch-sync (worktree `_worktrees/g2-dispatch-sync`)

**Design doc:** `docs/plans/2026-05-21-dispatch-sync-design.md`

---

## Scope Manifest

**PR Count:** 1
**Tasks:** 3
**Estimated Lines of Change:** ~45 (informational)

**Out of scope:**
- Plugin-side `notify-registry` step (= G1, separate workstream / sweep across N plugin repos)
- Changes to `build-pages.yml` (already accepts dispatch + rebuilds; the missing piece was source-manifest update which `sync-registry-manifests.yml` owns)
- Multi-plugin batching from a single dispatch
- Changes to `scripts/sync-versions.sh` (already supports `--plugin <name>` filter)

**PR Grouping:**

| PR # | Title | Tasks | Branch |
|------|-------|-------|--------|
| 1 | sync-registry-manifests: react to plugin-release dispatch | Task 1, Task 2, Task 3 | feat/dispatch-sync |

**Status:** Draft

---

### Task 1: Add `repository_dispatch: [plugin-release]` trigger + plugin-name guard

**Files:**
- Modify: `.github/workflows/sync-registry-manifests.yml`

**Step 1: Edit `on:` triggers**

Add `repository_dispatch: types: [plugin-release]` between `schedule` and `workflow_dispatch`:

```yaml
on:
  schedule:
    - cron: '0 6 * * *'   # daily at 06:00 UTC
  repository_dispatch:
    types: [plugin-release]
  workflow_dispatch:
    inputs:
      plugin:
        description: 'Plugin directory name (optional; if set, syncs only that plugin)'
        required: false
        default: ''
```

(The new `workflow_dispatch.inputs.plugin` lets a human trigger a single-plugin sync from the Actions UI without a real release event — useful for testing.)

**Step 2: Add a step that resolves which plugin (if any) to sync**

Above the existing "Detect and update drifted manifests" step, insert:

```yaml
      - name: Resolve plugin filter from event
        id: filter
        run: |
          set -euo pipefail
          plugin=""
          case "${{ github.event_name }}" in
            repository_dispatch)
              plugin='${{ github.event.client_payload.plugin }}'
              ;;
            workflow_dispatch)
              plugin='${{ github.event.inputs.plugin }}'
              ;;
          esac
          # Guard: empty plugin → fall through to all-plugin sync (cron behaviour).
          # Non-empty plugin → must match an existing directory; otherwise
          # log + exit clean (a dispatch for a not-yet-registered plugin
          # should not fail the workflow).
          if [[ -n "${plugin}" ]]; then
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

**Step 3: Smoke-validate YAML**

```bash
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/sync-registry-manifests.yml'))"
```

Expected: silent, exit 0.

**Step 4: Commit**

```bash
git add .github/workflows/sync-registry-manifests.yml
git commit -m "ci(sync-registry): add repository_dispatch trigger + plugin guard"
```

---

### Task 2: Branch the sync step on event type + add dispatch-specific PR title/branch

**Files:**
- Modify: `.github/workflows/sync-registry-manifests.yml`

**Step 1: Update the "Detect and update drifted manifests" step**

Replace the existing step body with a branching version that honors the filter:

```yaml
      - name: Detect and update drifted manifests
        if: steps.filter.outputs.skip != '1'
        id: sync
        run: |
          set -euo pipefail
          plugin='${{ steps.filter.outputs.plugin }}'
          if [[ -n "${plugin}" ]]; then
            echo "syncing single plugin: ${plugin}"
            scripts/sync-versions.sh --fix --plugin "${plugin}"
          else
            echo "syncing all plugins (cron / manual full run)"
            scripts/sync-versions.sh --fix
          fi
          if git diff --quiet -- plugins; then
            echo "changed=0" >> "$GITHUB_OUTPUT"
          else
            echo "changed=1" >> "$GITHUB_OUTPUT"
          fi
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

**Step 2: Update the "Open PR" step with dispatch-aware branch + title**

Replace the existing "Open PR if manifests changed" step:

```yaml
      - name: Open PR if manifests changed
        if: steps.sync.outputs.changed == '1'
        run: |
          set -euo pipefail
          plugin='${{ steps.filter.outputs.plugin }}'
          DATE=$(date +%Y-%m-%d)

          if [[ -n "${plugin}" ]]; then
            # Dispatch / single-plugin path. Use plugin name + manifest
            # version (post-fix) to avoid same-day branch collisions for
            # successive dispatches of the same plugin.
            version=$(jq -r '.version' "plugins/${plugin}/manifest.json")
            BRANCH="chore/sync-${plugin}-v${version}"
            TITLE="chore: sync ${plugin} to v${version}"
            BODY="Triggered by repository_dispatch (event_type=plugin-release) for plugin '${plugin}'. Updates \`plugins/${plugin}/manifest.json\` to match the latest GitHub release. Auto-generated by sync-registry-manifests workflow. Refs GoCodeAlone/workflow-registry#79."
          else
            # Cron / full-run path (existing behaviour).
            BRANCH="chore/sync-registry-manifests-${DATE}"
            TITLE="chore: sync registry manifests to latest plugin releases (${DATE})"
            BODY="Daily drift check detected version or download URL mismatches between plugin GitHub releases and registry manifests. Auto-generated by sync-registry-manifests workflow. Closes GoCodeAlone/workflow-registry#37."
          fi

          git config user.email "github-actions[bot]@users.noreply.github.com"
          git config user.name "github-actions[bot]"
          git checkout -b "$BRANCH"
          git add plugins/
          git commit -m "$TITLE"
          # If branch already exists upstream (same-tag duplicate dispatch),
          # push with --force-with-lease so the previous identical branch is
          # overwritten cleanly rather than failing the workflow run.
          git push origin "$BRANCH" --force-with-lease
          # Reuse an existing PR if one is already open for this branch.
          if existing=$(gh pr list --head "$BRANCH" --state open --json number --jq '.[0].number // empty'); then
            if [[ -n "${existing}" ]]; then
              echo "PR #${existing} already open for ${BRANCH}; pushed fresh commit."
              exit 0
            fi
          fi
          gh pr create --base main --head "$BRANCH" --title "$TITLE" --body "$BODY"
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

**Step 2.5: Step-level permission for PR write**

Confirm the job-level `permissions:` block at the top of the file already declares `pull-requests: write`. (It does — lines 6-7 in current file. No edit needed.)

**Step 3: Validate YAML**

```bash
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/sync-registry-manifests.yml'))"
```

Expected: silent, exit 0.

**Step 4: Commit**

```bash
git add .github/workflows/sync-registry-manifests.yml
git commit -m "ci(sync-registry): branch sync + PR shape on event type"
```

**Rollback:** revert the PR. No persistent state.

---

### Task 3: Push branch + open PR + add Copilot reviewer + manual workflow_dispatch validation

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
  --title "ci(sync-registry): react to plugin-release dispatch (G2 / #79 Piece 2)" \
  --body "$(cat <<'EOF'
## Summary

Adds `repository_dispatch: [plugin-release]` event handling to `sync-registry-manifests.yml` so a plugin repo can fire a dispatch on tag-publish and the registry syncs that one plugin immediately (vs waiting up to 24h for the daily cron).

## Mechanism

- New event listener: `repository_dispatch: types: [plugin-release]`.
- New `workflow_dispatch.inputs.plugin` for human-triggered single-plugin runs (mirrors the dispatch path).
- `Resolve plugin filter from event` step reads `client_payload.plugin` (or input), validates the directory exists, sets a step output.
- The existing sync step now passes `--plugin <name>` when filtered, falls back to scan-all on cron / blank input.
- The PR step uses a plugin-specific branch + title for dispatch runs, preserves the date-based branch for cron runs.

## Validation

- YAML parses (`python3 -c "yaml.safe_load(...)"`).
- Manual workflow_dispatch with `plugin=hover` will exercise the single-plugin path (no-op expected since hover is currently in sync at v0.2.0).

## Scope

This is **G2 / Piece 2** of #79. **G1 / Piece 1** (plugin repos firing the dispatch) is a separate workstream sweeping the notify step across plugin release.yml files.

## References

- Refs GoCodeAlone/workflow-registry#79
- Design: \`docs/plans/2026-05-21-dispatch-sync-design.md\`
EOF
)"
```

**Step 3: Add Copilot reviewer**

```bash
PR=$(gh pr view --json number --jq '.number')
gh pr edit "$PR" --add-reviewer @copilot
```

**Step 4: Trigger manual workflow_dispatch (no-op smoke)**

After the PR's CI passes — and BEFORE merge — manually fire the workflow against the PR branch with `plugin=hover` (currently in sync at v0.2.0). Confirm:

```bash
gh workflow run sync-registry-manifests.yml --ref feat/dispatch-sync -f plugin=hover
sleep 30
gh run list --workflow sync-registry-manifests.yml --branch feat/dispatch-sync --limit 1 --json status,conclusion
```

Expected: run completes with conclusion `success`, no new PR opens (hover already at v0.2.0).

**Step 5: Report back**

Print PR number + URL + the manual-dispatch run conclusion.

**Verification (CI workflow change):** The change runs on the PR via the actual GitHub Actions infrastructure; manual dispatch is the runtime-launch-validation step.

**Rollback:** revert the PR. No state.

---

## Verification summary

| Task | Change class | Verification |
|---|---|---|
| 1 | CI YAML edit | YAML parse + Task 3 dispatch |
| 2 | CI YAML edit | YAML parse + Task 3 dispatch |
| 3 | CI / PR | Manual workflow_dispatch (Step 4) returns success conclusion |

## Rollback (overall)

Single PR revert. The new triggers / branching are additive; reverting removes them. No persistent state.
