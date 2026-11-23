#!/usr/bin/env bash
# Fails when a built cmux-next app bundle lacks a first-party app package the
# daemon must load (cx-t2rz, cx-0uo1), or an App Store package it must list.
# The sources of truth are the markers: first-party-apps/<name>/BUNDLED, and
# STORE in samples/apps/<name> and first-party-apps/<name> (without BUNDLED);
# scripts/cmux-next/sync-app-runtime.sh copies those packages into CmuxNextApps'
# resources (store/ at build time, by build-web-bundles.sh), and the app points
# the daemon's app supervisor there (CMUX_APPS_FIRST_PARTY_DIR, CMUX_APPS_DIRS).
# For each BUNDLED app the built bundle must hold, in AppPlatform/first-party:
#   - its manifest (cmux-app.v2.json, else cmux-app.json),
#   - the catalog file the manifest names (`catalog`),
#   - for a native server (`server.kind: native`), the darwin-arm64 binary
#     next to cmux-app-host in Contents/Resources/bin.
# For each STORE app it must hold, in AppPlatform/store/<name>: cmux-app.v2.json
# and every package file that manifest names (runtime.main, catalog, an icon
# path, screenshots).
# scripts/reload.sh runs it on every built app, so a cmux-ci app build fails
# when a package or a server binary is missing.
# CMUX_APP_SAMPLES_DIR and CMUX_APP_FIRST_PARTY_DIR override the source directories (tests).
# Usage: scripts/cmux-next/check-app-bundle.sh <path to cmux DEV ….app>
set -euo pipefail
app="${1:?usage: check-app-bundle.sh <app bundle>}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
exec python3 -I - "$app" "${CMUX_APP_FIRST_PARTY_DIR:-$root/first-party-apps}" "${CMUX_APP_SAMPLES_DIR:-$root/samples/apps}" <<'PY'
import json, os, sys

app, source, samples = sys.argv[1], sys.argv[2], sys.argv[3]
resources = os.path.join(app, "Contents", "Resources")
platform = os.path.join(resources, "CmuxNext_CmuxNextApps.bundle", "Contents", "Resources", "AppPlatform")
first_party = os.path.join(platform, "first-party")
store = os.path.join(platform, "store")
bin_dir = os.path.join(resources, "bin")
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

# The App Store packages: the STORE samples, then the STORE first-party apps that are not BUNDLED.
listed = []
def store_packages():
    for folder, first in ((samples, False), (source, True)):
        if not os.path.isdir(folder):
            continue
        for name in sorted(os.listdir(folder)):
            pkg = os.path.join(folder, name)
            if not os.path.isfile(os.path.join(pkg, "STORE")):
                continue
            if first and os.path.isfile(os.path.join(pkg, "BUNDLED")):
                continue
            yield name
for name in store_packages():
    built_manifest = os.path.join(store, name, "cmux-app.v2.json")
    if not os.path.isfile(built_manifest):
        missing.append(f"{name}: App Store package {os.path.relpath(built_manifest, app)}")
        continue
    with open(built_manifest) as f:
        manifest = json.load(f)
    named = [(manifest.get("runtime") or {}).get("main"), manifest.get("catalog"), manifest.get("icon")]
    named += manifest.get("screenshots") or []
    for path in named:
        if isinstance(path, str) and path and not os.path.isfile(os.path.join(store, name, path)):
            missing.append(f"{name}: {os.path.relpath(os.path.join(store, name, path), app)}")
    listed.append(name)
if missing:
    print("check-app-bundle: the built app lacks app package files the daemon loads:", file=sys.stderr)
    for line in missing:
        print(f"  {line}", file=sys.stderr)
    print("Run scripts/cmux-next/build-web-bundles.sh (it writes the App Store packages) and rebuild; "
          "a native server binary comes from the cmux-tui client build.", file=sys.stderr)
    sys.exit(1)
print(f"check-app-bundle: {len(checked)} first-party packages present ({', '.join(checked)}); "
      f"{len(listed)} App Store packages present ({', '.join(listed)})")
PY
