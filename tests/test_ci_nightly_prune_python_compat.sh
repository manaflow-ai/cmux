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

assets = [
    module.ReleaseAsset(
        asset_id=build * 10 + index,
        name=f"cmux-nightly-macos-arm64-{build}-{index}.delta",
        build=build,
    )
    for build in range(1, 5)
    for index in range(2)
]
release_assets = [
    {"id": asset.asset_id, "name": asset.name}
    for asset in assets
] + [{"id": 1000, "name": "appcast.xml"}]
immutable_assets, ignored_assets = module.collect_immutable_assets({"assets": release_assets})
assert ignored_assets == 1
to_delete, builds = module.partition_assets(
    immutable_assets, keep_builds=3, total_assets=9, max_assets=8
)
assert builds == [4, 3, 2, 1]
assert {asset.build for asset in to_delete} == {1}
assert len(to_delete) == 2
assert all(asset.asset_id != 1000 for asset in to_delete)

# Every daemon artifact has the same lifetime as its immutable nightly DMG.
daemon_names = [
    "cmuxd-remote-linux-amd64-12345601",
    "cmuxd-remote-linux-arm64-12345601",
    "cmuxd-remote-darwin-amd64-12345601",
    "cmuxd-remote-darwin-arm64-12345601",
    "cmuxd-remote-checksums-12345601.txt",
    "cmuxd-remote-manifest-12345601.json",
]
release_assets = [{"id": i, "name": name} for i, name in enumerate(daemon_names)]
release_assets += [
    {"id": 10, "name": "cmux-nightly-macos-arm64-12345601.dmg"},
    {"id": 11, "name": "cmux-nightly-macos-arm64-12345701.dmg"},
    {"id": 12, "name": "cmuxd-remote-manifest.json"},
]
immutable, ignored = module.collect_immutable_assets({"assets": release_assets})
assert ignored == 1
to_delete, _ = module.partition_assets(immutable, keep_builds=1, total_assets=9, max_assets=950)
assert {asset.name for asset in to_delete} == set(daemon_names) | {"cmux-nightly-macos-arm64-12345601.dmg"}

# RC runs share the daemon naming contract but have independent release storage.
rc_assets = [{**asset, "name": asset["name"].replace("cmux-nightly-macos-", "cmux-rc-macos-")}
             for asset in release_assets]
immutable, ignored = module.collect_immutable_assets(
    {"assets": rc_assets}, module.immutable_asset_patterns("cmux-rc-macos-"))
assert ignored == 1
to_delete, _ = module.partition_assets(immutable, keep_builds=1, total_assets=9, max_assets=950)
assert {asset.name for asset in to_delete} == set(daemon_names) | {"cmux-rc-macos-arm64-12345601.dmg"}
PY

echo "PASS: nightly prune script is compatible with older macOS runner Python"
