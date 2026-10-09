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
    uploader.write_text(
        "#!/usr/bin/env python3\n"
        "import json, pathlib, sys\n"
        "args = sys.argv[1:]\n"
        "def value(name): return args[args.index(name) + 1]\n"
        'pathlib.Path(__file__).with_name("uploads.jsonl").open("a").write(json.dumps({"key": value("--key"), "file": value("--file")}) + "\\n")\n'
    )
    uploader.chmod(0o755)
    return assets, manifest, source, uploader


def _run_publish(tmp_path: Path):
    assets, manifest, source, uploader = _fixture(tmp_path)
    record = tmp_path / "uploads.jsonl"
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


LINUX_TREE_NAMES = (
    "cmux-tui-x86_64-unknown-linux-musl",
    "cmux-tui-aarch64-unknown-linux-musl",
    "cmux-tui-app-host-x86_64-unknown-linux-musl",
    "cmux-tui-app-host-aarch64-unknown-linux-musl",
)


def test_tree_carries_the_linux_daemon_and_app_host() -> None:
    # Linux daemon mode (GPUI) fetches cmux-tui and its app host by tree key.
    for name in LINUX_TREE_NAMES:
        assert name in publisher.COMPANION_NAMES, name
    # The macOS companions stay: the cmux-next gate reads them.
    assert publisher.COMPANION_NAMES[:3] == (
        "cmux-tui-aarch64-apple-darwin",
        "cmux-tui-app-host-aarch64-apple-darwin",
        "cmux-tui-cloud-server-aarch64-apple-darwin",
    )


def test_list_companions_is_the_one_list_the_workflow_reads() -> None:
    result = subprocess.run([sys.executable, str(SCRIPT), "--list-companions"],
                            text=True, capture_output=True, check=True)
    assert tuple(result.stdout.split()) == publisher.COMPANION_NAMES


def test_completion_json_keeps_the_pre_linux_bytes(tmp_path: Path) -> None:
    # completion.json is immutable. A republication of a tree published before
    # the Linux targets must write the same bytes, so it attests only the macOS
    # three; the Linux digests go to completion-linux.json.
    assets, manifest, source, uploader = _fixture(tmp_path)
    uploader.write_text(
        "#!/usr/bin/env python3\n"
        "import json, pathlib, sys\n"
        "args = sys.argv[1:]\n"
        "def value(name): return args[args.index(name) + 1]\n"
        'pathlib.Path(__file__).with_name("contents.jsonl").open("a").write(json.dumps({"key": value("--key"), "text": pathlib.Path(value("--file")).read_bytes().decode("latin-1")}) + "\\n")\n'
    )
    publisher.publish_tree(key="b" * 40, source_commit="a" * 40, assets_dir=assets, uploader=uploader,
                           endpoint_url="https://r2.example", bucket="cmux-binaries",
                           manifest_file=manifest, source_file=source)
    uploads = [json.loads(line) for line in (tmp_path / "contents.jsonl").read_text().splitlines()]
    by_key = {item["key"].rsplit("/", 1)[-1]: item["text"] for item in uploads}
    gate = json.loads(by_key["completion.json"])
    assert sorted(gate["binaries"]) == sorted(publisher.COMPANION_NAMES[:3])
    linux = json.loads(by_key["completion-linux.json"])
    assert sorted(linux["binaries"]) == sorted(LINUX_TREE_NAMES)
    # completion.json is written last: it is what the gate reads as complete.
    assert uploads[-1]["key"].endswith("/completion.json")


WINDOWS_NAME = "cmux-tui-x86_64-pc-windows-gnu.exe"


def _windows_fixture(tmp_path: Path, commit: str) -> Path:
    """Writes the Windows daemon into the fixture assets and returns a manifest of `commit` for it."""
    path = tmp_path / "assets" / WINDOWS_NAME
    path.write_bytes(b"windows-daemon" * 11)
    manifest = tmp_path / "windows-manifest.json"
    manifest.write_text(json.dumps({"commit": commit, "binaries": {
        WINDOWS_NAME: hashlib.sha256(path.read_bytes()).hexdigest()}}))
    return manifest


