#!/usr/bin/env bash
# Fetches the cmux-next web bundles published for a source key (cx-ycne), so a
# host without webviews/ + bun + node (GPUI hosting the React pages in CEF, a
# build without a toolchain) gets the exact bundle feat-cmux-next built.
#
# Published by .github/workflows/cmux-next-web-bundle-publish.yml on every
# feat-cmux-next push that changes a bundle input:
#   https://files.cmux.com/cmux-next-web/<key>/manifest.json
#   https://files.cmux.com/cmux-next-web/<key>/web-bundles-<sha256>.tar.gz
# <key> is `scripts/cmux-next/web-bundle-key.py <root> --source`: a sha256 of
# every bundle input (webviews/ incl. its lockfile and the bun pin, the settings
# schema, the xcstrings catalogs, the build scripts). The manifest
# (schema 1) names: key, commit, run_id, archive, sha256, size, bun, node,
# outputs. The archive holds the repository-relative output paths
# (web-bundle-key.py OUTPUTS), as `build-web-bundles.sh --out-root` writes them.
#
# Usage: scripts/cmux-next/fetch-web-bundles.sh [--key KEY] [--out DIR] [--install] [--print-key]
#   --key KEY    the source key (default: this checkout's)
#   --out DIR    where to unpack (default: .build/web-bundles/<key>)
#   --install    then install into this checkout and stamp it (build-web-bundles.sh --from)
#   --print-key  print this checkout's key and exit
# An existing DIR is replaced only when it holds .manifest.json (written here).
# Exit 0 fetched (prints DIR); 3 not published for this key (HTTP 404) (build it, or wait for
# the publish run); 1 a download or sha256 check failed.
# CMUX_WEB_BUNDLES_BASE overrides https://files.cmux.com/cmux-next-web.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
key="" out="" install=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --key) key="${2:?--key needs a value}"; shift 2 ;;
    --out) out="${2:?--out needs a directory}"; shift 2 ;;
    --install) install=1; shift ;;
    --print-key) python3 "$root/scripts/cmux-next/web-bundle-key.py" "$root" --source; exit 0 ;;
    -h|--help) sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "fetch-web-bundles: unknown argument $1" >&2; exit 2 ;;
  esac
done
[[ -n "$key" ]] || key="$(python3 "$root/scripts/cmux-next/web-bundle-key.py" "$root" --source)"
[[ "$key" =~ ^[0-9a-f]{64}$ ]] || { echo "fetch-web-bundles: bad key $key" >&2; exit 2; }
base="${CMUX_WEB_BUNDLES_BASE:-https://files.cmux.com/cmux-next-web}/$key"
out="${out:-$root/.build/web-bundles/$key}"; out="${out%/}"
[[ -n "$out" ]] || { echo "fetch-web-bundles: bad --out" >&2; exit 2; }
if [[ -e "$out" && ! -f "$out/.manifest.json" ]]; then
  echo "fetch-web-bundles: refusing to replace $out (not a directory this script wrote)" >&2; exit 2
fi
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
code="$(curl -sS -o "$work/manifest.json" -w '%{http_code}' --retry 3 --connect-timeout 20 --max-time 60 "$base/manifest.json" || true)"
if [[ "$code" == 404 ]]; then
  echo "fetch-web-bundles: no bundle published for key $key ($base/manifest.json: HTTP $code)" >&2; exit 3
fi
[[ "$code" == 200 ]] || { echo "fetch-web-bundles: manifest download failed (HTTP ${code:-none})" >&2; exit 1; }
read -r m_key archive sha < <(python3 -c 'import json,sys; m=json.load(open(sys.argv[1])); assert m.get("schema")==1, "schema"; print(m["key"], m["archive"], m["sha256"])' "$work/manifest.json")
[[ "$m_key" == "$key" ]] || { echo "fetch-web-bundles: manifest names key $m_key, not $key" >&2; exit 1; }
[[ "$archive" =~ ^web-bundles-[0-9a-f]{64}\.tar\.gz$ && "$sha" =~ ^[0-9a-f]{64}$ ]] || { echo "fetch-web-bundles: bad manifest entry $archive $sha" >&2; exit 1; }
curl -fsS --retry 3 --connect-timeout 20 --max-time 300 -o "$work/$archive" "$base/$archive" || { echo "fetch-web-bundles: archive download failed" >&2; exit 1; }
actual="$( (command -v sha256sum >/dev/null && sha256sum "$work/$archive" || shasum -a 256 "$work/$archive") | awk '{print $1}')"
[[ "$actual" == "$sha" ]] || { echo "fetch-web-bundles: $archive has sha256 $actual, the manifest says $sha" >&2; exit 1; }
mkdir -p "$(dirname "$out")"
stage="$(mktemp -d "$(dirname "$out")/.web-bundles.XXXXXX")"
python3 "$root/scripts/cmux-next/web-bundle-archive.py" unpack "$work/$archive" "$stage" || { rm -rf "$stage"; exit 1; }
cp "$work/manifest.json" "$stage/.manifest.json"
rm -rf "$out"; mv "$stage" "$out"
if [[ "$install" == 1 ]]; then
  [[ "$(python3 "$root/scripts/cmux-next/web-bundle-key.py" "$root" --source)" == "$key" ]] || {
    echo "fetch-web-bundles: --install needs this checkout's own key (fetched $key)" >&2; exit 2; }
  "$root/scripts/cmux-next/build-web-bundles.sh" --from "$out" >&2
fi
printf '%s\n' "$out"
