#!/usr/bin/env bash
# The web bundle source key (scripts/cmux-next/web-bundle-key.py --source) moves
# when a file outside webviews/ that a bundle imports changes, and stays when an
# unrelated file changes (cx-wtsf3: a model-catalog-only commit kept the old key,
# so Mac builds, the CI cache and the HQ Linux pool shipped a stale catalog).
# It also checks that every imported input the key finds is in the path filter
# of cmux-next-web-bundle-publish.yml and in cmux_next_route.py BUNDLE_INPUTS,
# so a new import outside webviews/ cannot skip the publish or the bundle tier.
# Runs the key script of this checkout against a scratch repository made from
# HEAD's files (git archive), so it never touches this checkout's git config.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
KEY="$ROOT/scripts/cmux-next/web-bundle-key.py"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
fail() { printf 'FAIL: %s\n' "$@" >&2; exit 1; }
src="$TMP/src"
mkdir -p "$src"

git -C "$ROOT" archive HEAD webviews web/data Resources/markdown-viewer config schemas/settings \
  Packages/Shared/CmuxAgentQuestion scripts/cmux-next/web-bundle-key.py README.md | tar -x -C "$src"
cp "$KEY" "$src/scripts/cmux-next/web-bundle-key.py"
git -C "$src" init -q
git -C "$src" -c user.name=t -c user.email=t@example.com -c core.hooksPath=/dev/null add -A
git -C "$src" -c user.name=t -c user.email=t@example.com -c core.hooksPath=/dev/null commit -q -m base

key() { python3 "$KEY" "$src" --source; }
base=$(key)

expect_moves() {
  local rel=$1
  [ -f "$src/$rel" ] || fail "$rel is missing from the scratch repository"
  printf '\n' >>"$src/$rel"
  [ "$(key)" != "$base" ] || fail "changing $rel did not change the web bundle key"
  git -C "$src" checkout -q -- "$rel"
  [ "$(key)" = "$base" ] || fail "restoring $rel did not restore the web bundle key"
}

# The agent pane imports the model catalog (modelCatalogData.ts).
expect_moves web/data/model-catalog/snapshot.json
# The webviews app imports the viewer navigation script (App.tsx).
expect_moves Resources/markdown-viewer/viewer-navigation.js
# A webviews source itself.
expect_moves webviews/src/agent-session/acpmux/modelCatalogData.ts

# Unrelated files: a tracked edit outside the inputs and a new untracked file.
printf '\nunrelated\n' >>"$src/README.md"
mkdir -p "$src/web/other"
printf 'x\n' >"$src/web/other/notes.txt"
[ "$(key)" = "$base" ] || fail "an unrelated change moved the web bundle key"
git -C "$src" checkout -q -- README.md
rm -rf "$src/web/other"

# Every imported input is covered by the publish path filter and the route.
python3 - "$ROOT" "$KEY" <<'PY'
import fnmatch, importlib.util, re, subprocess, sys
root, key = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location("key", key)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
imported = mod.imported_inputs(root)
for want in ("web/data/model-catalog/snapshot.json", "Resources/markdown-viewer/viewer-navigation.js"):
    if want not in imported:
        sys.exit(f"FAIL: web-bundle-key.py does not find the import of {want}")
files = mod.git_files(root, imported)
if not files:
    sys.exit("FAIL: the imported inputs match no file")

workflow = open(f"{root}/.github/workflows/cmux-next-web-bundle-publish.yml").read()
on_block = workflow.split("\njobs:", 1)[0]
paths = re.findall(r'^\s+- "([^"]+)"$', on_block, re.M)

def gh_glob(pattern):
    out, i = "", 0
    while i < len(pattern):
        if pattern.startswith("**", i):
            out += ".*"; i += 2
        elif pattern[i] == "*":
            out += "[^/]*"; i += 1
        else:
            out += re.escape(pattern[i]); i += 1
    return re.compile(out + r"\Z")

publish = [gh_glob(p) for p in paths]
route_spec = importlib.util.spec_from_file_location("route", f"{root}/scripts/ci/cmux_next_route.py")
route = importlib.util.module_from_spec(route_spec)
sys.modules["route"] = route
route_spec.loader.exec_module(route)
missing = []
for f in files:
    if not any(p.match(f) for p in publish):
        missing.append(f"{f}: not in cmux-next-web-bundle-publish.yml on.push.paths")
    if not any(fnmatch.fnmatch(f, p) for p in route.BUNDLE_INPUTS):
        missing.append(f"{f}: not in scripts/ci/cmux_next_route.py BUNDLE_INPUTS")
if missing:
    sys.exit("FAIL: imported web bundle inputs are not routed:\n  " + "\n  ".join(missing))
PY

echo "web-bundle-key inputs: ok"
