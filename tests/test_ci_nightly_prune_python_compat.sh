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

class FakeProc:
    returncode = 0
    stdout = ""
    stderr = ""

gh_calls = []

def fake_run(args, capture_output=None, text=None):
    gh_calls.append(args)
    return FakeProc()

module.os.environ.pop("GH_TOKEN")
module.os.environ.pop("GITHUB_TOKEN", None)
module.shutil.which = lambda name: "/fake/gh" if name == "gh" else None
module.subprocess.run = fake_run

module.delete_assets("manaflow-ai/cmux", [module.ReleaseAsset(asset_id=456, name="older.dmg", build=1)])
assert gh_calls == [
    ["gh", "api", "-X", "DELETE", "repos/manaflow-ai/cmux/releases/assets/456"],
]
PY

echo "PASS: nightly prune script is compatible with older macOS runner Python"
