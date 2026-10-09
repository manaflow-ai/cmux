from __future__ import annotations

import importlib.util
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "ci" / "cmux_tui_platform_scope.py"
SPEC = importlib.util.spec_from_file_location("cmux_tui_platform_scope", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def _repo(tmp_path: Path, path: str, content: str) -> tuple[Path, str, str]:
    repo = tmp_path / "repo"
    repo.mkdir(parents=True)
    subprocess.run(["git", "-C", str(repo), "init", "-q"], check=True)
    subprocess.run(["git", "-C", str(repo), "config", "user.name", "test"], check=True)
    subprocess.run(["git", "-C", str(repo), "config", "user.email", "test@example.com"], check=True)
    (repo / "README").write_text("base\n", encoding="utf-8")
    subprocess.run(["git", "-C", str(repo), "add", "README"], check=True)
    subprocess.run(["git", "-C", str(repo), "commit", "-qm", "base"], check=True)
    base = subprocess.check_output(["git", "-C", str(repo), "rev-parse", "HEAD"], text=True).strip()
    target = repo / path
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(content, encoding="utf-8")
    subprocess.run(["git", "-C", str(repo), "add", path], check=True)
    subprocess.run(["git", "-C", str(repo), "commit", "-qm", "change"], check=True)
    head = subprocess.check_output(["git", "-C", str(repo), "rev-parse", "HEAD"], text=True).strip()
    return repo, base, head


def test_focused_scope_stays_linux_for_generic_rust_change(tmp_path: Path) -> None:
    repo, base, head = _repo(tmp_path, "cmux-tui/crates/core/src/lib.rs", "pub fn changed() {}\n")
    result = MODULE.scope(repo, base, head)
    assert result["os"] == ["linux"]
    assert result["macos_required"] is False


def test_cfg_macos_change_adds_macos(tmp_path: Path) -> None:
    repo, base, head = _repo(
        tmp_path,
        "cmux-tui/crates/core/src/platform.rs",
        '#[cfg(target_os = "macos")]\npub fn changed() {}\n',
    )
    result = MODULE.scope(repo, base, head)
    assert result["os"] == ["linux", "macos"]
    assert result["macos_paths"] == ["cmux-tui/crates/core/src/platform.rs"]


def test_pty_and_relay_paths_add_macos(tmp_path: Path) -> None:
    for path in ("cmux-tui/crates/pty/src/lib.rs", "cmux-tui/crates/chatmux-relay/src/lib.rs"):
        repo, base, head = _repo(tmp_path / path.replace("/", "-"), path, "pub fn changed() {}\n")
        assert MODULE.scope(repo, base, head)["macos_required"] is True
