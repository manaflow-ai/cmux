#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
OUT_REACT="$ROOT/Resources/agent-session-react"
OUT_SOLID="$ROOT/Resources/agent-session-solid"

if ! command -v bun >/dev/null 2>&1; then
  echo "error: bun is required to build AgentSessionWeb" >&2
  exit 1
fi

rm -rf "$OUT_REACT" "$OUT_SOLID"
mkdir -p "$OUT_REACT/assets" "$OUT_SOLID/assets"

bun build "$ROOT/AgentSessionWeb/src/react/main.ts" \
  --target browser \
  --format esm \
  --production \
  --minify \
  --outfile "$OUT_REACT/assets/app.js"

bun build "$ROOT/AgentSessionWeb/src/solid/main.ts" \
  --target browser \
  --format esm \
  --production \
  --minify \
  --outfile "$OUT_SOLID/assets/app.js"

if ! command -v bunx >/dev/null 2>&1; then
  echo "error: bunx is required to build AgentSessionWeb styles" >&2
  exit 1
fi

bunx tailwindcss \
  -i "$ROOT/AgentSessionWeb/src/shared/styles.css" \
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
    printf '<html lang="en">\n'
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
    printf '  <body>\n'
    printf '    <main id="root"></main>\n'
    printf '    <script src="../markdown-viewer/marked.min.js"></script>\n'
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
