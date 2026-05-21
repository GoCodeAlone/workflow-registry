# Dispatch-Triggered Single-Plugin Sync — G2

**Date:** 2026-05-21
**Tracking:** workflow-registry#79 (Piece 2)
**Scope:** Add `repository_dispatch: [plugin-release]` trigger to `sync-registry-manifests.yml`; sync only the named plugin when fired.

## Goal

Today, plugin manifests in `plugins/<name>/manifest.json` only refresh on the daily 06:00 UTC cron run of `sync-registry-manifests.yml`. A plugin tagged at 06:01 UTC must wait ~24h before the registry surfaces the new version. Add a real-time path: a plugin repo can fire `repository_dispatch event_type=plugin-release` after its release, and the registry syncs that one plugin immediately + opens a PR.

## Mechanism

`scripts/sync-versions.sh` already supports `--plugin <name>` (line 22-29) for single-plugin sync. The script change is zero. The workflow gains:

1. `repository_dispatch: [plugin-release]` event added to `on:` triggers.
2. New step that branches on `${{ github.event_name }}`:
   - `schedule` / `workflow_dispatch` → existing path (`sync-versions.sh --fix`, scan all).
   - `repository_dispatch` → `sync-versions.sh --fix --plugin "${{ github.event.client_payload.plugin }}"`.
3. PR branch + title incorporates the plugin name + tag on dispatch path, so concurrent dispatches don't collide:
   - Branch: `chore/sync-<plugin>-<tag>` (e.g. `chore/sync-hover-v0.2.1`).
   - Title: `chore: sync <plugin> to <tag>`.

The cron path keeps its existing branch shape (`chore/sync-registry-manifests-<date>`).

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
