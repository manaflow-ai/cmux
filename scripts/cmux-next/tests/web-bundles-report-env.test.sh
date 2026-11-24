#!/usr/bin/env bash
# A report run (`build-web-bundles.sh --report-dir D`) hands each builder the
# metafile paths it writes. The Pages builder also bundles the artifact iframe
# runtime, so it needs CMUX_ARTIFACT_RUNTIME_METAFILE too. Without it, the
# report has no Pages artifact-runtime sidecar (#42415's follow-up).
# The test runs build-web-bundles.sh from a scratch root where every builder,
# bun and node are stubs that record their environment. It needs no
# toolchain and finishes in well under a second.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
fail() { printf 'FAIL: %s\n' "$@" >&2; exit 1; }

fake="$TMP/root"
mkdir -p "$fake/scripts/cmux-next" "$fake/webviews/scripts/pages" "$TMP/bin"
cp "$ROOT/scripts/cmux-next/build-web-bundles.sh" "$fake/scripts/cmux-next/"
printf '{}\n' > "$fake/webviews/package.json"
printf '#!/bin/sh\nexit 0\n' > "$fake/scripts/check-webviews-bun-version.sh"
printf 'print("1.0.0")\n' > "$fake/scripts/webviews_bun_version.py"
printf 'print("key")\n' > "$fake/scripts/cmux-next/web-bundle-key.py"
for tool in bun node; do printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/$tool"; done

# Each stub builder records the metafile variables it was given.
record() {
  cat > "$1" <<EOF
#!/bin/sh
{
  echo "pages=\${CMUX_PAGES_METAFILE:-}"
  echo "artifact=\${CMUX_ARTIFACT_RUNTIME_METAFILE:-}"
} > "$TMP/$2.env"
EOF
}
record "$fake/scripts/cmux-next/build-agent-pane-web.sh" pane
record "$fake/scripts/cmux-next/build-pages-web.sh" pages
record "$fake/scripts/cmux-next/build-agent-activity-web.sh" activity
record "$fake/scripts/build-webviews-app.sh" app
record "$fake/scripts/cmux-next/build-optchat-inspector-web.sh" inspector
chmod +x "$fake"/scripts/*.sh "$fake"/scripts/cmux-next/*.sh "$TMP"/bin/*

report="$TMP/report"
PATH="$TMP/bin:$PATH" CMUX_ARTIFACT_RUNTIME_METAFILE='' \
  "$fake/scripts/cmux-next/build-web-bundles.sh" --out-root "$TMP/out" --report-dir "$report" \
  >"$TMP/log" 2>&1 || fail "build-web-bundles.sh failed" "$(cat "$TMP/log")"

grep -qx "pages=$report/pages.json" "$TMP/pages.env" \
  || fail "the Pages builder got no CMUX_PAGES_METAFILE" "$(cat "$TMP/pages.env")"
grep -qx "artifact=$report/pages-artifact-runtime.json" "$TMP/pages.env" \
  || fail "the Pages builder got no CMUX_ARTIFACT_RUNTIME_METAFILE for its artifact runtime" "$(cat "$TMP/pages.env")"
# Only the Pages builder takes it from here: the webviews app names its own sidecar,
# and a shared path would let one builder overwrite another's record.
for other in pane activity app; do
  grep -qx "artifact=" "$TMP/$other.env" \
    || fail "$other was handed the Pages artifact-runtime path" "$(cat "$TMP/$other.env")"
done

# A build without a report directory hands out no metafile paths.
rm -f "$TMP"/*.env
PATH="$TMP/bin:$PATH" CMUX_ARTIFACT_RUNTIME_METAFILE='' CMUX_BUNDLE_REPORT_DIR='' \
  "$fake/scripts/cmux-next/build-web-bundles.sh" --out-root "$TMP/out2" \
  >"$TMP/log" 2>&1 || fail "plain build failed" "$(cat "$TMP/log")"
grep -qx "artifact=" "$TMP/pages.env" || fail "a plain build set an artifact metafile" "$(cat "$TMP/pages.env")"
grep -qx "pages=" "$TMP/pages.env" || fail "a plain build set a Pages metafile" "$(cat "$TMP/pages.env")"
echo "ok: report runs hand the Pages builder its artifact-runtime metafile"
