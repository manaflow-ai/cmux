#!/usr/bin/env bash
# Exact duplicate stored files, decoded inline fonts, and normalized gzip/tar
# transfer experiment on one verified web-bundle content key. Does not run an app.
# cmux-ci run --class light --measurement --os linux --script scripts/measure/web-asset-duplicates.sh \
#   --ref FULL_SHA --arg key=CONTENT_KEY --artifact artifacts/web-asset-duplicates.json --timeout 300 --queue-timeout 600
set -euo pipefail
key=""
for arg in "$@"; do
  case "$arg" in
    key=*) key="${arg#key=}" ;;
    *) echo "web-asset-duplicates: unknown argument $arg" >&2; exit 2 ;;
  esac
done
[[ "$key" =~ ^[a-f0-9]{64}$ ]] || { echo 'web-asset-duplicates: key=64_HEX required' >&2; exit 2; }
root="$(cd "$(dirname "$0")/../.." && pwd -P)"
python3 - "$root" "$key" <<'PY'
import pathlib, subprocess, sys, tempfile
root = pathlib.Path(sys.argv[1])
with tempfile.TemporaryDirectory(prefix='web-asset-duplicates-') as temp:
    bundles = pathlib.Path(temp) / 'bundles'
    subprocess.run(['bash', str(root / 'scripts/cmux-next/fetch-web-bundles.sh'),
                    '--key', sys.argv[2], '--out', str(bundles)], check=True, timeout=180)
    subprocess.run([sys.executable, str(root / 'scripts/measure/web-asset-duplicates.py'),
                    str(bundles), '--output', str(root / 'artifacts/web-asset-duplicates.json')],
                   check=True, timeout=90)
PY
