# Plugin Ecosystem Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build end-to-end plugin lifecycle infrastructure — static registry with GitHub Pages, version tracking via repository_dispatch, wfctl enhancements (--url install, auto-fetch, cosign verification), plugin init scaffold with CI templates, and plugin authoring documentation.

**Architecture:** GitHub Pages serves static JSON (index.json, versions.json per plugin) built by GitHub Actions. Plugin repos dispatch release events to the registry. wfctl gains --url install, engine gains opt-in auto-fetch. Trust is tiered: checksum for community, cosign for official/verified.

**Tech Stack:** Go (wfctl/engine), GitHub Actions, GitHub Pages, GoReleaser, jq, gh CLI, cosign

---

### Task 1: Registry Build Script — Generate Static JSON Index

**Files:**
- Create: `scripts/build-index.sh` (in workflow-registry)
- Create: `scripts/build-versions.sh` (in workflow-registry)

**Context:** The registry currently stores only `plugins/<name>/manifest.json`. We need scripts that:
1. Generate `v1/index.json` — a catalog of all plugins with name, description, tier, version, type
2. Generate `v1/plugins/<name>/versions.json` — all known versions with download URLs and checksums per plugin
3. Generate `v1/plugins/<name>/latest.json` — latest version shortcut
4. Generate `v1/plugins/<name>/manifest.json` — copy of the source manifest

**Step 1: Create the build-index.sh script**

This script reads all `plugins/*/manifest.json` files and produces the static JSON output directory.

```bash
#!/usr/bin/env bash
# build-index.sh — generates the static registry site under v1/
# Requirements: jq
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGINS_DIR="$REPO_ROOT/plugins"
OUT_DIR="$REPO_ROOT/v1"

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR/plugins"

# Build index.json from all manifests
index_entries="[]"
for manifest in "$PLUGINS_DIR"/*/manifest.json; do
  plugin_name="$(basename "$(dirname "$manifest")")"
  mkdir -p "$OUT_DIR/plugins/$plugin_name"

  # Copy manifest to output
  cp "$manifest" "$OUT_DIR/plugins/$plugin_name/manifest.json"

  # Extract summary fields for index
  entry=$(jq -c '{
    name: .name,
    description: .description,
    version: .version,
    type: .type,
    tier: .tier,
    license: .license,
    author: .author,
    keywords: (.keywords // []),
    private: (.private // false),
    repository: (.repository // ""),
    minEngineVersion: (.minEngineVersion // ""),
    capabilities: {
      moduleTypes: (.capabilities.moduleTypes // []),
      stepTypes: (.capabilities.stepTypes // []),
      triggerTypes: (.capabilities.triggerTypes // [])
    }
  }' "$manifest")
  index_entries=$(echo "$index_entries" | jq --argjson e "$entry" '. + [$e]')
done

# Sort index by name
echo "$index_entries" | jq -S 'sort_by(.name)' > "$OUT_DIR/index.json"

echo "Built index with $(echo "$index_entries" | jq length) plugins in $OUT_DIR/"
```

**Step 2: Create the build-versions.sh script**

This script queries GitHub Releases API for each plugin with a repository field and generates `versions.json`.

```bash
#!/usr/bin/env bash
# build-versions.sh — queries GitHub Releases for each plugin and generates versions.json
# Requirements: gh (GitHub CLI), jq
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGINS_DIR="$REPO_ROOT/plugins"
OUT_DIR="$REPO_ROOT/v1"

for manifest in "$PLUGINS_DIR"/*/manifest.json; do
  plugin_name="$(basename "$(dirname "$manifest")")"
  out_plugin_dir="$OUT_DIR/plugins/$plugin_name"
  mkdir -p "$out_plugin_dir"

  repo_url="$(jq -r '.repository // empty' "$manifest")"
  if [[ -z "$repo_url" ]]; then
    # No repository — write empty versions
    jq -n --arg name "$plugin_name" '{name: $name, versions: []}' > "$out_plugin_dir/versions.json"
    continue
  fi

  gh_repo="$(echo "$repo_url" | sed -E 's|https://github.com/||')"
  min_engine="$(jq -r '.minEngineVersion // ""' "$manifest")"

  # Fetch all releases (up to 100)
  releases=$(gh release list --repo "$gh_repo" --limit 100 --json tagName,publishedAt,assets 2>/dev/null || echo "[]")
  if [[ "$releases" == "[]" ]]; then
    jq -n --arg name "$plugin_name" '{name: $name, versions: []}' > "$out_plugin_dir/versions.json"
    echo "  SKIP  $plugin_name — no releases"
    continue
  fi

  # Build versions array
  versions="[]"
  while IFS= read -r release; do
    tag=$(echo "$release" | jq -r '.tagName')
    published=$(echo "$release" | jq -r '.publishedAt')
    version="${tag#v}"

    # Build downloads array from release assets
    downloads="[]"
    while IFS= read -r asset; do
      asset_name=$(echo "$asset" | jq -r '.name')
      asset_url=$(echo "$asset" | jq -r '.url')

      # Match pattern: <name>-<os>-<arch>.tar.gz
      if [[ "$asset_name" =~ (linux|darwin|windows)-(amd64|arm64)\.tar\.gz$ ]]; then
        os_val="${BASH_REMATCH[1]}"
        arch_val="${BASH_REMATCH[2]}"

        # Try to find checksum from checksums.txt asset
        sha256=""
        checksums_url=$(echo "$release" | jq -r '.assets[] | select(.name == "checksums.txt") | .url // empty')
        if [[ -n "$checksums_url" ]]; then
          checksum_line=$(curl -sL "$checksums_url" | grep "$asset_name" || true)
          if [[ -n "$checksum_line" ]]; then
            sha256=$(echo "$checksum_line" | awk '{print $1}')
          fi
        fi

        dl=$(jq -n \
          --arg os "$os_val" \
          --arg arch "$arch_val" \
          --arg url "$asset_url" \
          --arg sha256 "$sha256" \
          '{os: $os, arch: $arch, url: $url, sha256: $sha256}')
        downloads=$(echo "$downloads" | jq --argjson d "$dl" '. + [$d]')
      fi
    done < <(echo "$release" | jq -c '.assets[]?' 2>/dev/null)

    ver_entry=$(jq -n \
      --arg version "$version" \
      --arg released "$published" \
      --arg minEngine "$min_engine" \
      --argjson downloads "$downloads" \
      '{version: $version, released: $released, minEngineVersion: $minEngine, downloads: $downloads}')
    versions=$(echo "$versions" | jq --argjson v "$ver_entry" '. + [$v]')
  done < <(echo "$releases" | jq -c '.[]')

  # Write versions.json
  jq -n --arg name "$plugin_name" --argjson versions "$versions" \
    '{name: $name, versions: ($versions | sort_by(.version) | reverse)}' \
    > "$out_plugin_dir/versions.json"

  # Write latest.json (first entry = latest)
  jq '.versions[0] // {}' "$out_plugin_dir/versions.json" > "$out_plugin_dir/latest.json"

  count=$(echo "$versions" | jq length)
  echo "    OK  $plugin_name — $count version(s)"
done

echo "Version data built in $OUT_DIR/"
```

**Step 3: Run scripts locally to verify**

```bash
cd /Users/jon/workspace/workflow-registry
chmod +x scripts/build-index.sh scripts/build-versions.sh
bash scripts/build-index.sh
# Expected: "Built index with 41 plugins in v1/"
```

**Step 4: Commit**

```bash
git add scripts/build-index.sh scripts/build-versions.sh
git commit -m "feat: add registry build scripts for static JSON index and versions"
```

---

### Task 2: GitHub Pages Deployment Action

**Files:**
- Create: `.github/workflows/build-pages.yml` (in workflow-registry)

**Context:** This Action runs build-index.sh + build-versions.sh and deploys the `v1/` directory to GitHub Pages.

**Step 1: Create the workflow file**

