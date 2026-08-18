from __future__ import annotations

from pathlib import Path
import sys
import tomllib

import pytest


ROOT = Path(__file__).resolve().parents[1]


def test_every_published_rust_sdk_lock_records_runtime_sha2() -> None:
    """Path consumers must stay --locked after cmux-sdk gains runtime hashing."""

    manifest = tomllib.loads(
        (ROOT / "cmux-tui" / "bindings" / "rust" / "Cargo.toml").read_text(
            encoding="utf-8"
        )
    )
    sdk_version = manifest["package"]["version"]
    locks = sorted((ROOT / "cmux-tui").rglob("Cargo.lock"))
    sdk_packages: list[tuple[Path, dict[str, object]]] = []
    for lock in locks:
        document = tomllib.loads(lock.read_text(encoding="utf-8"))
        sdk_packages.extend(
            (lock, package)
            for package in document.get("package", [])
            if package.get("name") == "cmux-sdk"
            and package.get("version") == sdk_version
        )

    assert sdk_packages, "no published cmux-sdk Cargo.lock package was found"
    missing = [
        str(lock.relative_to(ROOT))
        for lock, package in sdk_packages
        if not any(
            dependency == "sha2" or dependency.startswith("sha2 ")
            for dependency in package.get("dependencies", [])
        )
    ]
    assert not missing, "cmux-sdk runtime sha2 is missing from: " + ", ".join(missing)


def test_lock_contract_tracks_a_non_default_sdk_version(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    manifest = tmp_path / "cmux-tui" / "bindings" / "rust" / "Cargo.toml"
    manifest.parent.mkdir(parents=True)
    manifest.write_text(
        "[package]\n"
        'name = "cmux-sdk"\n'
        'version = "9.9.9"\n',
        encoding="utf-8",
    )
    lock = tmp_path / "cmux-tui" / "Cargo.lock"
    lock.parent.mkdir(parents=True, exist_ok=True)
    lock.write_text(
        "[[package]]\n"
        'name = "cmux-sdk"\n'
        'version = "9.9.9"\n'
        'dependencies = ["sha2"]\n',
        encoding="utf-8",
    )
    monkeypatch.setattr(sys.modules[__name__], "ROOT", tmp_path)

    test_every_published_rust_sdk_lock_records_runtime_sha2()
