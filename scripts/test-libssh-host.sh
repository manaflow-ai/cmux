#!/bin/bash
# Behavioral loopback checks of the pinned, instrumented host static libraries.
set -euo pipefail
stack="${1:?Pass the sanitizer-enabled macosx build output}"
evidence="${2:?Pass a fresh evidence directory}"
root="$(cd "$(dirname "$0")/.." && pwd)"
[[ ! -e "$evidence" ]] || { echo "Evidence directory already exists" >&2; exit 2; }
python3 - "$stack/build-metadata.json" <<'PY'
import json, sys
metadata = json.load(open(sys.argv[1]))
assert metadata['sdk'] == 'macosx' and metadata['arch'] == 'arm64'
assert metadata['libsshVersion'] == '0.12.2' and metadata['mbedtlsVersion'] == '3.6.7'
assert metadata['fullArchiveLinkVerified']
assert '-fsanitize=address,undefined' in metadata['sanitizers']
PY
mkdir -p "$evidence"
cc -Wall -Wextra -Werror -fsanitize=address,undefined -fno-omit-frame-pointer -g \
  -I "$stack" "$root/tests/ssh_native/harness.c" \
  "$stack/libssh.a" "$stack/libmbedcrypto.a" "$stack/libmbedx509.a" \
  "$stack/libmbedtls.a" "$stack/libeverest.a" "$stack/libp256m.a" \
  -o "$evidence/harness"
cp "$stack/build-metadata.json" "$evidence/build-metadata.json"
ASAN_OPTIONS=halt_on_error=1 UBSAN_OPTIONS=halt_on_error=1 \
  uv run "$root/tests/ssh_native/fixture.py" --harness "$evidence/harness" \
  --output "$evidence/results.json" --libssh-version 0.12.2
git -C "$root" rev-parse HEAD > "$evidence/source-sha.txt"
