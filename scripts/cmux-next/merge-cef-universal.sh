#!/usr/bin/env bash
# Merges the arm64 and x86_64 CEF artifacts (ensure-cef.sh --arch) into one
# universal "Chromium Embedded Framework.framework" for the universal app, and
# prints the merged directory on stdout.
#
#   merge-cef-universal.sh <arm64_dist> <x86_64_dist> <cache_root>
#
# Every file of the framework:
#   - Mach-O in both dists      -> lipo -create of the two
#   - in one dist only          -> copied (arch-named files such as
#                                  v8_context_snapshot.<arch>.bin)
#   - identical in both         -> copied once
#   - property lists that differ only in the Xcode and SDK the arch was
#     built with (DT* keys, BuildMachineOSBuild) -> the arm64 copy
#   - different, not Mach-O     -> the arm64 copy when the name is in
#                                  ALLOWED_DIFFERENT (caches the engine
#                                  rebuilds), otherwise the merge fails
#
# The result, <cache_root>/<arm64 dist name>-universal-<key>, is
# content-addressed by the two artifact checksums and this script, built in a
# private temporary directory and renamed into place, so concurrent builds
# share it. Only the framework and CMUX-ARTIFACT.json are in it: the shim is
# built from each arch's own dist (embed-cef.sh).
set -euo pipefail

arm="${1:?usage: merge-cef-universal.sh <arm64_dist> <x86_64_dist> <cache_root>}"
x86="${2:?usage: merge-cef-universal.sh <arm64_dist> <x86_64_dist> <cache_root>}"
root="${3:?usage: merge-cef-universal.sh <arm64_dist> <x86_64_dist> <cache_root>}"
FW="Chromium Embedded Framework.framework"
ALLOWED_DIFFERENT="${CMUX_CEF_MERGE_ALLOWED_DIFFERENT:-gpu_shader_cache.bin}"

for dist in "$arm" "$x86"; do
  [[ -d "$dist/$FW" && -f "$dist/.verified" ]] || { echo "error: $dist is not a verified CEF dist" >&2; exit 1; }
done
key="$(
  { cat "$arm/.verified"; echo; cat "$x86/.verified"; echo; echo "$ALLOWED_DIFFERENT"; shasum -a 256 "${BASH_SOURCE[0]}"; } |
    shasum -a 256 | awk '{print substr($1, 1, 16)}'
)"
final="$root/$(basename "$arm")-universal-$key"
if [[ -f "$final/.merged" ]]; then
  echo "$final"
  exit 0
fi

mkdir -p "$root"
tmp="$(mktemp -d "$root/.merging.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
echo "==> merging CEF arm64 + x86_64 into $final" >&2
/usr/bin/python3 - "$arm/$FW" "$x86/$FW" "$tmp/$FW" "$ALLOWED_DIFFERENT" <<'PY'
import filecmp, os, plistlib, shutil, subprocess, sys

arm, x86, out, allowed = sys.argv[1], sys.argv[2], sys.argv[3], set(sys.argv[4].split())
MACHO = {b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xfe\xed\xfa\xce", b"\xca\xfe\xba\xbe"}

def macho(path):
    with open(path, "rb") as handle:
        return handle.read(4) in MACHO

def same_plist(a, x):
    """Equal apart from the build machine's Xcode and SDK keys (the arches
    may be built on different Macs)."""
    if not a.endswith(".plist"):
        return False
    try:
        with open(a, "rb") as fa, open(x, "rb") as fx:
            pa, px = plistlib.load(fa), plistlib.load(fx)
    except Exception:
        return False
    def strip(p):
        return {k: v for k, v in p.items() if not (k.startswith("DT") or k == "BuildMachineOSBuild")}
    return isinstance(pa, dict) and isinstance(px, dict) and strip(pa) == strip(px)

def files(base):
    found = set()
    for directory, _, names in os.walk(base):
        for name in names:
            found.add(os.path.relpath(os.path.join(directory, name), base))
    return found

def copy(source, target):
    os.makedirs(os.path.dirname(target), exist_ok=True)
    shutil.copy2(source, target, follow_symlinks=False)

arm_files, x86_files = files(arm), files(x86)
errors, merged = [], 0
for rel in sorted(arm_files | x86_files):
    target = os.path.join(out, rel)
    a, x = os.path.join(arm, rel), os.path.join(x86, rel)
    if rel not in x86_files or rel not in arm_files:
        copy(a if rel in arm_files else x, target)
    elif os.path.islink(a) or os.path.islink(x):
        if not (os.path.islink(a) and os.path.islink(x) and os.readlink(a) == os.readlink(x)):
            errors.append(f"symlink differs: {rel}")
        copy(a, target)
    elif macho(a) and macho(x):
        os.makedirs(os.path.dirname(target), exist_ok=True)
        subprocess.run(["lipo", "-create", a, x, "-output", target], check=True)
        shutil.copymode(a, target)
        merged += 1
    elif filecmp.cmp(a, x, shallow=False) or same_plist(a, x):
        copy(a, target)
    elif os.path.basename(rel) in allowed:
        print(f"note: {rel} differs between arches; keeping the arm64 copy", file=sys.stderr)
        copy(a, target)
    else:
        errors.append(f"differs and is not Mach-O: {rel}")
if errors:
    print("error: cannot merge the CEF arches:\n  " + "\n  ".join(errors), file=sys.stderr)
    sys.exit(1)
print(f"==> lipo-merged {merged} Mach-O files", file=sys.stderr)
PY
[[ -f "$arm/CMUX-ARTIFACT.json" ]] && cp "$arm/CMUX-ARTIFACT.json" "$tmp/"
printf '%s\n%s\n' "$(cat "$arm/.verified")" "$(cat "$x86/.verified")" > "$tmp/.merged"
if ! /usr/bin/python3 -c 'import os, sys; os.rename(sys.argv[1], sys.argv[2])' "$tmp" "$final" 2>/dev/null; then
  [[ -f "$final/.merged" ]] || { echo "error: $final exists but is incomplete" >&2; exit 1; }
fi
echo "$final"
