#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_DIR="$ROOT/webviews"
OUT_DIR="$ROOT/Resources/markdown-viewer/webviews-app"
MARKED_JS="$ROOT/Resources/markdown-viewer/marked.min.js"

write_agent_session_html() {
  out_dir="$1"
  if [ ! -f "$MARKED_JS" ]; then
    echo "error: missing markdown parser asset at $MARKED_JS" >&2
    exit 1
  fi
  {
    printf '<!doctype html>\n'
    printf '<html lang="en" data-cmux-webview-kind="agent-session" data-codex-window-type="electron" data-window-type="electron" data-codex-os="darwin">\n'
    printf '  <head>\n'
    printf '    <meta charset="UTF-8" />\n'
    printf '    <meta name="viewport" content="width=device-width, initial-scale=1.0" />\n'
    printf '    <title>cmux Agent Session</title>\n'
    printf '  </head>\n'
    printf '  <body data-cmux-webview-kind="agent-session" data-codex-window-type="electron">\n'
    printf '    <main id="root"></main>\n'
    printf '    <script>\n'
    /usr/bin/perl -0pe 's{</script}{<\\/script}ig; s{<!--}{<\\!--}g' "$MARKED_JS"
    printf '\n    </script>\n'
    printf '    <script type="module" src="./main.mjs"></script>\n'
    printf '  </body>\n'
    printf '</html>\n'
  } > "$out_dir/agent-session.html"
}

strip_trailing_line_whitespace() {
  /usr/bin/perl -0pi -e 's/[ \t]+(?=\r?\n)//g; s/[ \t]+\z//' "$@"
}

normalize_webviews_output() {
  out_dir="$1"
  strip_trailing_line_whitespace "$out_dir/main.mjs" "$out_dir/agent-session.html"
}

# Deflate large chunks so the committed git tree + .app bundle stay small; the
# CLI inflates them on copy into the diff viewer's serving dir. Only the big
# vendor chunks (diff-vendor, monaco-vendor) exceed the threshold, and they are
# served exclusively through the HTTP server / custom scheme, never the
# agent-session file:// load, so inflating on copy needs no serving changes.
# Raw DEFLATE (node deflateRawSync) matches Swift `NSData.decompressed(.zlib)`.
compress_webviews_output() {
  out_dir="$1"
  if [ ! -d "$out_dir/chunks" ]; then
    return
  fi
  find "$out_dir/chunks" -type f -name '*.mjs' -size +1000k 2>/dev/null | while IFS= read -r f; do
    node -e 'const z=require("zlib"),fs=require("fs");const p=process.argv[1];fs.writeFileSync(p+".deflate",z.deflateRawSync(fs.readFileSync(p),{level:9}));fs.unlinkSync(p)' "$f"
  done
  # Vite emits Monaco's codicon icon font because monaco-vendor.css references
  # it, but the editor surface inlines that CSS under a page CSP with no
  # font-src, so the font can never load (editorSurface.tsx documents the
  # trade-off). Drop the dead 122KB instead of shipping it.
  rm -f "$out_dir/assets/codicon.ttf"
}

# Materialize a directory for comparison: inflate every `*.deflate` back to its
# logical name so `--check` compares decompressed CONTENT, immune to deflate
# byte-variance across environments/zlib versions. Non-deflate files are copied
# verbatim (still byte-compared).
materialize_for_compare() {
  src="$1"
  dst="$2"
  (cd "$src" && find . -type f -print0) | while IFS= read -r -d '' f; do
    mkdir -p "$dst/$(dirname "$f")"
    case "$f" in
      *.deflate)
        node -e 'const z=require("zlib"),fs=require("fs");process.stdout.write(z.inflateRawSync(fs.readFileSync(process.argv[1])))' "$src/$f" > "$dst/${f%.deflate}"
        ;;
      *)
        cp "$src/$f" "$dst/$f"
        ;;
    esac
  done
}

if [ "${1:-}" = "--check" ]; then
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' EXIT
  (
    cd "$SRC_DIR"
    bun install --frozen-lockfile
    CMUX_WEBVIEWS_OUT_DIR="$tmp_dir" bun run build
    write_agent_session_html "$tmp_dir"
    normalize_webviews_output "$tmp_dir"
    compress_webviews_output "$tmp_dir"
  )
  committed_view="$(mktemp -d)"
  fresh_view="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir" "$committed_view" "$fresh_view"' EXIT
  materialize_for_compare "$OUT_DIR" "$committed_view"
  materialize_for_compare "$tmp_dir" "$fresh_view"
  diff_output="$(mktemp)"
  set +e
  diff -qr "$committed_view" "$fresh_view" >"$diff_output"
  diff_status=$?
  set -e
  if [ "$diff_status" -ne 0 ]; then
    cat "$diff_output" >&2
    rm -f "$diff_output"
    if [ "$diff_status" -eq 1 ]; then
      echo "webviews app assets are stale; run ./scripts/build-webviews-app.sh" >&2
      exit 1
    fi
    echo "failed to compare webviews assets (diff exit $diff_status)" >&2
    exit 2
  fi
  rm -f "$diff_output"
  exit 0
fi

(
  cd "$SRC_DIR"
  bun install --frozen-lockfile
  bun run build
)
write_agent_session_html "$OUT_DIR"
normalize_webviews_output "$OUT_DIR"
compress_webviews_output "$OUT_DIR"
