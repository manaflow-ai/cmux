#!/bin/sh
# tooling-steps runs: scripts/cmux-next/web-bundle-key.py scripts/cmux-next/sync-app-runtime.sh
# Builds every web bundle the cmux-next app ships, from the current sources:
# the agent pane, the React pages, Agent Activity, the
# webviews app (diff, markdown and editor pages) and the Chief memory inspector,
# and writes the App Store packages (sync-app-runtime.sh --store).
# Every app build path runs it
# before it compiles (scripts/reload.sh, scripts/cmux-next/check-release-compile.sh,
# the macOS jobs of cmux-next.yml, the nightly-next build, nx-remote Swift test
# jobs), so a build never depends on a committed copy of the output (cx-vn5).
#
#   scripts/cmux-next/build-web-bundles.sh               # build what is stale
#   scripts/cmux-next/build-web-bundles.sh --force       # rebuild everything
#   scripts/cmux-next/build-web-bundles.sh --verify      # exit 1 if not current
#   scripts/cmux-next/build-web-bundles.sh --out-root D  # build into D (same
#                                                        # relative paths), no stamp
#   scripts/cmux-next/build-web-bundles.sh --from D      # install bundles built into D
#                                                        # for this source key, and stamp
#
# A build records the source key (web-bundle-key.py: every input file, bun's
# version) and the output digest in .web-bundles.key at the repository root
# (gitignored). The next run skips the build when both still match, so a warm
# tree costs about a second. Release and nightly builds pass --force.
#
# Needs the bun that webviews/package.json pins, or a newer one of the same major
# (scripts/check-webviews-bun-version.sh),
# and node 22.18 or newer. The fleet recipe provides both; locally:
# curl -fsSL https://bun.sh/install | bash -s bun-v<pin>
set -eu

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)"
# An inherited `BUN_OPTIONS=--preload PATH` would fail every bun install here; this joins it to --preload=PATH.
. "$ROOT/scripts/lib/bun-options.sh"
# bun exits "EACCES accessing temporary directory" when its temp dir is not
# writable (hetzner-2-21, run 46053948772). Use the first writable candidate.
if [ -z "${BUN_TMPDIR:-}" ]; then
  for candidate in "${RUNNER_TEMP:-}" "${TMPDIR:-}" /tmp "${HOME:-}/.cache"; do
    [ -n "$candidate" ] || continue
    if mkdir -p "$candidate/bun-tmp" 2>/dev/null && [ -w "$candidate/bun-tmp" ]; then
      BUN_TMPDIR="$candidate/bun-tmp"
      export BUN_TMPDIR
      break
    fi
  done