```yaml
name: Build & Deploy Registry

on:
  push:
    branches: [main]
  repository_dispatch:
    types: [plugin-release]
  schedule:
    # Daily fallback to catch missed dispatches
    - cron: '0 6 * * *'
  workflow_dispatch: {}

permissions:
  contents: read
  pages: write
  id-token: write

concurrency:
  group: pages
  cancel-in-progress: false

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Install dependencies
        run: sudo apt-get install -y jq

      - name: Setup GitHub CLI
        run: echo "${{ secrets.GITHUB_TOKEN }}" | gh auth login --with-token

      - name: Build static index
        run: bash scripts/build-index.sh

      - name: Build version data
        run: bash scripts/build-versions.sh
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}

      - name: Upload Pages artifact
        uses: actions/upload-pages-artifact@v3
        with:
          path: v1

  deploy:
    needs: build
    runs-on: ubuntu-latest
    environment:
      name: github-pages
      url: ${{ steps.deployment.outputs.page_url }}
    steps:
      - name: Deploy to GitHub Pages
        id: deployment
        uses: actions/deploy-pages@v4
```

**Step 2: Add v1/ to .gitignore**

The `v1/` directory is generated output. Add it to `.gitignore` so local runs don't pollute the repo.

Add to `.gitignore`:
```
v1/
```

**Step 3: Commit**

```bash
git add .github/workflows/build-pages.yml .gitignore
git commit -m "feat: add GitHub Pages deployment workflow for static registry"
```

---

### Task 3: Plugin Release Notification Action Template

**Files:**
- Create: `templates/notify-registry.yml` (in workflow-registry)

**Context:** Plugin repos need a reusable Action snippet to dispatch release events to the registry. This template goes into the registry repo for easy reference. Plugin authors copy it into their `.github/workflows/release.yml`.

**Step 1: Create the notification template**

```yaml
# templates/notify-registry.yml
#
# Add this job to your plugin's .github/workflows/release.yml
# to automatically notify the workflow-registry when you publish a release.
#
# Prerequisites:
#   - Create a GitHub PAT with `repo` scope for GoCodeAlone/workflow-registry
#   - Add it as a secret named REGISTRY_PAT in your plugin repo
#
# Usage: Copy the job below into your release workflow, after the GoReleaser job.

# notify-registry:
#   if: startsWith(github.ref, 'refs/tags/v')
#   needs: [release]  # adjust to match your release job name
#   runs-on: ubuntu-latest
#   steps:
#     - name: Notify workflow-registry of new release
#       uses: peter-evans/repository-dispatch@v3
#       with:
#         token: ${{ secrets.REGISTRY_PAT }}
#         repository: GoCodeAlone/workflow-registry
#         event-type: plugin-release
#         client-payload: >-
#           {"plugin": "${{ github.repository }}", "tag": "${{ github.ref_name }}"}
```

**Step 2: Commit**

```bash
git add templates/notify-registry.yml
git commit -m "docs: add notify-registry Action template for plugin authors"
```

---

### Task 4: wfctl plugin install --url Support

**Files:**
- Modify: `cmd/wfctl/plugin_install.go` (in workflow repo)

**Context:** Users with private plugins need to install directly from a URL without configuring a registry. Currently `wfctl plugin install` only supports registry lookups or `owner/repo` GitHub refs. We add `--url` flag to download and install from any tar.gz URL.

**Step 1: Add the --url flag to runPluginInstall**

In `cmd/wfctl/plugin_install.go`, add the `--url` flag to the FlagSet and handle it before registry lookup.

After line 73 (where `registryName` is defined), add:
```go
directURL := fs.String("url", "", "Install from a direct download URL (tar.gz archive)")
```

After `fs.Parse(args)`, before the `fs.NArg() < 1` check, add the URL install path:

```go
if *directURL != "" {
    return installFromURL(*directURL, pluginDirVal)
}
```

**Step 2: Implement installFromURL**

Add this function to `cmd/wfctl/plugin_install.go`:

```go
// installFromURL downloads a plugin tarball from a direct URL and installs it.
// The plugin name is inferred from the archive contents (plugin.json name field).
func installFromURL(url, pluginDir string) error {
    fmt.Fprintf(os.Stderr, "Downloading %s...\n", url)
    data, err := downloadURL(url)
    if err != nil {
        return fmt.Errorf("download: %w", err)
    }

    // Extract to a temp dir first to read plugin.json and determine the name.
    tmpDir, err := os.MkdirTemp("", "wfctl-plugin-*")
    if err != nil {
        return fmt.Errorf("create temp dir: %w", err)
    }
    defer os.RemoveAll(tmpDir)

    if err := extractTarGz(data, tmpDir); err != nil {
        return fmt.Errorf("extract: %w", err)
    }

    // Read plugin.json to get the plugin name.
    pjData, err := os.ReadFile(filepath.Join(tmpDir, "plugin.json"))
    if err != nil {
        return fmt.Errorf("no plugin.json found in archive: %w", err)
    }
    var pj installedPluginJSON
    if err := json.Unmarshal(pjData, &pj); err != nil {
        return fmt.Errorf("parse plugin.json: %w", err)
    }
    if pj.Name == "" {
        return fmt.Errorf("plugin.json missing name field")
    }

    pluginName := normalizePluginName(pj.Name)
    destDir := filepath.Join(pluginDir, pluginName)
    if err := os.MkdirAll(destDir, 0750); err != nil {
        return fmt.Errorf("create plugin dir: %w", err)
    }

    // Re-extract to the final destination (clean extraction).
    if err := extractTarGz(data, destDir); err != nil {
        return fmt.Errorf("extract to dest: %w", err)
    }

    if err := ensurePluginBinary(destDir, pluginName); err != nil {
        fmt.Fprintf(os.Stderr, "warning: could not normalize binary name: %v\n", err)
    }

    // Compute checksum and update lockfile.
    h := sha256.Sum256(data)
    checksum := hex.EncodeToString(h[:])
    updateLockfileWithChecksum(pluginName, pj.Version, pj.Repository, checksum)

    fmt.Printf("Installed %s v%s to %s\n", pluginName, pj.Version, destDir)
    return nil
}
```

**Step 3: Add updateLockfileWithChecksum helper**

In `cmd/wfctl/plugin_lockfile.go`, add:

```go
// updateLockfileWithChecksum adds or updates a plugin entry with checksum in .wfctl.yaml.
func updateLockfileWithChecksum(pluginName, version, repository, sha256 string) {
    lf, err := loadPluginLockfile(wfctlYAMLPath)
    if err != nil {
        return
    }
    if lf.Plugins == nil {
        lf.Plugins = make(map[string]PluginLockEntry)
    }
    lf.Plugins[pluginName] = PluginLockEntry{
        Version:    version,
        Repository: repository,
        SHA256:     sha256,
    }
    _ = lf.Save(wfctlYAMLPath)
}
```

**Step 4: Update updateLockfile to also compute SHA256 when available**

Modify the existing `updateLockfile` function to also store the registry field. In `plugin_lockfile.go`, add a `Registry` field to `PluginLockEntry`:

```go
type PluginLockEntry struct {
    Version    string `yaml:"version"`
    Repository string `yaml:"repository,omitempty"`
    SHA256     string `yaml:"sha256,omitempty"`
    Registry   string `yaml:"registry,omitempty"`
}
```

**Step 5: Run tests**

```bash
cd /Users/jon/workspace/workflow
go build ./cmd/wfctl/...
go test ./cmd/wfctl/... -count=1
```

**Step 6: Commit**

```bash
cd /Users/jon/workspace/workflow
git add cmd/wfctl/plugin_install.go cmd/wfctl/plugin_lockfile.go
git commit -m "feat(wfctl): add plugin install --url for direct URL installs"
```

---

### Task 5: Lockfile Checksum Verification on Install

**Files:**
- Modify: `cmd/wfctl/plugin_install.go` (in workflow repo)

**Context:** Currently `installPluginFromManifest` verifies checksums from the manifest's `SHA256` field, but `installFromLockfile` doesn't verify the installed binary matches the lockfile's pinned checksum. We need verification on lockfile-based installs.

**Step 1: Update installFromLockfile to verify checksums**

In `cmd/wfctl/plugin_lockfile.go`, modify `installFromLockfile` to verify SHA256 after each install:

