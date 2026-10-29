#!/usr/bin/env bash
# Rename Sparkle delta files to release-asset-safe, track-specific names and
# rewrite the matching enclosure URLs in the appcast.
#
#   scripts/ci/finalize-sparkle-deltas.sh <appcast.xml> <archives-dir> <out-dir> <name-prefix>
#
# generate_appcast writes "<app name><new>-<old>.delta" (e.g. "cmux NIGHTLY123-100.delta")
# into <archives-dir>. The name carries a space, which GitHub rewrites on
# upload, and it is identical for every per-architecture track. Each delta is
# moved to <out-dir>/<name-prefix><new>-<old>.delta and the appcast's URL for
# it (percent-encoded by generate_appcast) is rewritten to the new basename.
set -euo pipefail

if [ "$#" -ne 4 ]; then
  sed -n '2,11p' "$0" >&2
  exit 2
fi
APPCAST="$1"
ARCHIVES_DIR="$2"
OUT_DIR="$3"
PREFIX="$4"
[ -f "$APPCAST" ] || { echo "error: appcast not found: $APPCAST" >&2; exit 1; }
[ -d "$ARCHIVES_DIR" ] || { echo "error: archives dir not found: $ARCHIVES_DIR" >&2; exit 1; }
mkdir -p "$OUT_DIR"

python3 - "$APPCAST" "$ARCHIVES_DIR" "$OUT_DIR" "$PREFIX" <<'EOF'
import os, re, sys, urllib.parse
appcast, archives, out_dir, prefix = sys.argv[1:5]
xml = open(appcast, encoding="utf-8").read()
renamed = 0
for name in sorted(os.listdir(archives)):
    if not name.endswith(".delta"):
        continue
    match = re.search(r"(\d+-\d+)\.delta$", name)
    if not match:
        print(f"error: unexpected delta name {name!r}", file=sys.stderr)
        sys.exit(1)
    new_name = f"{prefix}{match.group(1)}.delta"
    encoded = urllib.parse.quote(name)
    if encoded not in xml and name not in xml:
        print(f"error: appcast does not reference delta {name!r}", file=sys.stderr)
        sys.exit(1)
    xml = xml.replace(encoded, new_name).replace(name, new_name)
    os.replace(os.path.join(archives, name), os.path.join(out_dir, new_name))
    print(f"delta {name} -> {new_name}")
    renamed += 1
open(appcast, "w", encoding="utf-8").write(xml)
print(f"finalized {renamed} delta(s)")
EOF
