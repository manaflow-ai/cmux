#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_DIR="${ROOT}/webviews/code-sidecar"
BRIDGE_SOURCE="${ROOT}/webviews/src/surfaces/codeBridge.ts"
PACKAGE_DIST="${SOURCE_DIR}/node_modules/t3/dist"
BINARY_NAME="cmux-code-sidecar"
BUILD_OUTPUT_DIR="${TARGET_BUILD_DIR:-${ROOT}/.build/code-sidecar}"
BUILD_WORK_DIR="${TARGET_TEMP_DIR:-${ROOT}/.build/code-sidecar-work}"

export PATH="${HOME}/.bun/bin:/opt/homebrew/bin:/usr/local/bin:${PATH}"

BUN_VERSION="1.3.14"
BUN_BIN="$(command -v bun 2>/dev/null || true)"
if [[ -z "$BUN_BIN" || "$("$BUN_BIN" --version 2>/dev/null || true)" != "$BUN_VERSION" ]]; then
  case "$(uname -m)" in
    arm64|aarch64)
      bun_archive="bun-darwin-aarch64.zip"
      bun_sha256="d8b96221828ad6f97ac7ac0ab7e95872341af763001e8803e8267652c2652620"
      ;;
    x86_64)
      bun_archive="bun-darwin-x64.zip"
      bun_sha256="4183df3374623e5bab315c547cfa0974533cd457d86b73b639f7a87974cd6633"
      ;;
    *)
      echo "error: unsupported Bun host architecture $(uname -m)" >&2
      exit 1
      ;;
  esac
  bun_tool_dir="${CMUX_CODE_BUN_CACHE_DIR:-${ROOT}/.build/tools/bun-${BUN_VERSION}-$(uname -m)}"
  BUN_BIN="${bun_tool_dir}/bun"
  if [[ ! -x "$BUN_BIN" ]]; then
    mkdir -p "$bun_tool_dir"
    bun_download="${bun_tool_dir}/${bun_archive}.download"
    bun_unpack="${bun_tool_dir}/unpack"
    /usr/bin/curl --fail --location --retry 3 \
      "https://github.com/oven-sh/bun/releases/download/bun-v${BUN_VERSION}/${bun_archive}" \
      --output "$bun_download"
    printf '%s  %s\n' "$bun_sha256" "$bun_download" | /usr/bin/shasum -a 256 --check
    rm -rf "$bun_unpack"
    mkdir -p "$bun_unpack"
    /usr/bin/ditto -x -k "$bun_download" "$bun_unpack"
    bun_extracted="$(find "$bun_unpack" -type f -name bun -perm +111 -print -quit)"
    [[ -n "$bun_extracted" ]] || { echo "error: Bun archive did not contain an executable" >&2; exit 1; }
    cp "$bun_extracted" "$BUN_BIN"
    chmod +x "$BUN_BIN"
    rm -f "$bun_download"
    rm -rf "$bun_unpack"
  fi
fi
[[ "$("$BUN_BIN" --version)" == "$BUN_VERSION" ]] || { echo "error: expected Bun ${BUN_VERSION}" >&2; exit 1; }

(
  cd "$SOURCE_DIR"
  "$BUN_BIN" install --frozen-lockfile
)

[[ -f "${PACKAGE_DIST}/bin.mjs" ]] || { echo "error: missing pinned Code server package" >&2; exit 1; }
[[ -f "${PACKAGE_DIST}/client/index.html" ]] || { echo "error: missing Code client assets" >&2; exit 1; }

requested_archs="${CMUX_CODE_SIDECAR_ARCHS:-${ARCHS:-}}"
if [[ -z "$requested_archs" ]]; then
  case "$(uname -m)" in
    arm64|aarch64) requested_archs="arm64" ;;
    x86_64) requested_archs="x86_64" ;;
    *)
      echo "error: unsupported Code sidecar architecture $(uname -m)" >&2
      exit 1
      ;;
  esac
