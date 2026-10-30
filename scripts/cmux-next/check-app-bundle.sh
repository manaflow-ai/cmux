#!/usr/bin/env bash
# Fails when a built cmux-next app bundle lacks a first-party app package the
# daemon must load (cx-t2rz, cx-0uo1). The one source of truth is
# first-party-apps/<name>/BUNDLED; scripts/cmux-next/sync-app-runtime.sh copies
# those packages into CmuxNextApps' resources, and the app points the daemon's
# app supervisor there (CMUX_APPS_FIRST_PARTY_DIR). For each BUNDLED app the
# built bundle must hold, in that directory:
#   - its manifest (cmux-app.v2.json, else cmux-app.json),
#   - the catalog file the manifest names (`catalog`),
#   - for a native server (`server.kind: native`), the darwin-arm64 binary
#     next to cmux-app-host in Contents/Resources/bin.
# scripts/reload.sh runs it on every built app, so a cmux-ci app build fails
# when a package or a server binary is missing.
# Usage: scripts/cmux-next/check-app-bundle.sh <path to cmux DEV ….app>
set -euo pipefail
app="${1:?usage: check-app-bundle.sh <app bundle>}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
exec python3 -I - "$root" "$app" <<'PY'
import json, os, sys

root, app = sys.argv[1], sys.argv[2]
resources = os.path.join(app, "Contents", "Resources")
first_party = os.path.join(resources, "CmuxNext_CmuxNextApps.bundle", "Contents", "Resources", "AppPlatform", "first-party")
bin_dir = os.path.join(resources, "bin")
source = os.path.join(root, "first-party-apps")
missing = []
checked = []
for name in sorted(os.listdir(source)):
    pkg = os.path.join(source, name)
    if not os.path.isfile(os.path.join(pkg, "BUNDLED")):
        continue
    manifest_name = "cmux-app.v2.json" if os.path.isfile(os.path.join(pkg, "cmux-app.v2.json")) else "cmux-app.json"
    built = os.path.join(first_party, name)
    built_manifest = os.path.join(built, manifest_name)
    if not os.path.isfile(built_manifest):
        missing.append(f"{name}: {os.path.relpath(built_manifest, app)}")
        continue
    with open(os.path.join(pkg, manifest_name)) as f:
        manifest = json.load(f)
    catalog = manifest.get("catalog")
    if isinstance(catalog, str) and not os.path.isfile(os.path.join(built, catalog)):
        missing.append(f"{name}: catalog {os.path.relpath(os.path.join(built, catalog), app)}")
    server = manifest.get("server") or {}
    if server.get("kind") == "native":
        binary = (server.get("binaries") or {}).get("darwin-arm64")
        if not isinstance(binary, str) or not binary:
            missing.append(f"{name}: server.binaries.darwin-arm64 is not named in {manifest_name}")
        elif not os.access(os.path.join(bin_dir, binary), os.X_OK):
            missing.append(f"{name}: server binary Contents/Resources/bin/{binary}")
    checked.append(name)
if missing:
    print("check-app-bundle: the built app lacks first-party app files the daemon loads:", file=sys.stderr)
    for line in missing:
        print(f"  {line}", file=sys.stderr)
    print("Run scripts/cmux-next/sync-app-runtime.sh and rebuild; a native server binary comes from the cmux-tui client build.", file=sys.stderr)
    sys.exit(1)
print(f"check-app-bundle: {len(checked)} first-party packages present ({', '.join(checked)})")
PY