After `runPluginInstall(installArgs)` succeeds, add:
```go
// Verify checksum if lockfile has one pinned.
if entry.SHA256 != "" {
    pluginDir := filepath.Join(pluginDirVal, name)
    if verifyErr := verifyInstalledChecksum(pluginDir, name, entry.SHA256); verifyErr != nil {
        fmt.Fprintf(os.Stderr, "CHECKSUM MISMATCH for %s: %v\n", name, verifyErr)
        failed = append(failed, name)
        continue
    }
}
```

**Step 2: Add verifyInstalledChecksum function**

In `cmd/wfctl/plugin_install.go`, add:

```go
// verifyInstalledChecksum hashes the installed plugin binary and compares
// against an expected SHA256 hex string from the lockfile.
func verifyInstalledChecksum(pluginDir, pluginName, expectedSHA256 string) error {
    binaryPath := filepath.Join(pluginDir, pluginName)
    data, err := os.ReadFile(binaryPath)
    if err != nil {
        return fmt.Errorf("read binary %s: %w", binaryPath, err)
    }
    h := sha256.Sum256(data)
    got := hex.EncodeToString(h[:])
    if !strings.EqualFold(got, expectedSHA256) {
        return fmt.Errorf("binary checksum mismatch: got %s, want %s", got, expectedSHA256)
    }
    return nil
}
```

**Step 3: Store SHA256 in lockfile during registry install**

In `cmd/wfctl/plugin_install.go`, update `runPluginInstall` to pass the download checksum to `updateLockfile`. After `installPluginFromManifest` succeeds and before `updateLockfile` is called, capture the checksum:

Replace the existing `updateLockfile(manifest.Name, manifest.Version, manifest.Repository)` call with:
```go
sha := ""
if dl, dlErr := manifest.FindDownload(runtime.GOOS, runtime.GOARCH); dlErr == nil {
    sha = dl.SHA256
}
updateLockfileWithChecksum(manifest.Name, manifest.Version, manifest.Repository, sha)
```

**Step 4: Run tests**

```bash
cd /Users/jon/workspace/workflow
go build ./cmd/wfctl/...
go test ./cmd/wfctl/... -count=1
```

**Step 5: Commit**

```bash
cd /Users/jon/workspace/workflow
git add cmd/wfctl/plugin_install.go cmd/wfctl/plugin_lockfile.go
git commit -m "feat(wfctl): verify SHA-256 checksums from lockfile on install"
```

---

### Task 6: Enhanced Plugin Init Scaffold

**Files:**
- Modify: `plugin/sdk/generator.go` (in workflow repo)

**Context:** The current `wfctl plugin init` scaffold only generates `plugin.json` and a basic `.go` file. We need to generate a full project structure with `cmd/` entrypoint, `internal/` package, `go.mod`, `.goreleaser.yml`, `.github/workflows/`, and `Makefile`.

**Step 1: Update GenerateOptions with new fields**

In `plugin/sdk/generator.go`, add fields:
```go
type GenerateOptions struct {
    Name         string
    Version      string
    Author       string
    Description  string
    License      string
    OutputDir    string
    WithContract bool
    GoModule     string // e.g. "github.com/MyOrg/workflow-plugin-foo"
}
```

**Step 2: Update Generate() to create full project structure**

Replace the body of `Generate()` to create the full directory tree:

```go
func (g *TemplateGenerator) Generate(opts GenerateOptions) error {
    if opts.Name == "" {
        return fmt.Errorf("plugin name is required")
    }
    if opts.Version == "" {
        opts.Version = "0.1.0"
    }
    if opts.Author == "" {
        return fmt.Errorf("author is required")
    }
    if opts.Description == "" {
        opts.Description = "A workflow plugin"
    }
    if opts.OutputDir == "" {
        opts.OutputDir = opts.Name
    }
    if opts.GoModule == "" {
        opts.GoModule = fmt.Sprintf("github.com/%s/workflow-plugin-%s", opts.Author, opts.Name)
    }

    fullName := "workflow-plugin-" + opts.Name

    // Validate the name
    manifest := &plugin.PluginManifest{
        Name:        opts.Name,
        Version:     opts.Version,
        Author:      opts.Author,
        Description: opts.Description,
        License:     opts.License,
    }
    if err := manifest.Validate(); err != nil {
        return fmt.Errorf("generated manifest is invalid: %w", err)
    }

    // Create directory structure
    dirs := []string{
        opts.OutputDir,
        filepath.Join(opts.OutputDir, "cmd", fullName),
        filepath.Join(opts.OutputDir, "internal"),
        filepath.Join(opts.OutputDir, ".github", "workflows"),
    }
    for _, d := range dirs {
        if err := os.MkdirAll(d, 0750); err != nil {
            return fmt.Errorf("create directory %s: %w", d, err)
        }
    }

    // Write files
    files := map[string]string{
        "plugin.json":                         generatePluginJSON(opts, fullName),
        "cmd/" + fullName + "/main.go":        generateMainGo(opts),
        "internal/provider.go":                generateProviderGo(opts),
        "internal/steps.go":                   generateStepsGo(opts),
        "go.mod":                              generateGoMod(opts),
        ".goreleaser.yml":                     generateGoReleaser(fullName),
        ".github/workflows/ci.yml":            generateCIWorkflow(),
        ".github/workflows/release.yml":       generateReleaseWorkflow(fullName),
        "Makefile":                            generateMakefile(opts, fullName),
        "README.md":                           generateReadme(opts, fullName),
    }

    for relPath, content := range files {
        absPath := filepath.Join(opts.OutputDir, relPath)
        if err := os.WriteFile(absPath, []byte(content), 0600); err != nil {
            return fmt.Errorf("write %s: %w", relPath, err)
        }
    }

    return nil
}
```

**Step 3: Add template generation functions**

Add these functions to `plugin/sdk/generator.go`:

```go
func generatePluginJSON(opts GenerateOptions, fullName string) string {
    // Build a proper JSON manifest
    m := map[string]any{
        "name":        fullName,
        "version":     opts.Version,
        "description": opts.Description,
        "author":      opts.Author,
        "license":     opts.License,
        "type":        "external",
        "tier":        "community",
        "private":     false,
        "minEngineVersion": "0.3.30",
        "keywords":    []string{},
        "repository":  opts.GoModule,
        "capabilities": map[string]any{
            "moduleTypes": []string{},
            "stepTypes":   []string{"step." + strings.ReplaceAll(opts.Name, "-", "_") + "_example"},
            "triggerTypes": []string{},
        },
    }
    data, _ := json.MarshalIndent(m, "", "    ")
    return string(data) + "\n"
}

func generateMainGo(opts GenerateOptions) string {
    return fmt.Sprintf(`package main

import (
	"fmt"
	"os"

	"github.com/GoCodeAlone/workflow/plugin/external/sdk"
	"%s/internal"
)

func main() {
	provider := internal.NewProvider()
	if err := sdk.Serve(provider); err != nil {
		fmt.Fprintf(os.Stderr, "plugin error: %%v\n", err)
		os.Exit(1)
	}
}
`, opts.GoModule)
}

func generateProviderGo(opts GenerateOptions) string {
    funcName := toCamelCase(opts.Name)
    return fmt.Sprintf(`package internal

import (
	"github.com/GoCodeAlone/workflow/plugin/external/sdk"
)

// Provider implements the workflow plugin SDK interfaces.
type Provider struct{}

// NewProvider creates a new %s plugin provider.
func NewProvider() *Provider {
	return &Provider{}
}

// PluginInfo returns metadata about this plugin.
func (p *Provider) PluginInfo() sdk.PluginInfo {
	return sdk.PluginInfo{
		Name:        %q,
		Version:     %q,
		Description: %q,
	}
}

// StepFactories returns the step types this plugin provides.
func (p *Provider) StepFactories() map[string]sdk.StepFactory {
	return map[string]sdk.StepFactory{
		"step.%s_example": NewExampleStepFactory(),
	}
}
`, funcName, opts.Name, opts.Version, opts.Description, strings.ReplaceAll(opts.Name, "-", "_"))
}

func generateStepsGo(opts GenerateOptions) string {
    stepName := strings.ReplaceAll(opts.Name, "-", "_")
    return fmt.Sprintf(`package internal