def _contents_uploader(uploader: Path) -> None:
    uploader.write_text(
        "#!/usr/bin/env python3\n"
        "import json, pathlib, sys\n"
        "args = sys.argv[1:]\n"
        "def value(name): return args[args.index(name) + 1]\n"
        'pathlib.Path(__file__).with_name("contents.jsonl").open("a").write(json.dumps({"key": value("--key"), "text": pathlib.Path(value("--file")).read_bytes().decode("latin-1")}) + "\\n")\n'
    )


def test_windows_companion_is_listed_apart_from_the_unix_companions() -> None:
    assert publisher.WINDOWS_NAMES == (WINDOWS_NAME,)
    assert WINDOWS_NAME not in publisher.COMPANION_NAMES
    result = subprocess.run([sys.executable, str(SCRIPT), "--list-windows-companions"],
                            text=True, capture_output=True, check=True)
    assert tuple(result.stdout.split()) == publisher.WINDOWS_NAMES


def test_windows_companion_from_a_newer_commit_gets_its_own_completion(tmp_path: Path) -> None:
    # A tree published before the Windows target keeps its source commit (a);
    # its Windows binary comes from a newer build (c) of the same tree.
    assets, manifest, source, uploader = _fixture(tmp_path)
    windows_manifest = _windows_fixture(tmp_path, "c" * 40)
    _contents_uploader(uploader)
    digests = publisher.publish_tree(
        key="b" * 40, source_commit="a" * 40, assets_dir=assets, uploader=uploader,
        endpoint_url="https://r2.example", bucket="cmux-binaries",
        manifest_file=manifest, source_file=source,
        windows_manifest_file=windows_manifest, windows_source_commit="c" * 40)
    assert WINDOWS_NAME in digests
    uploads = [json.loads(line) for line in (tmp_path / "contents.jsonl").read_text().splitlines()]
    by_key = {item["key"].rsplit("/", 1)[-1]: item["text"] for item in uploads}
    digest = hashlib.sha256((assets / WINDOWS_NAME).read_bytes()).hexdigest()
    assert by_key[f"{WINDOWS_NAME}.sha256"] == f"{digest}  {WINDOWS_NAME}\n"
    windows = json.loads(by_key["completion-windows.json"])
    assert windows["sourceCommit"] == "c" * 40
    assert windows["binaries"] == {WINDOWS_NAME: digest}
    assert "sourceSha256" not in windows
    # The macOS gate and the Linux completion keep their bytes.
    assert sorted(json.loads(by_key["completion.json"])["binaries"]) == sorted(publisher.COMPANION_NAMES[:3])
    assert WINDOWS_NAME not in json.loads(by_key["completion-linux.json"])["binaries"]
    assert uploads[-1]["key"].endswith("/completion.json")


def test_windows_companion_must_match_its_manifest(tmp_path: Path) -> None:
    assets, manifest, source, uploader = _fixture(tmp_path)
    windows_manifest = _windows_fixture(tmp_path, "c" * 40)
    (assets / WINDOWS_NAME).write_bytes(b"tampered")
    for kwargs, message in (
        ({"windows_manifest_file": windows_manifest, "windows_source_commit": "c" * 40}, "does not match commit manifest"),
        ({"windows_manifest_file": windows_manifest, "windows_source_commit": "d" * 40}, "does not match"),
        ({"windows_manifest_file": windows_manifest}, "go together"),
    ):
        try:
            publisher.publish_tree(
                key="b" * 40, source_commit="a" * 40, assets_dir=assets, uploader=uploader,
                endpoint_url="https://r2.example", bucket="cmux-binaries",
                manifest_file=manifest, source_file=source, **kwargs)
        except publisher.PublicationError as error:
            assert message in str(error), error
        else:
            raise AssertionError(f"accepted {kwargs}")
    assert not (tmp_path / "uploads.jsonl").exists()


def test_without_windows_arguments_no_windows_object_is_written(tmp_path: Path) -> None:
    # The pull_request_target publisher (base helper) passes no Windows arguments.
    _assets, digests, uploaded = _run_publish(tmp_path)
    assert WINDOWS_NAME not in digests
    assert not any(WINDOWS_NAME in item["key"] or "completion-windows" in item["key"] for item in uploaded)
