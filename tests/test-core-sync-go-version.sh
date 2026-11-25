#!/usr/bin/env bash
# Core inspection compiles the checked-out Workflow module. Its go.mod owns
# the toolchain requirement; a registry-local version pin can silently age out.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
python3 - <<'PYTEST'
from pathlib import Path
import re

for name in ("sync-registry-manifests.yml", "validate.yml"):
    text = (Path(".github/workflows") / name).read_text()
    steps = re.split(r"(?m)^      - ", text)[1:]
    go_steps = [s for s in steps if "uses: actions/setup-go@" in s]
    assert len(go_steps) == 1, f"{name}: expected one Go setup step"
    setup = go_steps[0]
    assert re.search(r"(?m)^          go-version-file: ['\"]?_workflow/go\.mod['\"]?\s*$", setup), (
        f"{name}: core inspector must select Go from _workflow/go.mod, not a stale registry pin"
    )
    assert not re.search(r"(?m)^          go-version:", setup), f"{name}: go-version overrides the module requirement"
    assert re.search(r"(?m)^        id: go\s*$", setup), f"{name}: expose selected Go version for cache identity"
    caches = [s for s in steps if "uses: actions/cache@" in s]
    assert len(caches) == 1, f"{name}: expected one Go cache step"
    cache = caches[0]
    prefix = "${{ runner.os }}-go-${{ steps.go.outputs.go-version }}-"
    assert f"key: {prefix}${{{{ hashFiles('_workflow/go.sum') }}}}" in cache, f"{name}: cache key must use resolved Go version"
    assert f"restore-keys: |\n            {prefix}" in cache, f"{name}: restore key must use resolved Go version"
    print(f"PASS: {name} follows Workflow's Go requirement and isolates its cache")
PYTEST