import (
	"context"

	"github.com/GoCodeAlone/workflow/plugin/external/sdk"
)

// ExampleStep demonstrates a basic pipeline step implementation.
type ExampleStep struct {
	config map[string]any
}

// ExampleStepFactory creates ExampleStep instances.
type ExampleStepFactory struct{}

// NewExampleStepFactory creates a new factory for step.%s_example.
func NewExampleStepFactory() *ExampleStepFactory {
	return &ExampleStepFactory{}
}

func (f *ExampleStepFactory) Create(config map[string]any) (sdk.Step, error) {
	return &ExampleStep{config: config}, nil
}

func (s *ExampleStep) Execute(ctx context.Context, params sdk.StepParams) (map[string]any, error) {
	return map[string]any{
		"status":  "ok",
		"message": "step.%s_example executed successfully",
	}, nil
}
`, stepName, stepName)
}

func generateGoMod(opts GenerateOptions) string {
    return fmt.Sprintf(`module %s

go 1.24

require (
	github.com/GoCodeAlone/workflow v0.3.30
)
`, opts.GoModule)
}

func generateGoReleaser(fullName string) string {
    return fmt.Sprintf(`version: 2

builds:
  - main: "./cmd/%s"
    binary: "%s"
    env:
      - CGO_ENABLED=0
    goos:
      - linux
      - darwin
    goarch:
      - amd64
      - arm64
    ldflags:
      - "-s -w"

archives:
  - formats: [tar.gz]
    name_template: "%s-{{ .Os }}-{{ .Arch }}"
    files:
      - plugin.json
      - LICENSE

checksum:
  name_template: checksums.txt

changelog:
  sort: asc
`, fullName, fullName, fullName)
}

func generateCIWorkflow() string {
    return `name: CI

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-go@v5
        with:
          go-version: '1.24'
      - run: go test ./... -count=1 -race
      - run: go vet ./...
`
}

func generateReleaseWorkflow(fullName string) string {
    return fmt.Sprintf(`name: Release

on:
  push:
    tags: ['v*']

permissions:
  contents: write

jobs:
  release:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
      - uses: actions/setup-go@v5
        with:
          go-version: '1.24'
      - uses: goreleaser/goreleaser-action@v6
        with:
          version: '~> v2'
          args: release --clean
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}

  notify-registry:
    if: startsWith(github.ref, 'refs/tags/v')
    needs: [release]
    runs-on: ubuntu-latest
    steps:
      - name: Notify workflow-registry
        if: env.GH_TOKEN != ''
        uses: peter-evans/repository-dispatch@v3
        with:
          token: ${{ secrets.REGISTRY_PAT }}
          repository: GoCodeAlone/workflow-registry
          event-type: plugin-release
          client-payload: >-
            {"plugin": "${{ github.repository }}", "tag": "${{ github.ref_name }}"}
        env:
          GH_TOKEN: ${{ secrets.REGISTRY_PAT }}
        continue-on-error: true
`)
}

func generateMakefile(opts GenerateOptions, fullName string) string {
    return fmt.Sprintf(`.PHONY: build test install-local clean

build:
	go build -o %s ./cmd/%s

test:
	go test ./... -count=1 -race

install-local: build
	mkdir -p data/plugins/%s
	cp %s data/plugins/%s/%s
	cp plugin.json data/plugins/%s/

clean:
	rm -f %s
`, fullName, fullName, opts.Name, fullName, opts.Name, opts.Name, opts.Name, fullName)
}

func generateReadme(opts GenerateOptions, fullName string) string {
    return fmt.Sprintf(`# %s

%s

## Installation

`+"```bash\nwfctl plugin install %s\n```"+`

## Development

`+"```bash\nmake build    # Build the plugin binary\nmake test     # Run tests\nmake install-local  # Install to local data/plugins/\n```"+`

## Release

Tag a version to trigger GoReleaser:

`+"```bash\ngit tag v0.1.0\ngit push origin v0.1.0\n```"+`
`, fullName, opts.Description, opts.Name)
}
```

**Step 4: Update runPluginInit to pass GoModule**

In `cmd/wfctl/plugin.go`, add the `--module` flag:

```go
module := fs.String("module", "", "Go module path (default: github.com/<author>/workflow-plugin-<name>)")
```

And pass it to GenerateOptions:
```go
opts := sdk.GenerateOptions{
    Name:         name,
    Version:      *ver,
    Author:       *author,
    Description:  *desc,
    License:      *license,
    OutputDir:    *output,
    WithContract: *withContract,
    GoModule:     *module,
}
```

**Step 5: Run tests**

```bash
cd /Users/jon/workspace/workflow
go build ./cmd/wfctl/...
go test ./plugin/sdk/... -count=1
```

**Step 6: Commit**

```bash
cd /Users/jon/workspace/workflow
git add plugin/sdk/generator.go cmd/wfctl/plugin.go
git commit -m "feat(wfctl): enhanced plugin init scaffold with full project structure"
```

---

### Task 7: Engine Auto-Fetch Support

**Files:**
- Modify: `plugin/loader.go` (in workflow repo)
- Modify: `config/config.go` (in workflow repo) — if external plugin config exists

**Context:** The engine should optionally auto-fetch missing plugins on startup. This is configured per-plugin in the workflow YAML config with `autoFetch: true` and an optional `version` constraint.

**Step 1: Explore current external plugin config**

Read `config/config.go` to understand how external plugins are currently declared, and `engine.go` to see how they're loaded on startup.

```bash
cd /Users/jon/workspace/workflow
grep -rn "external" config/config.go | head -20
grep -rn "ExternalPlugin\|PluginDir\|plugin.*dir" engine.go | head -20
```

**Step 2: Add ExternalPluginConfig type**

In `config/config.go` (or a new `config/plugins.go` if config.go is too large), add:

```go
// ExternalPluginConfig declares an external plugin with optional auto-fetch.
type ExternalPluginConfig struct {
    Name      string `yaml:"name" json:"name"`
    AutoFetch bool   `yaml:"autoFetch,omitempty" json:"autoFetch,omitempty"`
    Version   string `yaml:"version,omitempty" json:"version,omitempty"` // semver constraint
    Registry  string `yaml:"registry,omitempty" json:"registry,omitempty"` // registry name
}
```

**Step 3: Add auto-fetch function to plugin loader**

In `plugin/loader.go` or a new `plugin/autofetch.go`, add:

```go
// AutoFetchPlugin downloads a plugin from the registry if it's not already installed.
// This is called by the engine on startup when autoFetch is true for a plugin.
func AutoFetchPlugin(pluginName, pluginDir, registryConfigPath string) error {
    destDir := filepath.Join(pluginDir, pluginName)
    if _, err := os.Stat(filepath.Join(destDir, "plugin.json")); err == nil {
        return nil // already installed
    }

    // Use wfctl install logic (imported or duplicated as a shared package)
    // For now, shell out to wfctl as the simplest integration:
    fmt.Fprintf(os.Stderr, "[auto-fetch] Plugin %q not found locally, fetching from registry...\n", pluginName)

    // Construct wfctl command
    args := []string{"plugin", "install", "--plugin-dir", pluginDir, pluginName}
    cmd := exec.Command("wfctl", args...)
    cmd.Stdout = os.Stderr
    cmd.Stderr = os.Stderr
    if err := cmd.Run(); err != nil {
        return fmt.Errorf("auto-fetch plugin %q: %w", pluginName, err)
    }
    return nil
}
```

**Note:** The actual implementation depends on whether we want the engine to import wfctl's install logic directly or shell out. Shelling out to `wfctl` is simpler and keeps the engine binary lean. The engine just needs `wfctl` on PATH.

**Step 4: Wire auto-fetch into engine startup**

In `engine.go`, in the `BuildFromConfig` or plugin loading section, add:

```go
// Auto-fetch declared external plugins before loading.
if cfg.Plugins != nil {
    for _, ep := range cfg.Plugins.External {
        if ep.AutoFetch {
            if err := plugin.AutoFetchPlugin(ep.Name, e.pluginDir, ""); err != nil {
                e.logger.Warn("auto-fetch failed", "plugin", ep.Name, "error", err)
                // Non-fatal: continue loading what's available
            }
        }
    }
}
```

