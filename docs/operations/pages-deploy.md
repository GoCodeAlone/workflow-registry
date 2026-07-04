# Registry Pages Deployment Notes

The `Build & Deploy Registry` workflow publishes the generated registry API to
GitHub Pages after every push to `main` and every plugin-release dispatch.

If manifest validation and artifact generation pass but the final
`actions/deploy-pages` step reports `Deployment failed, try again later`, first
rerun the failed workflow. If the same commit repeatedly fails while the
downloaded `github-pages` artifact is valid, merge a small follow-up commit and
let the normal `main` push workflow publish a fresh Pages build version.

Before treating a Pages deploy failure as a registry data failure, verify the
downloaded artifact contains the intended `v1/plugins/<name>/manifest.json` and
`latest.json` entries.
