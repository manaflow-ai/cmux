#!/usr/bin/env bash
# The web bundle source key (scripts/cmux-next/web-bundle-key.py --source) moves
# when a file outside webviews/ that a bundle imports changes, and stays when an
# unrelated file changes (cx-wtsf3: a model-catalog-only commit kept the old key,
# so Mac builds, the CI cache and the HQ Linux pool shipped a stale catalog).
# It also checks that every imported input the key finds is in the path filter
# of cmux-next-web-bundle-publish.yml, in both cmux-next.yml path filters and in
# cmux_next_route.py BUNDLE_INPUTS,
# so a new import outside webviews/ cannot skip the publish or the bundle tier.
# Runs the key script of this checkout against a scratch repository made from
# HEAD's files (git archive), so it never touches this checkout's git config.
set -euo pipefail
# shellcheck source=scripts/cmux-next/tests/lib/git-fixture.sh
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/cmux-next/tests/lib/git-fixture.sh"  # turns off git's background maintenance in temp repos
# Every relative import outside webviews/ must resolve to a file the key hashes.
export WEB_BUNDLE_KEY_STRICT=1
ROOT=$(cd "$(dirname "$0")/.." && pwd)
KEY="$ROOT/scripts/cmux-next/web-bundle-key.py"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
fail() { printf 'FAIL: %s\n' "$@" >&2; exit 1; }
src="$TMP/src"
mkdir -p "$src"

git -C "$ROOT" archive HEAD webviews web/data clients/ts/cloud Resources/markdown-viewer config schemas release-notes/next/highlights \
  Packages/Shared/CmuxAgentQuestion \
  scripts/cmux-next/web-bundle-key.py scripts/webviews_bun_version.py README.md | tar -x -C "$src"
cp "$KEY" "$src/scripts/cmux-next/web-bundle-key.py"
git -C "$src" init -q
git -C "$src" -c user.name=t -c user.email=t@example.com -c core.hooksPath=/dev/null add -A
git -C "$src" -c user.name=t -c user.email=t@example.com -c core.hooksPath=/dev/null -c commit.gpgsign=false commit -q -m base

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
# A What's New highlight: gen-feature-tips.mjs makes the agent pane's tips from them.
expect_moves release-notes/next/highlights/agents-drive-visible-browser-tabs.md

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
if any("acpmux-preview" in p or "CmuxAgentQuestion" in p for p in imported):
    sys.exit("FAIL: the dev-only acpmux preview fixtures count as a bundle input")
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
ci = open(f"{root}/.github/workflows/cmux-next.yml").read().split("\njobs:", 1)[0]
# The pull_request and push path filters of cmux-next.yml (unquoted list items).
filters = [blk for blk in re.split(r"^\s+paths:\s*$", ci, flags=re.M)[1:]]
if len(filters) < 2:
    sys.exit("FAIL: cmux-next.yml has fewer than two path filters")
ci_lists = []
for blk in filters:
    items = []
    for line in blk.splitlines()[1:]:
        m = re.match(r"^\s+- (\S+)$", line)
        if m:
            items.append(gh_glob(m.group(1).strip('"')))
        elif line.strip() and not line.strip().startswith("#"):
            break
    ci_lists.append(items)
route_spec = importlib.util.spec_from_file_location("route", f"{root}/scripts/ci/cmux_next_route.py")
route = importlib.util.module_from_spec(route_spec)
sys.modules["route"] = route
route_spec.loader.exec_module(route)


def lines_of(path):
    return open(f"{root}/{path}", encoding="utf-8").read().split("\n")

def last_line(path, pattern, stop=None):
    """The 1-based number of the last line matching pattern (before the line matching stop)."""
    found = 0
    for number, line in enumerate(lines_of(path), start=1):
        if stop and re.search(stop, line):
            break
        if re.search(pattern, line):
            found = number
    return found

def filter_starts(path):
    """The 1-based line of each `paths:` key before jobs:, in order."""
    starts = []
    for number, line in enumerate(lines_of(path), start=1):
        if line.startswith("jobs:"):
            break
        if re.fullmatch(r"\s+paths:\s*", line):
            starts.append(number)
    return starts

