#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
info="$RUNNER_TEMP/cmux-native-ssh-fixture.json"
python3 - "$info" <<'PY'
from pathlib import Path
import sys
Path(sys.argv[1]).unlink(missing_ok=True)
PY
fixture_pid=""
cleanup() { [[ -z "$fixture_pid" ]] || kill "$fixture_pid" >/dev/null 2>&1 || true; }
trap cleanup EXIT
uv run "$root/tests/ssh_native/fixture.py" --server-only --server-info "$info" > "$RUNNER_TEMP/cmux-native-ssh-fixture.log" 2>&1 &
fixture_pid=$!
for _ in $(seq 1 100); do
  python3 - "$info" <<'PY' >/dev/null 2>&1 && break
import json,sys
with open(sys.argv[1]) as file: json.load(file)
PY
  sleep 0.1
done
python3 - "$info" <<'PY' >/dev/null
import json,sys
with open(sys.argv[1]) as file: json.load(file)
PY
IFS=$'\t' read -r port password fingerprint ed25519_key < <(python3 - "$info" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
print("\t".join(str(d[key]) for key in ("port","password","hostFingerprint","ed25519PrivateKey")))
PY
)
export CMUX_NATIVE_SSH_PORT="$port"
export CMUX_NATIVE_SSH_PASSWORD="$password"
export CMUX_NATIVE_SSH_FINGERPRINT="$fingerprint"
export CMUX_NATIVE_SSH_ED25519_KEY="$ed25519_key"
swift test --package-path "$root/Packages/Shared/CmuxSSHNative" \
  --scratch-path "$RUNNER_TEMP/cmux-native-ssh-swift" \
  --filter LiveNativeSSHTests \
  --jobs 4
