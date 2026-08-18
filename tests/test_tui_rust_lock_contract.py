from __future__ import annotations

from pathlib import Path
import sys
import tomllib

import pytest


ROOT = Path(__file__).resolve().parents[1]


def test_every_published_rust_sdk_lock_records_runtime_sha2() -> None:
    """Path consumers must stay --locked after cmux-sdk gains runtime hashing."""

    locks = sorted((ROOT / "cmux-tui").rglob("Cargo.lock"))
    sdk_packages: list[tuple[Path, dict[str, object]]] = []
    for lock in locks:
        document = tomllib.loads(lock.read_text(encoding="utf-8"))
        for package in document.get("package", []):
            if package.get("name") == "cmux-sdk" and package.get("version") == "1.0.0":
                sdk_packages.append((lock, package))

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
    lock = tmp_path / "cmux-tui" / "Cargo.lock"
    lock.parent.mkdir(parents=True)
    lock.write_text(
        "[[package]]\n"
        'name = "cmux-sdk"\n'
        'version = "9.9.9"\n'
        'dependencies = ["sha2"]\n',
        encoding="utf-8",
    )
    monkeypatch.setattr(sys.modules[__name__], "ROOT", tmp_path)

    test_every_published_rust_sdk_lock_records_runtime_sha2()