**Step 5: Run tests**

```bash
cd /Users/jon/workspace/workflow
go build ./...
go test ./plugin/... -count=1
```

**Step 6: Commit**

```bash
cd /Users/jon/workspace/workflow
git add plugin/autofetch.go config/ engine.go
git commit -m "feat: engine auto-fetch for declared external plugins on startup"
```

---

### Task 8: Plugin Authoring Documentation

**Files:**
- Create: `docs/PLUGIN_AUTHORING.md` (in workflow repo)

**Context:** A comprehensive guide for plugin authors covering the full lifecycle: init, develop, test, publish, register.

**Step 1: Write the documentation**

```markdown
# Plugin Authoring Guide

This guide walks you through creating, testing, publishing, and registering a workflow plugin.

## Quick Start

```bash
# Scaffold a new plugin
wfctl plugin init my-plugin -author MyOrg -description "My custom plugin"

# Build and test
cd workflow-plugin-my-plugin
go mod tidy
make build
make test

# Install locally for development
make install-local
```

## Project Structure

`wfctl plugin init` generates:

```
workflow-plugin-my-plugin/
├── cmd/workflow-plugin-my-plugin/main.go   # gRPC entrypoint
├── internal/
│   ├── provider.go                         # Plugin provider (registers steps/modules)
│   └── steps.go                            # Step implementations
├── plugin.json                             # Plugin manifest
├── go.mod
├── .goreleaser.yml                         # Cross-platform release builds
├── .github/workflows/
│   ├── ci.yml                              # Test + lint on PR
│   └── release.yml                         # GoReleaser + registry notification
├── Makefile
└── README.md
```

## Implementing Steps

Add step types in `internal/steps.go`:

```go
type MyStep struct{ config map[string]any }
type MyStepFactory struct{}

func NewMyStepFactory() *MyStepFactory { return &MyStepFactory{} }

func (f *MyStepFactory) Create(config map[string]any) (sdk.Step, error) {
    return &MyStep{config: config}, nil
}

func (s *MyStep) Execute(ctx context.Context, params sdk.StepParams) (map[string]any, error) {
    // Access step config: s.config["key"]
    // Access pipeline context: params.Current["key"]
    // Access previous step output: params.Steps["step-name"]["key"]
    return map[string]any{"result": "value"}, nil
}
```

Register in `internal/provider.go`:
```go
func (p *Provider) StepFactories() map[string]sdk.StepFactory {
    return map[string]sdk.StepFactory{
        "step.my_action": NewMyStepFactory(),
    }
}
```

## Testing Locally

```bash
# Unit tests
make test

# Install to local engine
make install-local

# Validate manifest
wfctl plugin validate -plugin-dir data/plugins my-plugin

# Full lifecycle test
wfctl plugin test .
```

## Publishing a Release

1. Tag your version:
   ```bash
   git tag v0.1.0
   git push origin v0.1.0
   ```

2. GoReleaser builds cross-platform binaries and creates a GitHub Release.

3. If `REGISTRY_PAT` is configured, the registry is automatically notified.

## Registering in the Public Registry

1. Fork [GoCodeAlone/workflow-registry](https://github.com/GoCodeAlone/workflow-registry)
2. Add `plugins/<your-plugin>/manifest.json`:
   ```json
   {
     "name": "workflow-plugin-my-plugin",
     "version": "0.1.0",
     "description": "My custom plugin",
     "author": "MyOrg",
     "type": "external",
     "tier": "community",
     "license": "MIT",
     "repository": "https://github.com/MyOrg/workflow-plugin-my-plugin",
     "capabilities": {
       "moduleTypes": [],
       "stepTypes": ["step.my_action"],
       "triggerTypes": []
     },
     "downloads": [
       {"os": "linux", "arch": "amd64", "url": "https://github.com/MyOrg/workflow-plugin-my-plugin/releases/download/v0.1.0/workflow-plugin-my-plugin-linux-amd64.tar.gz"},
       {"os": "linux", "arch": "arm64", "url": "https://github.com/MyOrg/workflow-plugin-my-plugin/releases/download/v0.1.0/workflow-plugin-my-plugin-linux-arm64.tar.gz"},
       {"os": "darwin", "arch": "amd64", "url": "https://github.com/MyOrg/workflow-plugin-my-plugin/releases/download/v0.1.0/workflow-plugin-my-plugin-darwin-amd64.tar.gz"},
       {"os": "darwin", "arch": "arm64", "url": "https://github.com/MyOrg/workflow-plugin-my-plugin/releases/download/v0.1.0/workflow-plugin-my-plugin-darwin-arm64.tar.gz"}
     ]
   }
   ```
3. Open a PR — CI validates the manifest against the registry schema.
4. After merge, your plugin appears in `wfctl plugin search`.

## Private Plugins

No registry needed for private plugins:

```bash
# Install from a GitHub Release URL
wfctl plugin install --url https://github.com/MyOrg/my-plugin/releases/download/v0.1.0/my-plugin-darwin-arm64.tar.gz

# Install from a local build
wfctl plugin install --local ./my-plugin

# Pin in lockfile for reproducible installs
# .wfctl.yaml is updated automatically
```

## Auto-Fetch by Engine

Declare plugins in your workflow config for automatic download on startup:

```yaml
plugins:
  external:
    - name: my-plugin
      autoFetch: true
      version: ">=0.1.0"
```

The engine calls `wfctl plugin install` automatically if the plugin binary isn't found locally.

## Trust Tiers

| Tier | Requirements |
|------|-------------|
| **community** | Valid manifest, PR reviewed, SHA-256 checksums via GoReleaser |
| **verified** | + cosign-signed releases, public key in manifest |
| **official** | GoCodeAlone-maintained, signed with org key |

## Registry Notification

To get automatic version updates in the registry, add the `REGISTRY_PAT` secret to your repo and include the notification job in your release workflow. See [templates/notify-registry.yml](https://github.com/GoCodeAlone/workflow-registry/blob/main/templates/notify-registry.yml).
```

**Step 2: Commit**

```bash
cd /Users/jon/workspace/workflow
git add docs/PLUGIN_AUTHORING.md
git commit -m "docs: add comprehensive plugin authoring guide"
```

---

### Task 9: Registry README and Contribution Guide

**Files:**
- Modify: `README.md` (in workflow-registry)

**Context:** Update the registry README with contribution guidelines, static site URL, and PR process for third-party plugin authors.

**Step 1: Rewrite README.md**

```markdown
# workflow-registry

[![Validate Registry](https://github.com/GoCodeAlone/workflow-registry/actions/workflows/validate.yml/badge.svg)](https://github.com/GoCodeAlone/workflow-registry/actions/workflows/validate.yml)
[![Build & Deploy](https://github.com/GoCodeAlone/workflow-registry/actions/workflows/build-pages.yml/badge.svg)](https://github.com/GoCodeAlone/workflow-registry/actions/workflows/build-pages.yml)

Official plugin registry for the [Workflow](https://github.com/GoCodeAlone/workflow) engine. Browse, search, and install plugins via `wfctl`.

**Registry URL:** `https://gocodealone.github.io/workflow-registry/v1/`

## Using Plugins

```bash
# Search for plugins
wfctl plugin search monitoring

# Install a plugin
wfctl plugin install datadog

# List installed plugins
wfctl plugin list

# Update a plugin
wfctl plugin update datadog
```