fi
MODE=build
OUT_ROOT=""
REPORT_DIR="${CMUX_BUNDLE_REPORT_DIR:-}"
while [ $# -gt 0 ]; do
  case "$1" in
    --force) MODE=force ;;
    --verify) MODE=verify ;;
    --out-root)
      [ $# -ge 2 ] || { echo "error: --out-root needs a directory" >&2; exit 2; }
      case "$2" in /*) OUT_ROOT="$2" ;; *) OUT_ROOT="$PWD/$2" ;; esac
      shift ;;
    --report-dir)
      [ $# -ge 2 ] || { echo "error: --report-dir needs a directory" >&2; exit 2; }
      case "$2" in /*) REPORT_DIR="$2" ;; *) REPORT_DIR="$PWD/$2" ;; esac
      shift ;;
    --from)
      [ $# -ge 2 ] || { echo "error: --from needs a directory" >&2; exit 2; }
      MODE=from
      case "$2" in /*) FROM_ROOT="$2" ;; *) FROM_ROOT="$PWD/$2" ;; esac
      shift ;;
    -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
    *) echo "usage: $0 [--force | --verify] [--out-root DIR] [--report-dir DIR] [--from DIR]" >&2; exit 2 ;;
  esac
  shift
done

# The output paths, relative to the repository root, and the builder of each.
PANE="Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane/Resources/agent-pane"
PAGES="Packages/macOS/CmuxNext/Sources/CmuxNextPages/Resources/pages"
ACTIVITY="Packages/macOS/CmuxNext/Sources/CmuxNextAgentActivity/Resources/agent-activity"
APP="Resources/markdown-viewer/webviews-app"
INSPECTOR="Native/OptChat/optchat-chief/inspector"
STAMP="$ROOT/.web-bundles.key"
KEY="$ROOT/scripts/cmux-next/web-bundle-key.py"

# CMUX_WEB_BUNDLES_TOOLS_OPTIONAL=1 (scripts/reload.sh while the bundles are
# still committed): a missing or wrong bun or node is a warning and exit 0, so
# a build log does not show an "error:" line for a build that ships the
# committed bundles. Any other failure still fails.
missing_tool() {
  if [ "${CMUX_WEB_BUNDLES_TOOLS_OPTIONAL:-0}" = 1 ]; then
    echo "warning: $1 (this build ships the committed bundles)" >&2
    exit 0
  fi
  echo "error: $1" >&2
  exit 1
}

need_bun() {
  want="$(python3 -I "$ROOT/scripts/webviews_bun_version.py" "$ROOT/webviews/package.json" 2>/dev/null || true)"
  if ! command -v bun >/dev/null 2>&1; then
    missing_tool "the cmux-next web bundles need bun ${want:-(see webviews/package.json devEngines)} or newer; install it: curl -fsSL https://bun.sh/install | bash -s bun-v${want:-<version>}"
  fi
  if [ "${CMUX_WEB_BUNDLES_TOOLS_OPTIONAL:-0}" = 1 ] && ! "$ROOT/scripts/check-webviews-bun-version.sh" --quiet; then
    missing_tool "the cmux-next web bundles need bun ${want:-(see webviews/package.json devEngines)} or newer; $(command -v bun) is bun $(bun --version); install it: curl -fsSL https://bun.sh/install | bash -s bun-v${want:-<version>}"
  fi
  "$ROOT/scripts/check-webviews-bun-version.sh"
  # `vp build` (the webviews app) runs on node when node is on PATH and on bun
  # otherwise, and the two emit different bytes (Vite stringifies its preload
  # helper with the runtime's Function.prototype.toString). Require node so
  # every host builds the same app; Vite+ needs node 22.18 or newer.
  if ! command -v node >/dev/null 2>&1 \
    || ! node -e 'const [a, b] = process.versions.node.split(".").map(Number); process.exit(a > 22 || (a === 22 && b >= 18) ? 0 : 1)'; then
    missing_tool "the webviews app build needs node 22.18 or newer on PATH (found: $(command -v node >/dev/null 2>&1 && node --version || echo none))"
  fi
}

current() {
  [ -f "$STAMP" ] || return 1
  [ "$(python3 "$KEY" "$ROOT" --stamp)" = "$(cat "$STAMP")" ]
}

# --verify ignores the bun field: the Xcode phase's PATH may lack bun.
verified() {
  [ -f "$STAMP" ] || return 1
  [ "$(python3 "$KEY" "$ROOT" --verify-stamp)" = "$(cut -d' ' -f1-2 "$STAMP")" ]
}

# The App Store packages the app bundles (AppPlatform/store: samples/apps and first-party-apps with
# a STORE marker) are build output too (Leo, 2026-10-21: "don't commit generatable files"): plain
# copies of committed packages, no bun, so every in-tree run writes them, and --verify checks them.
# Every checkout has the script; a scratch tree holding only the bundle scripts (the tests of
# --from, ensure-web-bundles and the report run) has no app platform to write, so it is skipped there.
STORE_SYNC="$ROOT/scripts/cmux-next/sync-app-runtime.sh"
[ -f "$STORE_SYNC" ] || STORE_SYNC=""

if [ "$MODE" = verify ]; then
  if [ -n "$STORE_SYNC" ] && ! "$STORE_SYNC" --store --check; then
    echo "error: the App Store packages are missing or stale; run scripts/cmux-next/build-web-bundles.sh" >&2
    exit 1
  fi
  if verified; then
    echo "web bundles are current"
    exit 0
  fi
  echo "error: the cmux-next web bundles are missing or stale; run scripts/cmux-next/build-web-bundles.sh" >&2
  exit 1
fi

# In-tree runs only: an --out-root build hands over web bundles, and --from writes the packages here.
if [ -z "$OUT_ROOT" ] && [ -n "$STORE_SYNC" ]; then
  "$STORE_SYNC" --store
fi

# A tree built elsewhere for this source key (cmux-next.yml's Linux web-bundles job caches
# `--out-root` builds by `web-bundle-key.py --source`): check it is complete, install it
# and stamp it, so the build below and every later build path skip. The caller restores
# it under that key, so the stamp's source key is the key it was built from.
if [ "$MODE" = from ]; then
  # The inspector page stays committed (optchat-chief compiles it in with
  # include_str!, and the brain build runs no bundle step): never removed here.
  for path in "$PANE" "$PAGES" "$ACTIVITY" "$APP" "$INSPECTOR/index.html"; do
    [ -e "$FROM_ROOT/$path" ] || { echo "error: $FROM_ROOT has no $path; build the web bundles instead" >&2; exit 1; }
  done
  # The check an in-tree build runs (build-optchat-inspector-web.sh --check): the page the
  # prebuilt tree generated for this source key must be the committed one.
  # A pull request build that left optional pages out (scripts/ci/oops/isolate.py) is installed only where
  # such a build may run; a strict build (nightly, release, a push, a local build) builds every page itself.
  if [ -s "$FROM_ROOT/$PAGES/__oops-dropped" ] && ! python3 "$ROOT/scripts/ci/oops/isolate.py" allowed | grep -q '^allowed'; then
    echo "error: $FROM_ROOT left out optional pages ($(tr '\n' ' ' < "$FROM_ROOT/$PAGES/__oops-dropped")); this build compiles every page: build the web bundles instead" >&2
    exit 1
  fi
  if ! cmp -s "$FROM_ROOT/$INSPECTOR/index.html" "$ROOT/$INSPECTOR/index.html"; then
    echo "error: generated file is stale; run scripts/cmux-next/build-optchat-inspector-web.sh and commit: $INSPECTOR/index.html" >&2
    exit 1
  fi
  rm -f "$STAMP"
  # An --out-root tree holds only what the builders wrote. The files a commit keeps in these
  # directories (their GENERATED.md notes, which the app bundles) stay as the checkout has
  # them, as an in-tree build leaves them: only untracked and ignored files are cleared, so a
  # copy that fails part way never loses a tracked file (the fallback build rewrites the rest).
  for path in "$PANE" "$PAGES" "$ACTIVITY" "$APP"; do
    mkdir -p "${ROOT:?}/$path"
    git -C "$ROOT" clean -fdqx -- "$path"
    cp -R "$FROM_ROOT/$path/." "$ROOT/$path/"
  done
  python3 "$KEY" "$ROOT" --stamp > "$STAMP.tmp"
  mv "$STAMP.tmp" "$STAMP"
  echo "web bundles restored ($(cut -c1-12 "$STAMP"))"
  exit 0
fi

need_bun
cd "$ROOT/webviews"
# The lockfile may have changed since node_modules was installed (a merge, a
# branch switch); a bundle built with other dependencies differs.
bun install --frozen-lockfile >/dev/null
# The strings tables are inputs of the pane and page bundles. They are build
# output, ignored by git (#21946), made here from the commit's xcstrings
# catalogs and settings schema, which the source key hashes; so a build still
# ships only what a commit holds (cx-t3e5). A missing translation fails, unless
# CMUX_STRINGS_BEST_EFFORT=1 (the autofix export jobs, whose bundles never ship).
bun scripts/pages/gen-strings.mjs
cd "$ROOT"

if [ -z "$OUT_ROOT" ] && [ -z "$REPORT_DIR" ] && [ "$MODE" = build ] && current; then
  echo "web bundles are current ($(cut -c1-12 "$STAMP"))"
  exit 0
fi

# The memory inspector page is committed too (optchat-chief compiles it in with
# include_str!). An in-tree build checks it and never rewrites it; an
# --out-root build writes its own copy under the output root.
if [ -z "$OUT_ROOT" ] && ! "$ROOT/scripts/cmux-next/build-optchat-inspector-web.sh" --check; then
  echo "error: generated file is stale; run scripts/cmux-next/build-optchat-inspector-web.sh and commit: $INSPECTOR/index.html" >&2
  exit 1
fi

out() {
  if [ -n "$OUT_ROOT" ]; then printf '%s/%s' "$OUT_ROOT" "$1"; else printf '%s/%s' "$ROOT" "$1"; fi
}

rm -f "$STAMP"
# A report run hands every builder its metafile folder through the environment (bundle-metafile.mjs).
if [ -n "$REPORT_DIR" ]; then
  mkdir -p "$REPORT_DIR"
  export CMUX_BUNDLE_REPORT_DIR="$REPORT_DIR" CMUX_PAGES_METAFILE="$REPORT_DIR/pages.json"
fi
"$ROOT/scripts/cmux-next/build-agent-pane-web.sh" --out "$(out "$PANE")"
# The Pages build also bundles the artifact iframe runtime; a report run records that graph too.
# It goes to this builder alone: the webviews app names its own sidecar, so no two share a file.
if [ -n "$REPORT_DIR" ]; then
  CMUX_ARTIFACT_RUNTIME_METAFILE="$REPORT_DIR/pages-artifact-runtime.json" \
    "$ROOT/scripts/cmux-next/build-pages-web.sh" --out "$(out "$PAGES")"
else
  "$ROOT/scripts/cmux-next/build-pages-web.sh" --out "$(out "$PAGES")"
fi
"$ROOT/scripts/cmux-next/build-agent-activity-web.sh" --out "$(out "$ACTIVITY")"
"$ROOT/scripts/build-webviews-app.sh" --skip-checks --out "$(out "$APP")"
# In-tree, the committed page was checked above.
if [ -n "$OUT_ROOT" ]; then
  "$ROOT/scripts/cmux-next/build-optchat-inspector-web.sh" --out "$(out "$INSPECTOR")"
fi

if [ -z "$OUT_ROOT" ] && [ -s "$ROOT/$PAGES/__oops-dropped" ]; then
  echo "web bundles built without the optional pages $(tr '\n' ' ' < "$ROOT/$PAGES/__oops-dropped")(ci-oops; not stamped, so the next build rebuilds them)"
elif [ -z "$OUT_ROOT" ]; then
  python3 "$KEY" "$ROOT" --stamp > "$STAMP.tmp"
  mv "$STAMP.tmp" "$STAMP"
  echo "web bundles built ($(cut -c1-12 "$STAMP"))"
fi
