#!/usr/bin/env bash
# The cmux-next app finds Ghostty's themes in <app>/Contents/Resources/ghostty/themes
# (GhosttyRuntime.resourcesDirectory). Two build phases write Contents/Resources:
#   - the Resources phase copies the synchronized Resources/ folder, every file flat
#     by its name, except the target's exact membership exceptions (a folder listed
#     as an exception still has its files copied);
#   - "Bundle Ghostty resources" (bundle-ghostty-resources.sh) puts the directories
#     ghostty/, terminfo/, shell-integration/ and cmux-cli-path/ there.
# Xcode runs the Resources phase first; the fleet builder runs it after the script phases, and a flat file replaces a directory
# of the same name. When a flat resource is named like one of those directories, a
# fleet build ships no themes: every theme resolves to Ghostty's built-in default
# (#282C34), so `debug.appearance light` and a cmux.json theme change nothing
# (cx-31li). Whichever order the two phases run in, the themes must be there.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# The Resources phase's flat copy, from the project's exceptions for the cmux-next target.
flat_copy() {  # <dest Contents/Resources>
  python3 -I - "$ROOT" "$1" <<'PY'
import os, re, shutil, sys
root, dest = sys.argv[1], sys.argv[2]
text = open(os.path.join(root, "cmux.xcodeproj", "project.pbxproj")).read()
block = re.search(r'/\* Exceptions for "Resources" folder in "cmux-next" target \*/ = \{(.*?)\n\t\t\};', text, re.S)
exceptions = set()
if block:
    members = re.search(r"membershipExceptions = \((.*?)\);", block.group(1), re.S)
    exceptions = {m.strip().strip('"') for m in members.group(1).split(",") if m.strip()} if members else set()
group = re.search(r'/\* Resources \*/ = \{\s*isa = PBXFileSystemSynchronizedRootGroup;(.*?)\n\t\t\};', text, re.S)
explicit = set()
if group:
    folders = re.search(r"explicitFolders = \((.*?)\);", group.group(1), re.S)
    explicit = {m.strip().strip('"') for m in folders.group(1).split(",") if m.strip()} if folders else set()
packages = {".icon", ".xcassets", ".bundle", ".app", ".framework", ".rtfd", ".xcstrings"}
sources = {".swift", ".m", ".mm", ".c", ".cc", ".cpp", ".h", ".ts", ".tsx", ".metal", ".modulemap"}
src_root = os.path.join(root, "Resources")
copied = []
for dirpath, dirnames, filenames in os.walk(src_root):
    rel = os.path.relpath(dirpath, src_root)
    rel = "" if rel == "." else rel + "/"
    dirnames[:] = [d for d in sorted(dirnames) if rel + d not in explicit and os.path.splitext(d)[1] not in packages]
    for name in sorted(filenames):
        if rel + name in exceptions or name == ".DS_Store" or os.path.splitext(name)[1] in sources:
            continue
        copied.append((rel + name, os.path.join(dirpath, name)))
os.makedirs(dest, exist_ok=True)
for rel, path in sorted(copied):
    target = os.path.join(dest, os.path.basename(rel))
    if os.path.isdir(target) and not os.path.islink(target):
        print(f"flat resource {rel} replaces the directory {os.path.basename(rel)}/", file=sys.stderr)
        shutil.rmtree(target)
    shutil.copy2(path, target)
PY
}

phase() {  # <build dir>
  local src="$TMP/src"
  if [[ ! -d "$src" ]]; then
    mkdir -p "$src/Resources"
    for path in Resources/ghostty Resources/terminfo-overlay Resources/shell-integration Resources/cmux-cli-path; do
      [[ -e "$ROOT/$path" ]] && ln -s "$ROOT/$path" "$src/$path"
    done
  fi
  env -i PATH=/usr/bin:/bin TARGET_BUILD_DIR="$1" UNLOCALIZED_RESOURCES_FOLDER_PATH=app.app/Contents/Resources \
    SRCROOT="$src" bash "$ROOT/scripts/cmux-next/bundle-ghostty-resources.sh" >"$1.log" 2>&1 \
    || { cat "$1.log" >&2; echo "FAIL: the Bundle Ghostty resources phase failed" >&2; exit 1; }
}

fail=0
check() {  # <order> <Contents/Resources>
  local res="$2" theme
  for theme in "Apple System Colors" "Apple System Colors Light"; do
    [[ -f "$res/ghostty/themes/$theme" ]] || { echo "FAIL ($1): no ghostty/themes/$theme in the bundle" >&2; fail=1; }
  done
  [[ -f "$res/terminfo/78/xterm-ghostty" ]] || { echo "FAIL ($1): no terminfo/78/xterm-ghostty in the bundle" >&2; fail=1; }
  # Every directory the script phases put in Resources stays a directory.
  local dir
  for dir in ghostty terminfo shell-integration cmux-cli-path bin libexec; do
    [[ ! -e "$res/$dir" || -d "$res/$dir" ]] || { echo "FAIL ($1): $dir is a flat file, not a directory" >&2; fail=1; }
  done
}

# Xcode: the Resources phase, then the script phase.
xcode="$TMP/xcode"
flat_copy "$xcode/app.app/Contents/Resources" 2>"$TMP/xcode-flat.log"
phase "$xcode"
check "Resources phase first" "$xcode/app.app/Contents/Resources"

# The fleet builder: the script phase, then the Resources phase.
fleet="$TMP/fleet"
phase "$fleet"
flat_copy "$fleet/app.app/Contents/Resources" 2>"$TMP/fleet-flat.log" || { cat "$TMP/fleet-flat.log" >&2; echo "FAIL: the flat copy failed" >&2; exit 1; }
cat "$TMP/fleet-flat.log" >&2
check "script phase first" "$fleet/app.app/Contents/Resources"

[[ $fail -eq 0 ]] || exit 1
echo "PASS: the bundle has Ghostty's themes and terminfo whichever order the resource phases run in"