See the [Plugin Authoring Guide](https://github.com/GoCodeAlone/workflow/blob/main/docs/PLUGIN_AUTHORING.md) for creating your own plugins.

## Submitting a Plugin

1. Fork this repository
2. Create `plugins/<your-plugin>/manifest.json` following the [schema](schema/registry-schema.json)
3. Open a PR — CI validates your manifest automatically
4. After review and merge, your plugin appears in `wfctl plugin search`

### Manifest Requirements

- `name`: Your plugin name (e.g., `workflow-plugin-my-tool`)
- `version`: Current semver version
- `author`: Your name or organization
- `description`: Short description
- `type`: `external` for gRPC plugins, `builtin` for engine-compiled plugins
- `tier`: `community` for third-party plugins
- `license`: SPDX identifier (e.g., `MIT`, `Apache-2.0`)
- `repository`: GitHub repository URL
- `capabilities`: Step types, module types, and trigger types your plugin provides
- `downloads`: Platform-specific binary download URLs from your GitHub Releases

### Automatic Version Tracking

After your plugin is registered, add the [registry notification Action](templates/notify-registry.yml) to your release workflow. This dispatches a `plugin-release` event to this repo, triggering an automatic rebuild of the version index.

## Structure

```
plugins/<name>/manifest.json    # Plugin manifest (source of truth)
schema/registry-schema.json     # JSON Schema for validation
templates/                      # Starter configs and CI templates
scripts/                        # Build and validation scripts
v1/                             # Generated static site (GitHub Pages)
```

## Plugin Tiers

| Tier | Badge | Description |
|------|-------|-------------|
| **core** | Official | Maintained by GoCodeAlone |
| **community** | Community | Third-party, PR-reviewed |
| **premium** | Premium | Commercial/private plugins |
```

**Step 2: Commit**

```bash
cd /Users/jon/workspace/workflow-registry
git add README.md
git commit -m "docs: update README with contribution guide and registry URL"
```

---

### Task 10: Add Existing Plugin Repos Notification Workflows

**Files:**
- Modify: `.github/workflows/release.yml` in each existing external plugin repo

**Context:** Existing GoCodeAlone plugin repos need the `notify-registry` job added to their release workflows so the registry auto-updates on new releases. Repos: workflow-plugin-datadog, workflow-plugin-okta, workflow-plugin-launchdarkly, workflow-plugin-salesforce, workflow-plugin-openlms, workflow-plugin-payments, workflow-plugin-agent, workflow-plugin-authz, workflow-plugin-admin, workflow-plugin-bento, workflow-plugin-github.

**Step 1: For each plugin repo, add the notify-registry job**

Add this job to each repo's `.github/workflows/release.yml`:

```yaml
  notify-registry:
    if: startsWith(github.ref, 'refs/tags/v')
    needs: [release]
    runs-on: ubuntu-latest
    steps:
      - name: Notify workflow-registry
        if: env.GH_TOKEN != ''
        uses: peter-evans/repository-dispatch@v3
        with:
          token: ${{ secrets.REGISTRY_PAT }}
          repository: GoCodeAlone/workflow-registry
          event-type: plugin-release
          client-payload: >-
            {"plugin": "${{ github.repository }}", "tag": "${{ github.ref_name }}"}
        env:
          GH_TOKEN: ${{ secrets.REGISTRY_PAT }}
        continue-on-error: true
```

**Step 2: Use a parallel agent approach**

Since these are independent repos, dispatch agents in parallel to add the job to each release workflow. Each agent should:
1. Read the existing `release.yml`
2. Add the `notify-registry` job if not already present
3. Commit and push

**Step 3: Commit each repo**

```bash
git add .github/workflows/release.yml
git commit -m "ci: add registry notification on release"
git push
```

---

### Task 11: VS Code Marketplace Panel

**Files:**
- Create: `src/marketplace/MarketplaceProvider.ts` (in workflow-vscode)
- Create: `src/marketplace/MarketplaceItem.ts` (in workflow-vscode)
- Modify: `src/extension.ts` (in workflow-vscode)
- Modify: `package.json` (in workflow-vscode) — add view contribution

**Context:** Add a tree view panel to VS Code that shows available plugins from the registry, their install status, and provides install/update buttons.

**Step 1: Add view contribution to package.json**

In `package.json`, add to `contributes.views`:

```json
"workflow-explorer": [
  {
    "id": "workflowPluginMarketplace",
    "name": "Plugin Marketplace"
  }
]
```

Add to `contributes.commands`:
```json
{
  "command": "workflow.installPlugin",
  "title": "Install Plugin",
  "icon": "$(cloud-download)"
},
{
  "command": "workflow.refreshMarketplace",
  "title": "Refresh Marketplace",
  "icon": "$(refresh)"
}
```

**Step 2: Create MarketplaceProvider.ts**

```typescript
import * as vscode from 'vscode';

const REGISTRY_URL = 'https://gocodealone.github.io/workflow-registry/v1';
const CACHE_TTL_MS = 15 * 60 * 1000; // 15 minutes

interface RegistryPlugin {
  name: string;
  description: string;
  version: string;
  tier: string;
  type: string;
  keywords: string[];
  repository: string;
  capabilities: {
    stepTypes: string[];
    moduleTypes: string[];
  };
}

export class MarketplaceProvider implements vscode.TreeDataProvider<MarketplaceItem> {
  private _onDidChangeTreeData = new vscode.EventEmitter<MarketplaceItem | undefined>();
  readonly onDidChangeTreeData = this._onDidChangeTreeData.event;

  private cache: RegistryPlugin[] | null = null;
  private cacheTime = 0;

  refresh(): void {
    this.cache = null;
    this._onDidChangeTreeData.fire(undefined);
  }

  async getChildren(): Promise<MarketplaceItem[]> {
    const plugins = await this.fetchIndex();
    return plugins
      .filter(p => !p.private)
      .map(p => new MarketplaceItem(p));
  }

  getTreeItem(element: MarketplaceItem): vscode.TreeItem {
    return element;
  }

  private async fetchIndex(): Promise<RegistryPlugin[]> {
    if (this.cache && Date.now() - this.cacheTime < CACHE_TTL_MS) {
      return this.cache;
    }
    try {
      const resp = await fetch(`${REGISTRY_URL}/index.json`);
      if (!resp.ok) throw new Error(`HTTP ${resp.status}`);
      this.cache = await resp.json() as RegistryPlugin[];
      this.cacheTime = Date.now();
      return this.cache;
    } catch (e) {
      vscode.window.showWarningMessage(`Failed to fetch plugin registry: ${e}`);
      return [];
    }
  }
}

export class MarketplaceItem extends vscode.TreeItem {
  constructor(public readonly plugin: RegistryPlugin) {
    super(plugin.name, vscode.TreeItemCollapsibleState.None);
    this.description = `v${plugin.version} · ${plugin.tier}`;
    this.tooltip = new vscode.MarkdownString(
      `**${plugin.name}** v${plugin.version}\n\n${plugin.description}\n\n` +
      `Steps: ${plugin.capabilities?.stepTypes?.length || 0} · ` +
      `Modules: ${plugin.capabilities?.moduleTypes?.length || 0}`
    );
    this.contextValue = 'pluginMarketplaceItem';
    this.iconPath = new vscode.ThemeIcon(
      plugin.tier === 'core' ? 'verified' : 'extensions'
    );
  }
}
```

**Step 3: Register in extension.ts**

```typescript
import { MarketplaceProvider } from './marketplace/MarketplaceProvider';

// In activate():
const marketplaceProvider = new MarketplaceProvider();
context.subscriptions.push(
  vscode.window.registerTreeDataProvider('workflowPluginMarketplace', marketplaceProvider),
  vscode.commands.registerCommand('workflow.refreshMarketplace', () => marketplaceProvider.refresh()),
  vscode.commands.registerCommand('workflow.installPlugin', async (item: MarketplaceItem) => {
    const terminal = vscode.window.createTerminal('wfctl');
    terminal.sendText(`wfctl plugin install ${item.plugin.name}`);
    terminal.show();
  })
);
```

**Step 4: Commit**

```bash
cd /Users/jon/workspace/workflow-vscode
git add src/marketplace/ package.json src/extension.ts
git commit -m "feat: add plugin marketplace panel to VS Code extension"
```

---

### Task 12: JetBrains Marketplace Panel

**Files:**
- Create: `src/main/kotlin/.../marketplace/MarketplaceToolWindow.kt` (in workflow-jetbrains)
- Modify: `src/main/resources/META-INF/plugin.xml` (in workflow-jetbrains)

**Context:** Mirror the VS Code marketplace panel for JetBrains. Uses a tool window with a JBTable showing available plugins.

**Step 1: Create MarketplaceToolWindow.kt**

```kotlin
package com.gocodealone.workflow.marketplace

import com.intellij.openapi.project.Project
import com.intellij.openapi.wm.ToolWindow
import com.intellij.openapi.wm.ToolWindowFactory
import com.intellij.ui.content.ContentFactory
import com.intellij.ui.table.JBTable
import javax.swing.*
import javax.swing.table.DefaultTableModel
import com.intellij.openapi.application.ApplicationManager
import com.intellij.util.io.HttpRequests
import com.google.gson.Gson
import com.google.gson.reflect.TypeToken

class MarketplaceToolWindowFactory : ToolWindowFactory {
    override fun createToolWindowContent(project: Project, toolWindow: ToolWindow) {
        val panel = MarketplacePanel(project)
        val content = ContentFactory.getInstance().createContent(panel, "Plugins", false)
        toolWindow.contentManager.addContent(content)
    }
}

class MarketplacePanel(private val project: Project) : JPanel() {
    private val tableModel = DefaultTableModel(arrayOf("Name", "Version", "Tier", "Description"), 0)
    private val table = JBTable(tableModel)

    init {
        layout = BoxLayout(this, BoxLayout.Y_AXIS)
        add(JScrollPane(table))
        loadPlugins()
    }

    private fun loadPlugins() {
        ApplicationManager.getApplication().executeOnPooledThread {
            try {
                val json = HttpRequests.request("https://gocodealone.github.io/workflow-registry/v1/index.json")
                    .readString()
                val type = object : TypeToken<List<Map<String, Any>>>() {}.type
                val plugins: List<Map<String, Any>> = Gson().fromJson(json, type)
                SwingUtilities.invokeLater {
                    tableModel.rowCount = 0
                    for (p in plugins) {
                        val isPrivate = p["private"] as? Boolean ?: false
                        if (!isPrivate) {
                            tableModel.addRow(arrayOf(
                                p["name"] ?: "",
                                p["version"] ?: "",
                                p["tier"] ?: "",
                                p["description"] ?: ""
                            ))
                        }
                    }
                }
            } catch (e: Exception) {
                // Log warning
            }
        }
    }
}
```

**Step 2: Register tool window in plugin.xml**

```xml
<toolWindow id="Workflow Marketplace"
            factoryClass="com.gocodealone.workflow.marketplace.MarketplaceToolWindowFactory"
            anchor="right"
            icon="AllIcons.Actions.Download"/>
```

**Step 3: Commit**

```bash
cd /Users/jon/workspace/workflow-jetbrains
git add src/main/kotlin/ src/main/resources/META-INF/plugin.xml
git commit -m "feat: add plugin marketplace tool window"
```

---

### Task 13: Enable GitHub Pages on workflow-registry

**Files:** None (GitHub settings)

**Context:** GitHub Pages must be enabled on the workflow-registry repo to serve the static site.

**Step 1: Enable Pages via gh CLI**

```bash
# Enable GitHub Pages with GitHub Actions as the source
gh api repos/GoCodeAlone/workflow-registry/pages \
  --method POST \
  --field source='{"branch":"gh-pages","path":"/"}' \
  --field build_type=workflow \
  2>/dev/null || echo "Pages may already be configured"
```

**Step 2: Verify by triggering the build workflow**

```bash
cd /Users/jon/workspace/workflow-registry
gh workflow run build-pages.yml
```

**Step 3: Verify the site is live**

```bash
# After workflow completes:
curl -s https://gocodealone.github.io/workflow-registry/v1/index.json | jq length
# Expected: 41 (or current plugin count)
```

---

### Task 14: Update wfctl Registry Source to Support Static Pages URL

**Files:**
- Modify: `cmd/wfctl/registry_source.go` (in workflow repo)
- Modify: `cmd/wfctl/registry_config.go` (in workflow repo)

**Context:** Currently the registry source type is `github` and fetches raw content from the GitHub API. We need to add a `static` type that fetches from a base URL (GitHub Pages). This is faster and doesn't count against GitHub API rate limits.

**Step 1: Add StaticRegistrySource**

In `cmd/wfctl/registry_source.go`, add a new source type:

```go
// StaticRegistrySource fetches plugin data from a static HTTP endpoint (e.g., GitHub Pages).
type StaticRegistrySource struct {
    name    string
    baseURL string // e.g. "https://gocodealone.github.io/workflow-registry/v1"
}

func NewStaticRegistrySource(cfg RegistrySourceConfig) *StaticRegistrySource {
    return &StaticRegistrySource{
        name:    cfg.Name,
        baseURL: cfg.URL,
    }
}

func (s *StaticRegistrySource) Name() string { return s.name }

func (s *StaticRegistrySource) FetchManifest(name string) (*RegistryManifest, error) {
    url := fmt.Sprintf("%s/plugins/%s/manifest.json", s.baseURL, name)
    data, err := downloadURL(url)
    if err != nil {
        return nil, fmt.Errorf("fetch manifest for %q: %w", name, err)
    }
    var m RegistryManifest
    if err := json.Unmarshal(data, &m); err != nil {
        return nil, fmt.Errorf("parse manifest for %q: %w", name, err)
    }
    return &m, nil
}

func (s *StaticRegistrySource) SearchPlugins(query string) ([]PluginSearchResult, error) {
    url := fmt.Sprintf("%s/index.json", s.baseURL)
    data, err := downloadURL(url)
    if err != nil {
        return nil, fmt.Errorf("fetch index: %w", err)
    }
    var plugins []RegistryManifest
    if err := json.Unmarshal(data, &plugins); err != nil {
        return nil, fmt.Errorf("parse index: %w", err)
    }
    q := strings.ToLower(query)
    var results []PluginSearchResult
    for _, p := range plugins {
        if query == "" || strings.Contains(strings.ToLower(p.Name), q) ||
            strings.Contains(strings.ToLower(p.Description), q) {
            results = append(results, PluginSearchResult{
                Name: p.Name, Version: p.Version,
                Description: p.Description, Tier: p.Tier,
                Source: s.name,
            })
        }
    }
    return results, nil
}

func (s *StaticRegistrySource) ListPlugins() ([]string, error) {
    url := fmt.Sprintf("%s/index.json", s.baseURL)
    data, err := downloadURL(url)
    if err != nil {
        return nil, fmt.Errorf("fetch index: %w", err)
    }
    var plugins []struct{ Name string `json:"name"` }
    if err := json.Unmarshal(data, &plugins); err != nil {
        return nil, fmt.Errorf("parse index: %w", err)
    }
    names := make([]string, len(plugins))
    for i, p := range plugins {
        names[i] = p.Name
    }
    return names, nil
}
```

**Step 2: Add URL field to RegistrySourceConfig**

In `cmd/wfctl/registry_config.go`, add:
```go
type RegistrySourceConfig struct {
    Name     string `yaml:"name" json:"name"`
    Type     string `yaml:"type" json:"type"`     // "github" or "static"
    Owner    string `yaml:"owner" json:"owner"`   // GitHub owner (for type: github)
    Repo     string `yaml:"repo" json:"repo"`     // GitHub repo (for type: github)
    Branch   string `yaml:"branch" json:"branch"` // Git branch (for type: github)
    URL      string `yaml:"url" json:"url"`       // Base URL (for type: static)
    Token    string `yaml:"token" json:"token"`   // Auth token (for private registries)
    Priority int    `yaml:"priority" json:"priority"`
}
```

**Step 3: Update NewMultiRegistry to handle static type**

In `cmd/wfctl/multi_registry.go`, add the `static` case:

```go
case "static":
    sources = append(sources, NewStaticRegistrySource(sc))
```

**Step 4: Update DefaultRegistryConfig to use static type**

```go
func DefaultRegistryConfig() *RegistryConfig {
    return &RegistryConfig{
        Registries: []RegistrySourceConfig{
            {
                Name:     "default",
                Type:     "static",
                URL:      "https://gocodealone.github.io/workflow-registry/v1",
                Priority: 0,
            },
            {
                Name:     "github-fallback",
                Type:     "github",
                Owner:    registryOwner,
                Repo:     registryRepo,
                Branch:   registryBranch,
                Priority: 100,
            },
        },
    }
}
```

**Step 5: Run tests**

```bash
cd /Users/jon/workspace/workflow
go build ./cmd/wfctl/...
go test ./cmd/wfctl/... -count=1
```

**Step 6: Commit**

```bash
cd /Users/jon/workspace/workflow
git add cmd/wfctl/registry_source.go cmd/wfctl/registry_config.go cmd/wfctl/multi_registry.go
git commit -m "feat(wfctl): add static registry source type for GitHub Pages"
```

---

### Task 15: wfctl plugin install --local Support

**Files:**
- Modify: `cmd/wfctl/plugin_install.go` (in workflow repo)

**Context:** Users need to install plugins from a local build directory without going through the registry. This is essential for development workflows and private plugins.

**Step 1: Add the --local flag to runPluginInstall**

In `cmd/wfctl/plugin_install.go`, add to the FlagSet (after the `directURL` flag from Task 4):

```go
localPath := fs.String("local", "", "Install from a local plugin directory or build output")
```

After the `*directURL` check, add:

```go
if *localPath != "" {
    return installFromLocal(*localPath, pluginDirVal)
}
```

**Step 2: Implement installFromLocal**

```go
// installFromLocal copies a plugin from a local directory to the plugin install dir.
func installFromLocal(srcDir, pluginDir string) error {
    // Read plugin.json to determine the name.
    pjPath := filepath.Join(srcDir, "plugin.json")
    pjData, err := os.ReadFile(pjPath)
    if err != nil {
        return fmt.Errorf("read plugin.json in %s: %w", srcDir, err)
    }
    var pj installedPluginJSON
    if err := json.Unmarshal(pjData, &pj); err != nil {
        return fmt.Errorf("parse plugin.json: %w", err)
    }
    if pj.Name == "" {
        return fmt.Errorf("plugin.json missing name field")
    }

    pluginName := normalizePluginName(pj.Name)
    destDir := filepath.Join(pluginDir, pluginName)
    if err := os.MkdirAll(destDir, 0750); err != nil {
        return fmt.Errorf("create plugin dir: %w", err)
    }

    // Copy plugin.json
    if err := copyFile(pjPath, filepath.Join(destDir, "plugin.json")); err != nil {
        return err
    }

    // Copy the binary (look for the plugin binary by name or largest executable)
    binaryName := pluginName
    srcBinary := filepath.Join(srcDir, binaryName)
    if _, err := os.Stat(srcBinary); os.IsNotExist(err) {
        // Try full name
        fullName := "workflow-plugin-" + pluginName
        srcBinary = filepath.Join(srcDir, fullName)
        if _, err := os.Stat(srcBinary); os.IsNotExist(err) {
            return fmt.Errorf("no plugin binary found in %s (tried %s and %s)", srcDir, pluginName, fullName)
        }
    }
    if err := copyFile(srcBinary, filepath.Join(destDir, pluginName)); err != nil {
        return err
    }
    // Ensure executable
    _ = os.Chmod(filepath.Join(destDir, pluginName), 0750)

    fmt.Printf("Installed %s v%s from %s to %s\n", pluginName, pj.Version, srcDir, destDir)
    return nil
}

// copyFile copies a file from src to dst.
func copyFile(src, dst string) error {
    in, err := os.Open(src)
    if err != nil {
        return fmt.Errorf("open %s: %w", src, err)
    }
    defer in.Close()
    out, err := os.Create(dst)
    if err != nil {
        return fmt.Errorf("create %s: %w", dst, err)
    }
    defer out.Close()
    if _, err := io.Copy(out, in); err != nil {
        return fmt.Errorf("copy %s to %s: %w", src, dst, err)
    }
    return nil
}
```

**Step 3: Run tests**

```bash
cd /Users/jon/workspace/workflow
go build ./cmd/wfctl/...
```

**Step 4: Commit**

```bash
cd /Users/jon/workspace/workflow
git add cmd/wfctl/plugin_install.go
git commit -m "feat(wfctl): add plugin install --local for local directory installs"
```

---

### Task 16: Engine Load-Time Checksum Verification

**Files:**
- Modify: `plugin/loader.go` (in workflow repo)

**Context:** The design requires that the engine verify the SHA-256 of on-disk plugin binaries against the lockfile on every load, preventing post-install tampering.

**Step 1: Add lockfile-based verification to LoadPlugin**

In `plugin/loader.go`, add a function that reads `.wfctl.yaml` and verifies the binary hash before loading:

```go
// VerifyPluginIntegrity checks the plugin binary's SHA-256 against the lockfile.
// Returns nil if no lockfile entry exists or if the checksum matches.
func VerifyPluginIntegrity(pluginDir, pluginName string) error {
    lockfilePath := filepath.Join(".", ".wfctl.yaml")
    data, err := os.ReadFile(lockfilePath)
    if os.IsNotExist(err) {
        return nil // no lockfile, skip verification
    }
    if err != nil {
        return fmt.Errorf("read lockfile: %w", err)
    }

    var lf struct {
        Plugins map[string]struct {
            SHA256 string `yaml:"sha256"`
        } `yaml:"plugins"`
    }
    if err := yaml.Unmarshal(data, &lf); err != nil {
        return nil // unparseable lockfile, skip
    }

    entry, ok := lf.Plugins[pluginName]
    if !ok || entry.SHA256 == "" {
        return nil // not pinned with checksum
    }

    binaryPath := filepath.Join(pluginDir, pluginName, pluginName)
    binaryData, err := os.ReadFile(binaryPath)
    if err != nil {
        return fmt.Errorf("read plugin binary %s: %w", binaryPath, err)
    }

    h := sha256.Sum256(binaryData)
    got := hex.EncodeToString(h[:])
    if !strings.EqualFold(got, entry.SHA256) {
        return fmt.Errorf("plugin %q binary integrity check failed: checksum %s does not match lockfile %s", pluginName, got, entry.SHA256)
    }
    return nil
}
```

**Step 2: Call VerifyPluginIntegrity before loading each external plugin**

In the engine's external plugin discovery/load path, add:

```go
if err := plugin.VerifyPluginIntegrity(pluginDir, pluginName); err != nil {
    logger.Error("plugin integrity check failed", "plugin", pluginName, "error", err)
    continue // skip loading tampered plugin
}
```

**Step 3: Run tests**

```bash
cd /Users/jon/workspace/workflow
go build ./...
go test ./plugin/... -count=1
```

**Step 4: Commit**

```bash
cd /Users/jon/workspace/workflow
git add plugin/loader.go
git commit -m "feat: verify plugin binary integrity against lockfile checksums on load"
```

---

### Task 17: Auto-Fetch Version Constraint Passthrough

**Files:**
- Modify: `plugin/autofetch.go` (in workflow repo, created in Task 7)

**Context:** Task 7's auto-fetch shells out to `wfctl plugin install` but doesn't pass the version constraint. The design says auto-fetch should respect `version: ">=0.1.0"` constraints and lockfile pins.

**Step 1: Update AutoFetchPlugin to accept and pass version**

```go
func AutoFetchPlugin(pluginName, version, pluginDir, registryConfigPath string) error {
    destDir := filepath.Join(pluginDir, pluginName)
    if _, err := os.Stat(filepath.Join(destDir, "plugin.json")); err == nil {
        return nil // already installed
    }

    fmt.Fprintf(os.Stderr, "[auto-fetch] Plugin %q not found locally, fetching from registry...\n", pluginName)

    // Build install argument with version if specified
    installArg := pluginName
    if version != "" {
        installArg = pluginName + "@" + strings.TrimPrefix(version, ">=")
    }

    args := []string{"plugin", "install", "--plugin-dir", pluginDir, installArg}
    cmd := exec.Command("wfctl", args...)
    cmd.Stdout = os.Stderr
    cmd.Stderr = os.Stderr
    if err := cmd.Run(); err != nil {
        return fmt.Errorf("auto-fetch plugin %q: %w", pluginName, err)
    }
    return nil
}
```

**Step 2: Update the engine callsite to pass version**

```go
if err := plugin.AutoFetchPlugin(ep.Name, ep.Version, e.pluginDir, ""); err != nil {
```

**Step 3: Commit**

```bash
cd /Users/jon/workspace/workflow
git add plugin/autofetch.go engine.go
git commit -m "feat: pass version constraint to auto-fetch plugin installs"
```
