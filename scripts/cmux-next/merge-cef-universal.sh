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
# content-addressed by the two artifact checksums and this script's bytes
# (never a path: each fleet step checks out under its own directory), built in
# a private temporary directory and renamed into place, so concurrent builds
# and later checkouts share it. Only the framework and CMUX-ARTIFACT.json are
# in it: the shim is built from each arch's own dist (embed-cef.sh).
#
# Each entry is ~0.67 GiB, so the cache is bounded where it is written: a use
# touches the entry's .merged, and every run then removes the entries past the
# CMUX_CEF_UNIVERSAL_KEEP (default 3) most recently used, and any entry unused
# for 7 days. An entry used in the last hour is never removed (a build copies
# it out within minutes of its use), and removal renames an entry out of its
# name before deleting it, so no build ever sees half of one.
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
  { cat "$arm/.verified"; echo; cat "$x86/.verified"; echo; echo "$ALLOWED_DIFFERENT"; shasum -a 256 < "${BASH_SOURCE[0]}"; } |
    shasum -a 256 | awk '{print substr($1, 1, 16)}'
)"
final="$root/$(basename "$arm")-universal-$key"

# Removes the entries this run does not use (see the header). Never fails the
# merge: a cache it cannot trim is still a correct cache.
prune() {
  /usr/bin/python3 - "$root" "$(basename "$final")" "${CMUX_CEF_UNIVERSAL_KEEP:-3}" <<'PY' || true
import os, shutil, sys, time

root, current, keep = sys.argv[1], sys.argv[2], max(1, int(sys.argv[3]))
IN_USE, MAX_AGE, STALE_TMP = 3600, 7 * 86400, 86400

def age(entry):
    """Seconds since the entry's last use: .merged's mtime (a rename of the
    entry leaves it alone), else the directory's for an incomplete entry."""
    for path in (os.path.join(entry, ".merged"), entry):
        try:
            return time.time() - os.stat(path).st_mtime
        except OSError:
            pass
    return None

def remove(name):
    path, gone = os.path.join(root, name), os.path.join(root, f".deleting.{name}.{os.getpid()}")
    try:
        os.rename(path, gone)
    except OSError:
        return
    # Used between the scan and the rename: put it back, unless a new merge
    # already took the name (then the copy here is a duplicate).
    if (age(gone) or 0) < IN_USE:
        try:
            os.rename(gone, path)
            return
        except OSError:
            pass
    shutil.rmtree(gone, ignore_errors=True)

def alive(pid):
    try:
        os.kill(int(pid), 0)
    except ProcessLookupError:
        return False
    except (ValueError, OSError):
        return True
    return True

entries = []
for name in os.listdir(root):
    path = os.path.join(root, name)
    if name.startswith(".merging.") and (age(path) or 0) > STALE_TMP:
        shutil.rmtree(path, ignore_errors=True)
    elif name.startswith(".deleting.") and not alive(name.rsplit(".", 1)[-1]):
        shutil.rmtree(path, ignore_errors=True)  # a prune that died mid-delete
    elif not name.startswith(".") and name != current and "-universal-" in name and os.path.isdir(path):
        entry_age = age(path)
        if entry_age is not None:
            entries.append((entry_age, name))
for index, (entry_age, name) in enumerate(sorted(entries)):
    # `current` is one of the `keep` entries.
    if entry_age > IN_USE and (index >= keep - 1 or entry_age > MAX_AGE):
        remove(name)
PY
}

# A use marks the entry as recently used before the check, so a concurrent
# prune that saw it as old puts it back (prune above).
touch -c "$final/.merged" 2>/dev/null || true
if [[ -f "$final/.merged" ]]; then
  prune
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
touch -c "$final/.merged" 2>/dev/null || true
prune
echo "$final"
