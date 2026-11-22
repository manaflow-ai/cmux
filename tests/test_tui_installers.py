from __future__ import annotations

import hashlib
import json
import os
import stat
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
UNIX_INSTALLER = ROOT / "web/public/tui/install-static.sh"
WINDOWS_INSTALLER = ROOT / "web/public/tui/install-static.ps1"
COMMIT = "a" * 40
PAYLOAD = b"real cmux binary fixture\n"


def write_executable(path: Path, contents: str) -> None:
    path.write_text(contents)
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


def run_unix_installer(
    tmp_path: Path,
    base_url: str,
    commit: str | None = COMMIT,
    payload: bytes = PAYLOAD,
) -> tuple[subprocess.CompletedProcess[str], Path, list[str]]:
    fake_bin = tmp_path / "fake-bin"
    fake_bin.mkdir()
    manifest = {
        "binaries": {
            "cmux-tui-aarch64-apple-darwin": hashlib.sha256(PAYLOAD).hexdigest(),
        },
    }
    if commit is not None:
        manifest["commit"] = commit
    (tmp_path / "manifest.json").write_text(json.dumps(manifest, indent=2))
    (tmp_path / "binary").write_bytes(payload)
    downloads = tmp_path / "downloads"

    write_executable(
        fake_bin / "uname",
        """#!/bin/sh
if [ "$1" = "-s" ]; then printf 'Darwin\\n'; else printf 'arm64\\n'; fi
""",
    )
    write_executable(
        fake_bin / "curl",
        """#!/bin/sh
out=""
url=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    http*) url="$1"; shift ;;
    *) shift ;;
  esac
done
printf '%s\\n' "$url" >>"$FIXTURES/downloads"
case "$url" in
  */manifest.json)
    cp "$FIXTURES/manifest.json" "$out"
    ;;
  */cmux-tui-aarch64-apple-darwin)
    case "$url" in
      */latest/*) printf 'stale cmux binary fixture\\n' >"$out" ;;
      *) cp "$FIXTURES/binary" "$out" ;;
    esac
    ;;
  *) exit 22 ;;
esac
""",
    )

    install_root = tmp_path / "install"
    result = subprocess.run(
        ["/bin/sh", str(UNIX_INSTALLER)],
        cwd=ROOT,
        env={
            **os.environ,
            "CMUX_DOWNLOAD_BASE_URL": base_url,
            "CMUX_INSTALL": str(install_root),
            "FIXTURES": str(tmp_path),
            "PATH": f"{fake_bin}:{os.environ['PATH']}",
            "SHELL": "/bin/sh",
        },
        check=False,
        capture_output=True,
        text=True,
    )
    return result, install_root / "bin/cmux", downloads.read_text().splitlines()


def test_unix_installer_selects_verifies_and_installs_native_binary(
    tmp_path: Path,
) -> None:
    result, installed, downloads = run_unix_installer(
        tmp_path, "https://fixtures.invalid/cmux-tui/latest",
    )

    assert result.returncode == 0, result.stderr
    assert installed.read_bytes() == PAYLOAD
    assert installed.stat().st_mode & stat.S_IXUSR
    assert f"Installed cmux to {installed}" in result.stdout
    assert downloads[:2] == [
        "https://fixtures.invalid/cmux-tui/latest/manifest.json",
        f"https://fixtures.invalid/cmux-tui/{COMMIT}/cmux-tui-aarch64-apple-darwin",
    ]
    assert sum(url.endswith("/manifest.json") for url in downloads) == 1


def test_install_scripts_are_public_and_checksum_verified() -> None:
    unix = UNIX_INSTALLER.read_text()
    windows = WINDOWS_INSTALLER.read_text()

    assert "https://files.cmux.com/cmux-tui/latest" in unix
    assert "checksum verification failed" in unix
    assert '"commit"' in unix
    assert "artifact_base_url" in unix
    assert "release manifest" not in unix
    assert "cmux-tui-x86_64-pc-windows-gnu.exe" in windows
    assert "Get-FileHash" in windows
    assert "$Manifest.commit" in windows
    assert "$ArtifactBaseUrl" in windows
    assert "SetEnvironmentVariable" in windows
    assert "SecurityProtocolType]::Tls12" in windows
    assert "release manifest" not in windows


def test_unix_installer_has_valid_shell_syntax() -> None:
    subprocess.run(["/bin/sh", "-n", str(UNIX_INSTALLER)], check=True)


def test_unix_installer_preserves_overrides_and_trims_trailing_slashes() -> None:
    for suffix in (COMMIT, "mirror", "latest/"):
        with tempfile.TemporaryDirectory() as directory:
            base_url = f"https://fixtures.invalid/cmux-tui/{suffix}"
            result, installed, downloads = run_unix_installer(Path(directory), base_url)
            assert result.returncode == 0, result.stderr
            assert installed.read_bytes() == PAYLOAD
            artifact_base = base_url.rstrip("/")
            if suffix == "latest/":
                artifact_base = f"https://fixtures.invalid/cmux-tui/{COMMIT}"
            assert downloads[1] == f"{artifact_base}/cmux-tui-aarch64-apple-darwin"


def test_unix_installer_rejects_missing_or_invalid_commit_before_binary_download() -> None:
    for commit in (None, "", "b" * 39, "g" * 40, "../escape"):
        with tempfile.TemporaryDirectory() as directory:
            result, installed, downloads = run_unix_installer(
                Path(directory), "https://fixtures.invalid/cmux-tui/latest", commit,
            )
            assert result.returncode != 0
            assert "manifest has no commit" in result.stderr
            assert not installed.exists()
            assert len(downloads) == 1


def test_unix_installer_rejects_wrong_commit_binary_checksum() -> None:
    with tempfile.TemporaryDirectory() as directory:
        result, installed, _ = run_unix_installer(
            Path(directory), "https://fixtures.invalid/cmux-tui/latest", payload=b"wrong binary\n",
        )
        assert result.returncode != 0
        assert "checksum verification failed" in result.stderr
        assert not installed.exists()


if __name__ == "__main__":
    with tempfile.TemporaryDirectory() as directory:
        test_unix_installer_selects_verifies_and_installs_native_binary(Path(directory))
    test_install_scripts_are_public_and_checksum_verified()
    test_unix_installer_has_valid_shell_syntax()
    test_unix_installer_preserves_overrides_and_trims_trailing_slashes()
    test_unix_installer_rejects_missing_or_invalid_commit_before_binary_download()
    test_unix_installer_rejects_wrong_commit_binary_checksum()
    print("cmux-tui installer tests passed")