fi

rm -rf "${BUILD_WORK_DIR}/source"
mkdir -p "${BUILD_WORK_DIR}/source" "$BUILD_OUTPUT_DIR"
cp "${PACKAGE_DIST}/bin.mjs" "${PACKAGE_DIST}/BunPtyAdapter-"*.mjs "${PACKAGE_DIST}/PtyAdapter-"*.mjs "${BUILD_WORK_DIR}/source/"
ln -sfn "${SOURCE_DIR}/node_modules" "${BUILD_WORK_DIR}/node_modules"

patched_entry="${BUILD_WORK_DIR}/source/bin.mjs"
/usr/bin/perl -0pi -e 's{node: \(\) => import\("\./NodeSqliteClient-[^"\n]+\.mjs"\)}{node: () => import("\@effect/sql-sqlite-bun/SqliteClient")}g' "$patched_entry"
/usr/bin/perl -0pi -e 's{else return \(yield\* Effect\.promise\(\(\) => import\("\./NodePtyAdapter-[^"\n]+\.mjs"\)\)\)\.layer;}{else return (yield* Effect.promise(() => import("./BunPtyAdapter-BIcMskhs.mjs"))).layer;}g' "$patched_entry"
/usr/bin/perl -0pi -e 's{const bundledClient = resolve\(join\(import\.meta\.dirname, "client"\)\);}{const bundledClient = resolve(process.env.CMUX_CODE_STATIC_DIR ?? join(import.meta.dirname, "client"));}g' "$patched_entry"
/usr/bin/perl -0pi -e 's/T3 Code/Code/g; s/T3 Connect/Connect/g; s/\bT3\b/Code/g; s/T3CODE/CMUX_CODE/g; s/Command\.make\("t3",/Command.make("code",/g' "$patched_entry"

if grep -Eq 'NodeSqliteClient-|NodePtyAdapter-' "$patched_entry"; then
  echo "error: the pinned server layout changed; update the Code sidecar compile patch" >&2
  exit 1
fi
if ! grep -q 'CMUX_CODE_STATIC_DIR' "$patched_entry"; then
  echo "error: the Code static directory patch was not applied" >&2
  exit 1
fi
if grep -Eq 'T3 Code|T3 Connect|(^|[^[:alnum:]_])T3([^[:alnum:]_]|$)|T3CODE' "$patched_entry"; then
  echo "error: user-visible upstream branding remains in the Code server" >&2
  exit 1
fi

binaries=()
seen_archs=""
for arch in $requested_archs; do
  case "$arch" in
    arm64|arm64e) target="bun-darwin-arm64"; canonical_arch="arm64" ;;
    x86_64) target="bun-darwin-x64"; canonical_arch="x86_64" ;;
    *)
      echo "error: unsupported Code sidecar architecture $arch" >&2
      exit 1
      ;;
  esac
  case " $seen_archs " in
    *" $canonical_arch "*) continue ;;
  esac
  seen_archs="$seen_archs $canonical_arch"
  binary="${BUILD_WORK_DIR}/${BINARY_NAME}-${canonical_arch}"
  "$BUN_BIN" build "$patched_entry" --compile --target="$target" --outfile="$binary"
  binaries+=("$binary")
done

output_binary="${BUILD_OUTPUT_DIR}/${BINARY_NAME}"
if [[ "${#binaries[@]}" -eq 1 ]]; then
  rsync -a "${binaries[0]}" "$output_binary"
else
  lipo -create -output "$output_binary" "${binaries[@]}"
fi
chmod +x "$output_binary"

if [[ -z "${TARGET_BUILD_DIR:-}" ]]; then
  echo "built ${output_binary}"
  exit 0
fi