def importers(target):
    """Where a webviews source imports target: `file:line` for each line naming its tail."""
    tail = "/".join(target.split("/")[-2:])
    sources = mod.git_files(root, ["webviews"])
    hits = []
    for rel in sources:
        if not rel.endswith(mod.SCANNED_SUFFIXES) or mod.UNSCANNED.search(rel):
            continue
        try:
            text = open(f"{root}/{rel}", encoding="utf-8", errors="replace").read()
        except OSError:
            continue
        for number, line in enumerate(text.split("\n"), start=1):
            if tail in line and any(spec.endswith(tail) for spec in mod.specifiers(line)):
                hits.append(f"{rel}:{number}")
    return hits or ["(a webviews source; run scripts/cmux-next/web-bundle-key.py . --inputs)"]

PUBLISH = ".github/workflows/cmux-next-web-bundle-publish.yml"
CI = ".github/workflows/cmux-next.yml"
ROUTE = "scripts/ci/cmux_next_route.py"
publish_end = last_line(PUBLISH, r'^\s+- "[^"]+"$', stop=r"^jobs:")
route_end = last_line(ROUTE, r"^\)$", stop=r"^BUNDLE_TARGETS\b")
ci_starts = filter_starts(CI)
missing = []
for f in files:
    where = []
    if not any(p.match(f) for p in publish):
        where.append(f'{PUBLISH}:{publish_end}: add `- "{f}"` to on.push.paths (after this line)')
    for i, items in enumerate(ci_lists):
        if not any(p.match(f) for p in items):
            start = ci_starts[i] if i < len(ci_starts) else 0
            where.append(f"{CI}:{start}: add `- {f}` to path filter {i + 1} (the `paths:` list here)")
    if not any(fnmatch.fnmatch(f, p) for p in route.BUNDLE_INPUTS):
        where.append(f'{ROUTE}:{route_end}: add `"{f}",` to BUNDLE_INPUTS (before this closing parenthesis)')
    if where:
        missing.append(f"{f} is a web bundle input, imported at " + ", ".join(importers(f))
                       + "; a change to it must publish the bundles and run the bundle tier:\n    "
                       + "\n    ".join(where))
if missing:
    sys.exit("FAIL: imported web bundle inputs are not routed:\n  " + "\n  ".join(missing))
PY

# The toolchain part of the key is the bun webviews/package.json pins, read by the one
# shared reader (scripts/webviews_bun_version.py): an npm entry listed first does not pick
# it, and no bun pin stops the key instead of keying bundles to a guessed 1.4.4.
pins="$TMP/pins"
mkdir -p "$pins/webviews"
identity() { env -u CMUX_WEB_BUN_VERSION CMUX_WEB_NODE_VERSION=24.22.1 python3 -I -c 'import runpy, sys; print(runpy.run_path(sys.argv[1])["toolchain_identity"](sys.argv[2]), end="")' "$KEY" "$pins" 2>&1; }
printf '{"devEngines": {"packageManager": [{"name": "npm", "version": "10.9.2"}, {"name": "bun", "version": "1.4.5"}]}}\n' > "$pins/webviews/package.json"
out=$(identity) || fail "npm listed first: $out"
[[ "$out" == $'bun=1.4.5\nnode=24.22.1' ]] || fail "npm listed first must key bun 1.4.5: $out"
printf '{"devEngines": {"packageManager": {"name": "npm", "version": "10.9.2"}}}\n' > "$pins/webviews/package.json"
status=0; out=$(identity) || status=$?
[[ "$status" != 0 && "$out" == *"no bun in devEngines.packageManager"* ]] || fail "no bun pin must stop the key: $status $out"
out=$(CMUX_WEB_BUN_VERSION=1.4.6 CMUX_WEB_NODE_VERSION=24.22.1 python3 -I -c 'import runpy, sys; print(runpy.run_path(sys.argv[1])["toolchain_identity"](sys.argv[2]), end="")' "$KEY" "$pins" 2>&1) \
  || fail "CMUX_WEB_BUN_VERSION must key without reading the pin: $out"
[[ "$out" == $'bun=1.4.6\nnode=24.22.1' ]] || fail "CMUX_WEB_BUN_VERSION must win: $out"

echo "web-bundle-key inputs: ok"
