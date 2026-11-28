#!/usr/bin/env bash
# The agent pane's first-load JavaScript at one or more commits, from one harness: builds the pane
# (build-agent-pane-web.sh --out) at each commit in its own scratch worktree and sums pane.js plus every
# chunk it imports statically (what the page parses before its first frame; the same walk as
# webviews/test/agent-pane-startup-bundle.test.ts). Also prints the bytes of all pane JS and of the
# chunks/ left to load on demand.
#   cmux-ci test -- bash -c 'scripts/measure/pane-startup-bytes.sh BASE_SHA HEAD_SHA; echo rc=$?'
# Prints "PANE-STARTUP <sha> startup_js_bytes=N startup_files=N total_js_bytes=N lazy_js_bytes=N".
set -uo pipefail
[[ $# -gt 0 ]] || { echo "usage: pane-startup-bytes.sh SHA..." >&2; exit 2; }
root="$(git rev-parse --show-toplevel)"
source "$root/scripts/measure/fetch-commit.sh"
scratch="$(mktemp -d)"
trees=()
cleanup() {
  for tree in ${trees[@]+"${trees[@]}"}; do git -C "$root" worktree remove --force "$tree" >/dev/null 2>&1; done
  rm -rf "$scratch"
}
trap cleanup EXIT
status=0
# step SHA WHAT CMD...: run one build step quietly; on failure print its last lines so a missing row says why.
step() {
  local sha="$1" what="$2"; shift 2
  "$@" >"$scratch/step.log" 2>&1 && return 0
  echo "PANE-STARTUP $sha FAILED at $what:" >&2; tail -15 "$scratch/step.log" >&2; return 1
}
for sha in "$@"; do
  tree="$scratch/$sha"
  measure_fetch_commit "$root" "$sha" 2>/dev/null || true
  git -C "$root" worktree add -q --detach "$tree" "$sha" || { status=1; continue; }
  trees+=("$tree")
  step "$sha" "bun install" bash -c 'cd "$1/webviews" && bun install --frozen-lockfile --ignore-scripts' _ "$tree" || { status=1; continue; }
  # build-agent-pane-web.sh writes only the agentPane strings table, but the pane also imports other pages'
  # tables (cloud's, from CloudEnvironmentEditorContent), which a full app build writes first: write them all.
  step "$sha" "gen-strings" bash -c 'cd "$1/webviews" && bun scripts/pages/gen-strings.mjs' _ "$tree" || { status=1; continue; }
  step "$sha" "pane build" bash -c 'cd "$1" && scripts/cmux-next/build-agent-pane-web.sh --out "$2"' _ "$tree" "$scratch/out-$sha" || { status=1; continue; }
  line="$(cd "$tree/webviews" && bun -e '
    const { readFileSync, readdirSync } = require("fs");
    const { dirname, resolve } = require("path");
    const out = process.argv[1];
    const seen = new Set();
    const queue = [resolve(out, "pane.js")];
    const scan = new Bun.Transpiler({ loader: "js" });
    let startup = 0;
    while (queue.length) {
      const file = queue.pop();
      if (seen.has(file)) continue;
      seen.add(file);
      const source = readFileSync(file, "utf8");
      startup += Buffer.byteLength(source);
      for (const item of scan.scanImports(source))
        if (item.kind === "import-statement" && item.path.startsWith(".")) queue.push(resolve(dirname(file), item.path));
    }
    let total = Buffer.byteLength(readFileSync(resolve(out, "pane.js")));
    for (const name of readdirSync(resolve(out, "chunks"))) if (name.endsWith(".js")) total += readFileSync(resolve(out, "chunks", name)).length;
    console.log(`startup_js_bytes=${startup} startup_files=${seen.size} total_js_bytes=${total} lazy_js_bytes=${total - startup}`);
  ' "$scratch/out-$sha")" || { status=1; continue; }
  echo "PANE-STARTUP $sha $line"
done
exit $status
