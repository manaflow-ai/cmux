#!/bin/sh
# Builds the Chief memory inspector (webviews/src/optchat-inspector). The
# default page is self-contained for binary-only Chief installs; an app build
# sets CMUX_SHARED_REACT_RUNTIME_OUT and gets an external shared-runtime page.
# With no output directory, both generated variants are refreshed:
# index.html (standalone) and index.shared.html (app).
# Usage: build-optchat-inspector-web.sh [--check | --out DIR]
set -eu
ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)"
OUT="$ROOT/Native/OptChat/optchat-chief/inspector/index.html"
MODE=build
REPORT_DIR="${CMUX_BUNDLE_REPORT_DIR:-}"
if [ "$#" -gt 0 ]; then
  case "$1" in
    --check) MODE=check ;;
    --out)
      [ "$#" -ge 2 ] || { echo "error: --out needs a directory" >&2; exit 2; }
      case "$2" in /*) OUT="$2/index.html" ;; *) OUT="$PWD/$2/index.html" ;; esac
      ;;
    *) echo "usage: $0 [--check | --out DIR]" >&2; exit 2 ;;
  esac
fi
command -v bun >/dev/null 2>&1 || { echo "error: bun is required" >&2; exit 1; }
"$ROOT/scripts/check-webviews-bun-version.sh"
WORK="$(mktemp -d)"
BUILD_SCRIPT="$(mktemp "$ROOT/webviews/.cmux-inspector-build.XXXXXX.mjs")"
cleanup() { rm -rf "$WORK" "$BUILD_SCRIPT"; }
trap cleanup EXIT
cd "$ROOT/webviews"
[ -d node_modules ] || bun install --frozen-lockfile >/dev/null
if [ -n "$REPORT_DIR" ]; then mkdir -p "$REPORT_DIR"; fi
cat > "$BUILD_SCRIPT" <<'EOF'
import { build } from "esbuild";
import { writeFile } from "node:fs/promises";
const { sharedReactExternalPlugin } = await import(process.env.CMUX_SHARED_REACT_PLUGIN);

const [outfile, metafile] = process.argv.slice(2);
const result = await build({
  entryPoints: ["src/optchat-inspector/main.tsx"],
  bundle: true,
  format: "esm",
  platform: "browser",
  target: "es2022",
  minify: true,
  legalComments: "none",
  define: { "process.env.NODE_ENV": '"production"' },
  outfile,
  metafile: Boolean(metafile),
  logLevel: "warning",
  plugins: [sharedReactExternalPlugin()],
});
if (metafile) await writeFile(metafile, JSON.stringify(result.metafile));
EOF
export CMUX_SHARED_REACT_PLUGIN="$ROOT/webviews/scripts/shared-react-runtime.mjs"

build_bundle() {
  app_js="$1"
  metafile_path="${2:-}"
  bun "$BUILD_SCRIPT" "$app_js" "$metafile_path"
}

write_page() {
  app_js="$1"
  page="$2"
  CSP="default-src 'none'; script-src 'self' 'unsafe-inline'; style-src 'unsafe-inline'; img-src data:; connect-src 'self'"
  {
    printf '<!doctype html>\n<html lang="en">\n<head>\n<meta charset="utf-8" />\n<meta http-equiv="Content-Security-Policy" content="%s" />\n<meta name="viewport" content="width=device-width, initial-scale=1" />\n<title>Chief Memory Inspector</title>\n<style>\n' "$CSP"
    cat src/optchat-inspector/styles.css
    printf '\n</style>\n</head>\n<body>\n<div id="root"></div>\n<script type="module">\n'
    perl -0pe 's{</script}{<\\/script}ig; s{<!--}{<\\!--}g' "$app_js"
    printf '\n</script>\n</body>\n</html>\n'
  } > "$page"
}

DEFAULT_OUT="$ROOT/Native/OptChat/optchat-chief/inspector/index.html"
OUT_DIR="$(dirname "$OUT")"
SHARED_OUT="$OUT_DIR/index.shared.html"
SHARED_RUNTIME_OUT="${CMUX_SHARED_REACT_RUNTIME_OUT:-}"

# An app caller supplies the already-built app runtime and requests one
# external page at its output path. Never silently emit an external page for a
# binary-only caller: that page has no guaranteed companion at install time.
if [ -n "$SHARED_RUNTIME_OUT" ]; then
  shared_meta=""
  if [ -n "$REPORT_DIR" ]; then shared_meta="$REPORT_DIR/optchat-inspector.json"; fi
  export CMUX_SHARED_REACT_RUNTIME_OUT="$SHARED_RUNTIME_OUT"
  build_bundle "$WORK/app.shared.js" "$shared_meta"
  if [ "$MODE" = check ]; then
    write_page "$WORK/app.shared.js" "$WORK/index.shared.html"
    cmp -s "$WORK/index.shared.html" "$OUT" || { echo "error: the memory inspector shared page is stale; run scripts/cmux-next/build-optchat-inspector-web.sh" >&2; exit 1; }
    echo "memory inspector shared page is current"; exit 0
  fi
  mkdir -p "$OUT_DIR"
  write_page "$WORK/app.shared.js" "$OUT"
  echo "wrote $OUT ($(wc -c < "$OUT" | tr -d ' ') bytes; shared runtime external)"
  exit 0
fi

# The no-env path always builds a self-contained standalone page. The source
# checkout also carries the app variant so Cargo can select it deterministically
# for the cmux-next app without changing the standalone binary's page.
unset CMUX_SHARED_REACT_RUNTIME_OUT
standalone_meta=""
if [ -n "$REPORT_DIR" ]; then standalone_meta="$REPORT_DIR/optchat-inspector-standalone.json"; fi
build_bundle "$WORK/app.standalone.js" "$standalone_meta"
if [ "$MODE" = check ]; then
  write_page "$WORK/app.standalone.js" "$WORK/index.html"
  cmp -s "$WORK/index.html" "$OUT" || { echo "error: the memory inspector standalone page is stale; run scripts/cmux-next/build-optchat-inspector-web.sh" >&2; exit 1; }
  if [ "$OUT" = "$DEFAULT_OUT" ]; then
    export CMUX_SHARED_REACT_RUNTIME_OUT="$WORK/__runtime"
    build_bundle "$WORK/app.shared.js" ""
    write_page "$WORK/app.shared.js" "$WORK/index.shared.html"
    cmp -s "$WORK/index.shared.html" "$SHARED_OUT" || { echo "error: the memory inspector shared page is stale; run scripts/cmux-next/build-optchat-inspector-web.sh" >&2; exit 1; }
  fi
  echo "memory inspector pages are current"; exit 0
fi
mkdir -p "$OUT_DIR"
write_page "$WORK/app.standalone.js" "$OUT"
echo "wrote $OUT ($(wc -c < "$OUT" | tr -d ' ') bytes; standalone)"
if [ "$OUT" = "$DEFAULT_OUT" ]; then
  export CMUX_SHARED_REACT_RUNTIME_OUT="$WORK/__runtime"
  build_bundle "$WORK/app.shared.js" ""
  write_page "$WORK/app.shared.js" "$SHARED_OUT"
  echo "wrote $SHARED_OUT ($(wc -c < "$SHARED_OUT" | tr -d ' ') bytes; shared runtime external)"
fi
