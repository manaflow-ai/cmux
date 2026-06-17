#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT_DIR/scripts/prune_nightly_release_assets.py"
PYTHON_BIN="${PYTHON_BIN:-python3}"

"$PYTHON_BIN" -m py_compile "$SCRIPT"
"$PYTHON_BIN" - "$SCRIPT" <<'PY'
import importlib.util
import pathlib
import sys

script = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("nightly_prune_compat", script)
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
sys.modules[spec.name] = module
spec.loader.exec_module(module)
assert callable(module.load_release)

class FakeResponse:
    def __init__(self, body):
        self.body = body

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, tb):
        return False

    def read(self):
        return self.body

requests = []

def fake_urlopen(request):
    requests.append((request.get_method(), request.full_url))
    if request.get_method() == "DELETE":
        return FakeResponse(b"")
    return FakeResponse(b'{"assets": []}')

module.urllib.request.urlopen = fake_urlopen
module.os.environ["GH_TOKEN"] = "test-token"
module.os.environ["GITHUB_API_URL"] = "https://api.example.test"
module.os.environ["PATH"] = ""

release = module.load_release("manaflow-ai/cmux", "nightly")
assert release == {"assets": []}
module.delete_assets("manaflow-ai/cmux", [module.ReleaseAsset(asset_id=123, name="old.dmg", build=1)])
assert requests == [
    ("GET", "https://api.example.test/repos/manaflow-ai/cmux/releases/tags/nightly"),
    ("DELETE", "https://api.example.test/repos/manaflow-ai/cmux/releases/assets/123"),
]
PY

echo "PASS: nightly prune script is compatible with older macOS runner Python"
