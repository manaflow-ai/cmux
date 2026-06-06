#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
OUT_REACT="$ROOT/Resources/agent-session-react"
OUT_SOLID="$ROOT/Resources/agent-session-solid"
MARKED_JS="$ROOT/Resources/markdown-viewer/marked.min.js"

if ! command -v bun >/dev/null 2>&1; then
  echo "error: bun is required to build AgentSessionWeb" >&2
  exit 1
fi

if ! command -v bunx >/dev/null 2>&1; then
  echo "error: bunx is required to build AgentSessionWeb" >&2
  exit 1
fi

if [ ! -f "$MARKED_JS" ]; then
  echo "error: missing markdown parser asset at $MARKED_JS" >&2
  exit 1
fi

rm -rf "$OUT_REACT" "$OUT_SOLID"
mkdir -p "$OUT_REACT/assets" "$OUT_SOLID/assets"

bunx esbuild "$ROOT/webviews/src/agent-session/react/standalone.ts" \
  --bundle \
  --format=esm \
  --platform=browser \
  --target=es2022 \
  '--define:process.env.NODE_ENV="production"' \
  --minify \
  --outfile="$OUT_REACT/assets/app.js"

bunx esbuild "$ROOT/webviews/src/agent-session/solid/main.ts" \
  --bundle \
  --format=esm \
  --platform=browser \
  --target=es2022 \
  '--define:process.env.NODE_ENV="production"' \
  --minify \
  --outfile="$OUT_SOLID/assets/app.js"

bunx tailwindcss \
  -i "$ROOT/webviews/src/agent-session/shared/styles.css" \
  -o "$OUT_REACT/assets/styles.css" \
  --minify
cp "$OUT_REACT/assets/styles.css" "$OUT_SOLID/assets/styles.css"

strip_trailing_line_whitespace() {
  /usr/bin/perl -0pi -e 's/[ \t]+(?=\r?\n)//g; s/[ \t]+\z//' "$@"
}

strip_trailing_line_whitespace \
  "$OUT_REACT/assets/app.js" \
  "$OUT_SOLID/assets/app.js" \
  "$OUT_REACT/assets/styles.css" \
  "$OUT_SOLID/assets/styles.css"

write_index() {
  out_dir="$1"
  {
    printf '<!doctype html>\n'
    printf '<html lang="en" data-codex-window-type="electron" data-window-type="electron" data-codex-os="darwin">\n'
    printf '  <head>\n'
    printf '    <meta charset="UTF-8" />\n'
    printf '    <meta\n'
    printf '      name="viewport"\n'
    printf '      content="width=device-width, initial-scale=1.0"\n'
    printf '    />\n'
    printf '    <title>cmux Agent Session</title>\n'
    printf '    <style>\n'
    cat "$out_dir/assets/styles.css"
    printf '\n    </style>\n'
    printf '  </head>\n'
    printf '  <body data-codex-window-type="electron">\n'
    printf '    <main id="root"></main>\n'
    printf '    <script>\n'
    /usr/bin/perl -0pe 's{</script}{<\\/script}ig; s{<!--}{<\\!--}g' "$MARKED_JS"
    printf '\n    </script>\n'
    printf '    <script>\n'
    /usr/bin/perl -0pe 's{</script}{<\\/script}ig; s{<!--}{<\\!--}g' "$out_dir/assets/app.js"
    printf '\n    </script>\n'
    printf '  </body>\n'
    printf '</html>\n'
  } > "$out_dir/index.html"
}

write_index "$OUT_REACT"
write_index "$OUT_SOLID"

strip_trailing_line_whitespace "$OUT_REACT/index.html" "$OUT_SOLID/index.html"
