from __future__ import annotations

import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/publish-cmux-tui-tree.py"
spec = importlib.util.spec_from_file_location("publish_cmux_tui_tree", SCRIPT)
assert spec and spec.loader
publisher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(publisher)


def _fixture(tmp_path: Path) -> tuple[Path, Path, Path, Path]:
    assets = tmp_path / "assets"
    assets.mkdir()
    binaries: dict[str, str] = {}
    for index, name in enumerate(publisher.COMPANION_NAMES):
        path = assets / name
        path.write_bytes((f"binary-{index}" * 17).encode())
        binaries[name] = hashlib.sha256(path.read_bytes()).hexdigest()
    commit = "a" * 40
    manifest = tmp_path / "manifest.json"
    manifest.write_text(json.dumps({"commit": commit, "binaries": binaries}))
    source = tmp_path / "source.json"
    source.write_text(json.dumps({"key": "b" * 40, "commit": commit, "binaries": {publisher.COMPANION_NAMES[0]: binaries[publisher.COMPANION_NAMES[0]]}}))
    uploader = tmp_path / "uploader.py"
    uploader.write_text("""#!/usr/bin/env python3
import json, pathlib, sys
args = sys.argv[1:]
def value(name): return args[args.index(name) + 1]
pathlib.Path(__file__).with_name("uploads.jsonl").open("a").write(json.dumps({"key": value("--key"), "file": value("--file")}) + "\n")
""")
    uploader.chmod(0o755)
    return assets, manifest, source, uploader


def _run_publish(tmp_path: Path):
    assets, manifest, source, uploader = _fixture(tmp_path)
    record = tmp_path / "uploads.jsonl"
    uploader.write_text(uploader.read_text().replace("uploads.jsonl", str(record)))
    result = publisher.publish_tree(
        key="b" * 40,
        source_commit="a" * 40,
        assets_dir=assets,
        uploader=uploader,
        endpoint_url="https://r2.example",
        bucket="cmux-binaries",
        manifest_file=manifest,
        source_file=source,
    )
    return assets, result, [json.loads(line) for line in record.read_text().splitlines()]


def test_publish_tree_requires_every_companion_and_records_completion(tmp_path: Path) -> None:
    _assets, digests, uploaded = _run_publish(tmp_path)
    assert set(digests) == set(publisher.COMPANION_NAMES)
    keys = {item["key"] for item in uploaded}
    for name in publisher.COMPANION_NAMES:
        assert f"cmux-tui/tree/{'b' * 40}/{name}" in keys
        assert f"cmux-tui/tree/{'b' * 40}/{name}.sha256" in keys
    assert f"cmux-tui/tree/{'b' * 40}/completion.json" in keys
    assert f"cmux-tui/tree/{'b' * 40}/source.json" not in keys


def test_publish_tree_rejects_partial_assets(tmp_path: Path) -> None:
    assets, manifest, source, uploader = _fixture(tmp_path)
    (assets / publisher.COMPANION_NAMES[-1]).unlink()
    try:
        publisher.publish_tree(
            key="b" * 40,
            source_commit="a" * 40,
            assets_dir=assets,
            uploader=uploader,
            endpoint_url="https://r2.example",
            bucket="cmux-binaries",
            manifest_file=manifest,
            source_file=source,
        )
    except publisher.PublicationError as error:
        assert "missing companion" in str(error)
    else:
        raise AssertionError("partial companion publication was accepted")


def test_cli_failure_prints_repair_pointer(tmp_path: Path) -> None:
    assets, manifest, _source, uploader = _fixture(tmp_path)
    (assets / publisher.COMPANION_NAMES[1]).unlink()
    result = subprocess.run(
        [
            sys.executable,
            str(SCRIPT),
            "--key", "b" * 40,
            "--source-commit", "a" * 40,
            "--assets-dir", str(assets),
            "--manifest-file", str(manifest),
            "--uploader", str(uploader),
            "--endpoint-url", "https://r2.example",
            "--bucket", "cmux-binaries",
        ],
        text=True,
        capture_output=True,
    )
    assert result.returncode == 1
    assert "see cmuxterm-hq REPAIR.md#cmux-tui-tree-publication" in result.stderr