resources_dir="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}"
binary_dir="${resources_dir}/bin"
client_dir="${resources_dir}/code-sidecar/client"
monitor_dir="${resources_dir}/code-sidecar/resource-monitor"
mkdir -p "$binary_dir" "$client_dir" "$monitor_dir"
rsync -a "$output_binary" "${binary_dir}/${BINARY_NAME}"
rsync -a --delete --exclude '*.map' "${PACKAGE_DIST}/client/" "$client_dir/"
# The desktop client only uses the native bridge for its local environment.
# Remove the hosted-login and telemetry configuration inherited from the
# pinned web bundle so the renderer has no embedded credential or relay path.
find "$client_dir" -type f -name '*.js' -print0 \
  | xargs -0 /usr/bin/perl -0777pi -e 'for my $key (qw(VITE_CLERK_CLI_OAUTH_CLIENT_ID VITE_CLERK_JWT_TEMPLATE VITE_CLERK_PUBLISHABLE_KEY VITE_RELAY_OTLP_TRACES_DATASET VITE_RELAY_OTLP_TRACES_TOKEN VITE_RELAY_OTLP_TRACES_URL VITE_T3CODE_RELAY_URL)) { if (/\Q$key\E:`([^`]*)`/) { my $value = $1; s{`\Q$value\E`}{``}g if length $value; } }'
if ! find "$client_dir" -type f -name '*.js' -print0 \
    | xargs -0 grep -Fq 'VITE_RELAY_OTLP_TRACES_TOKEN:``'; then
  echo "error: failed to remove hosted Code configuration from the client" >&2
  exit 1
fi
if find "$client_dir" -type f -name '*.js' -print0 \
    | xargs -0 grep -Eil 'xaat-|pk_live_[[:alnum:]]{8,}|api\.axiom\.co|relay\.t3\.codes|relay-traces' >/dev/null; then
  echo "error: a hosted credential or relay endpoint remains in the Code client" >&2
  exit 1
fi
cp "${ROOT}/web/app/apple-icon.png" "${client_dir}/apple-touch-icon.png"
rm -rf "${monitor_dir}/darwin-arm64" "${monitor_dir}/darwin-x64"
rsync -a "${PACKAGE_DIST}/resource-monitor/darwin-arm64" "$monitor_dir/"
rsync -a "${PACKAGE_DIST}/resource-monitor/darwin-x64" "$monitor_dir/"
for monitor in "$monitor_dir"/darwin-*/t3-resource-monitor; do
  [ -f "$monitor" ] || continue
  mv "$monitor" "$(dirname "$monitor")/cmux-code-resource-monitor"
done
cp "${SOURCE_DIR}/cmux-code.css" "${client_dir}/cmux-code.css"
"$BUN_BIN" build "$BRIDGE_SOURCE" \
  --outfile "${client_dir}/cmux-code-bridge.js" \
  --target browser \
  --format iife \
  --minify

/usr/bin/perl -0pi -e 's{href="/favicon\.ico"}{href="/apple-touch-icon.png"}; s{<title>(?:T3 )?Code \(Alpha\)</title>}{<title>Code</title>}; s{<script type="module" crossorigin src="([^"]+)"></script>}{<script src="/cmux-code-bridge.js"></script>\n    <script type="application/x-cmux-code-module" data-cmux-code-main="$1"></script>}; s{<link rel="modulepreload" crossorigin href="([^"]+)">}{<link data-cmux-code-modulepreload href="$1">}g; s{<link rel="stylesheet" crossorigin href="([^"]+)">}{<link data-cmux-code-stylesheet href="$1">}g; s{</head>}{  <link rel="stylesheet" href="/cmux-code.css" />\n</head>}' "${client_dir}/index.html"
/usr/bin/perl -0pi -e 's{<body>.*?</body>}{<body>\n    <main id="boot-shell" class="code-instant">\n      <header class="code-instant__topbar">\n        <button class="code-instant__new-thread" type="button">\n          <span data-cmux-string="newThread">New thread</span>\n        </button>\n      </header>\n      <section class="code-instant__stage">\n        <div class="code-instant__empty-state">\n          <p data-cmux-string="emptyState">Send a message to start the conversation.</p>\n        </div>\n      </section>\n      <form class="code-instant__composer">\n        <textarea id="cmux-code-instant-draft" rows="2" autofocus data-cmux-placeholder="prompt" placeholder="Describe a task or ask a question"></textarea>\n        <div class="code-instant__composer-footer">\n          <button class="code-instant__control" type="button" data-cmux-string="fullAccess">Full access</button>\n          <button class="code-instant__control" type="button" data-cmux-string="build">Build</button>\n          <button class="code-instant__send" type="submit" aria-label="Send" data-cmux-aria-label="send">↑</button>\n        </div>\n      </form>\n    </main>\n    <div id="root"></div>\n  </body>}s' "${client_dir}/index.html"
if ! grep -Fq '<script src="/cmux-code-bridge.js"></script>' "${client_dir}/index.html"; then
  echo "error: failed to install the Code WebView bridge" >&2
  exit 1
