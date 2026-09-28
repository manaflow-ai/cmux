from __future__ import annotations

import hashlib
import os
import stat
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
UNIX_INSTALLER = ROOT / "web/public/tui/install-static.sh"
WINDOWS_INSTALLER = ROOT / "web/public/tui/install-static.ps1"


def write_executable(path: Path, contents: str) -> None:
    path.write_text(contents)
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


def test_unix_installer_selects_verifies_and_installs_native_binary(
    tmp_path: Path,
) -> None:
    fake_bin = tmp_path / "fake-bin"
    fake_bin.mkdir()
    payload = b"real cmux binary fixture\n"
    checksum = hashlib.sha256(payload).hexdigest()

    write_executable(
        fake_bin / "uname",
        """#!/bin/sh
if [ "$1" = "-s" ]; then printf 'Darwin\\n'; else printf 'arm64\\n'; fi
""",
    )
    write_executable(
        fake_bin / "curl",
        f"""#!/bin/sh
out=""
url=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    http*) url="$1"; shift ;;
    *) shift ;;
  esac
done
case "$url" in
  */manifest.json)
    printf '{{"binaries":{{"cmux-tui-aarch64-apple-darwin":"{checksum}"}}}}\\n' >"$out"
    ;;
  */cmux-tui-aarch64-apple-darwin)
    printf 'real cmux binary fixture\\n' >"$out"
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
            "CMUX_DOWNLOAD_BASE_URL": "https://fixtures.invalid/cmux-tui/latest",
            "CMUX_INSTALL": str(install_root),
            "PATH": f"{fake_bin}:{os.environ['PATH']}",
            "SHELL": "/bin/sh",
        },
        check=False,
        capture_output=True,
        text=True,
    )

    assert result.returncode == 0, result.stderr
    installed = install_root / "bin/cmux"
    assert installed.read_bytes() == payload
    assert installed.stat().st_mode & stat.S_IXUSR
    assert f"Installed cmux to {installed}" in result.stdout


def test_install_scripts_are_public_and_checksum_verified() -> None:
    unix = UNIX_INSTALLER.read_text()
    windows = WINDOWS_INSTALLER.read_text()

    assert "https://files.cmux.com/cmux-tui/latest" in unix
    assert "checksum verification failed" in unix
    assert "release manifest" not in unix
    assert "cmux-tui-x86_64-pc-windows-gnu.exe" in windows
    assert "Get-FileHash" in windows
    assert "SetEnvironmentVariable" in windows
    assert "SecurityProtocolType]::Tls12" in windows
    assert "release manifest" not in windows


def test_unix_installer_has_valid_shell_syntax() -> None:
    subprocess.run(["/bin/sh", "-n", str(UNIX_INSTALLER)], check=True)
