# Dispatch-Triggered Single-Plugin Sync — G2

**Date:** 2026-05-21
**Tracking:** workflow-registry#79 (Piece 2)
**Scope:** Filter the EXISTING `repository_dispatch: [plugin-release]` listener in `sync-registry-manifests.yml` so it syncs only the named plugin (vs the current scan-all behaviour). The listener is already present; this PR adds the per-plugin branching, not the trigger itself.

## Goal

Today, plugin manifests in `plugins/<name>/manifest.json` only refresh on the daily 06:00 UTC cron run of `sync-registry-manifests.yml`. A plugin tagged at 06:01 UTC must wait ~24h before the registry surfaces the new version. Make the existing `repository_dispatch: [plugin-release]` listener actually filter to one plugin when fired, so a plugin repo can dispatch after its release and the registry syncs that one plugin immediately + opens a PR.

## Mechanism

The workflow already has `repository_dispatch: types: [plugin-release, workflow-release]` and the script `scripts/sync-versions.sh` already supports `--plugin <name>` (line 22-29) for single-plugin sync. What's missing is the filtering logic that reads `client_payload.plugin` and passes it to the script. The workflow gains:

1. A `Resolve plugin filter from event` step that reads `client_payload.plugin` (or `workflow_dispatch.inputs.plugin`) via `env:` — NOT inline-interpolated into bash, to avoid script injection — then regex-validates the value (`^[A-Za-z0-9._-]+$`) + verifies the `plugins/<name>/` directory exists.
2. The existing "Detect and update drifted manifests" step branches on the filter output:
   - filter set → `sync-versions.sh --fix --plugin "${PLUGIN}"` (single-plugin path; skips `sync-core-manifests.sh` because the `_workflow` checkout is conditional-skipped on dispatch).
   - filter empty → existing 3-script sweep (cron / full-run path), unchanged.
3. PR branch + title takes the plugin name + manifest-version on dispatch path (after the fix script writes the new version), so concurrent dispatches for different plugins don't collide. Branch name: `chore/sync-<plugin>-v<version>` (version stripped of any leading `v`). Title: `chore: sync <plugin> to v<version>`.

The cron path keeps its existing branch shape (`chore/sync-registry-manifests-<date>`).

A job-level `concurrency: group: sync-<plugin-or-all>` block serialises same-plugin dispatches at the Actions scheduler level. The bash step is the real injection-sanitisation boundary; Actions does not sanitise the concurrency-group key.

## Dispatch payload contract

```json
{
  "event_type": "plugin-release",
  "client_payload": {
    "plugin": "<directory-name-under-plugins/>",
    "tag": "v<semver>"
  }
}
```

`plugin` MUST match an existing `plugins/<name>/` directory. If missing or unknown, the step exits cleanly with a logged warning — does not fail the workflow run (a misfire from a not-yet-registered plugin should not break the registry).

`tag` is informational; the script reads the latest release from GitHub regardless. Included so log messages + PR title can reference the triggering tag without an extra GH API call.

## Validation

- Manual workflow_dispatch with `plugin=hover` + `tag=v0.2.0` (already-current — exercises the no-op path; should produce no PR).
- Test by re-tagging a plugin (or use a `gh api dispatches` curl) after this lands.

## Out of scope

- Modifying plugin repos to fire the dispatch (= G1, separate workstream).
- Changing `build-pages.yml` (it already accepts `repository_dispatch: [plugin-release]` and rebuilds the index — the missing piece was the manifest update, which `sync-registry-manifests.yml` owns).
- Multi-plugin batching (each dispatch handles one plugin).

## Assumptions

| # | Claim | Risk if false |
|---|---|---|
| A1 | `sync-versions.sh --plugin <name>` correctly handles a name that doesn't match any plugin directory. | If it errors, the workflow run fails noisy on unknown plugin names. Mitigation: wrap with a `[[ -d plugins/<name> ]]` guard in the workflow step. |
| A2 | Concurrent dispatches for different plugins won't collide (different branch names ensure no clash). | Same plugin getting two rapid dispatches in <1 min produces two PRs targeting the same branch name and one push fails. Mitigation: branch name uses dispatching tag, not date. |
| A3 | `secrets.GITHUB_TOKEN` has permission to receive `repository_dispatch` from external plugin repos. | External tokens have repo-scope; receiving needs no special perm, but sending FROM plugin repos requires `RELEASES_TOKEN` with `repo` scope. (= G1 scope.) |

## Rollback

Single revert PR. The new event listener is additive; reverting removes it. No state, no migration.