fi
if ! grep -Fq 'class="code-instant__composer"' "${client_dir}/index.html" \
    || ! grep -Fq '<div id="root"></div>' "${client_dir}/index.html" \
    || ! grep -Fq 'type="application/x-cmux-code-module"' "${client_dir}/index.html" \
    || grep -Fq '<script type="module"' "${client_dir}/index.html" \
    || grep -Fq '<img id="boot-shell-logo"' "${client_dir}/index.html"; then
  echo "error: failed to install the static Code app shell" >&2
  exit 1
fi
sidebar_default_open='className:`h-dvh! min-h-0!`,defaultOpen:!0,style:'
sidebar_default_closed='className:`h-dvh! min-h-0!`,defaultOpen:!1,style:'
sidebar_asset=""
sidebar_asset_count=0
for candidate in "$client_dir"/assets/index-*.js; do
  [[ -f "$candidate" ]] || continue
  if grep -Fq "$sidebar_default_open" "$candidate"; then
    sidebar_asset="$candidate"
    ((sidebar_asset_count += 1))
  fi
done
if [[ "$sidebar_asset_count" -ne 1 ]]; then
  echo "error: expected one pinned Code client sidebar default, found ${sidebar_asset_count}" >&2
  exit 1
fi
/usr/bin/perl -0pi -e 's{className:`h-dvh! min-h-0!`,defaultOpen:!0,style:}{className:`h-dvh! min-h-0!`,defaultOpen:!1,style:}g' "$sidebar_asset"
if grep -Fq "$sidebar_default_open" "$sidebar_asset" || ! grep -Fq "$sidebar_default_closed" "$sidebar_asset"; then
  echo "error: failed to make the Code client sidebar hidden by default" >&2
  exit 1
fi
find "$client_dir" -type f \( -name '*.html' -o -name '*.js' \) -print0 \
  | xargs -0 /usr/bin/perl -0pi -e 's/T3 Code/Code/g; s/T3 Connect/Connect/g; s/\bT3\b/Code/g; s/T3CODE/CMUX_CODE/g'
if find "$client_dir" -type f \( -name '*.html' -o -name '*.js' \) -print0 \
    | xargs -0 grep -El 'T3 Code|T3 Connect|(^|[^[:alnum:]_])T3([^[:alnum:]_]|$)|T3CODE' >/dev/null; then
  echo "error: user-visible upstream branding remains in the Code client" >&2
  exit 1
fi

chmod +x "${binary_dir}/${BINARY_NAME}" "$monitor_dir"/darwin-*/cmux-code-resource-monitor
if [[ "${CODE_SIGNING_ALLOWED:-YES}" != "NO" && -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]]; then
  codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" "${binary_dir}/${BINARY_NAME}" >/dev/null
  for monitor in "$monitor_dir"/darwin-*/cmux-code-resource-monitor; do
    codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" "$monitor" >/dev/null
  done
fi
