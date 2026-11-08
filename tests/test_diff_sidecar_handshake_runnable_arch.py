#!/usr/bin/env python3
"""The x86_64 nightly variant is prepared on Apple silicon minis that may lack
Rosetta. Running its sidecar handshake there fails with "Bad CPU type"
(exit 126), so the verifier must skip only the handshake when this host
cannot execute any of the sidecar's slices, keep every static check, and
still run the handshake when the host can run a slice.

The Mach-O tools, uname and arch are stubbed on PATH so the verifier runs on
any host against a fake sidecar that records whether it was executed."""
from __future__ import annotations

import os
import stat
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "verify-diff-sidecar-artifact.sh"

HANDSHAKE = (
    '{"id":"handshake","version":1,"error":null,"result":{"type":"handshake",'
    '"value":{"capabilities":["transport.webkit","transport.stdio"]}}}'
)


def write_executable(path: Path, body: str) -> None:
    path.write_text("#!/usr/bin/env bash\n" + body)
    path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


def run(tmp: Path, *, sidecar_archs: str, host_arch: str, rosetta: bool, minos: str = "14.0"):
    stubs = tmp / "stubs"
    stubs.mkdir()
    marker = tmp / "ran"
    sidecar = tmp / "cmux-diff-sidecar"
    write_executable(sidecar, f'touch "{marker}"\nprintf \'%s\\n\' \'{HANDSHAKE}\'\n')
    write_executable(stubs / "stat", 'echo 1024\n')
    write_executable(stubs / "lipo", f'echo "{sidecar_archs}"\n')
    write_executable(
        stubs / "otool",
        'case " $* " in\n'
        f'  *" -l "*) printf \'Load command 9\\n      cmd LC_BUILD_VERSION\\n    minos {minos}\\n\' ;;\n'
        '  *" -L "*) echo "$4:" ;;\n'
        'esac\n',
    )
    write_executable(stubs / "nm", 'exit 0\n')
    write_executable(stubs / "dwarfdump", 'exit 0\n')
    write_executable(stubs / "codesign", 'exit 1\n')
    write_executable(stubs / "uname", f'echo {host_arch}\n')
    write_executable(stubs / "arch", 'exit 0\n' if rosetta else 'echo "Bad CPU type" >&2; exit 1\n')
    env = {
        "PATH": f"{stubs}{os.pathsep}{os.environ.get('PATH', '/usr/bin:/bin')}",
        "HOME": str(tmp),
    }
    result = subprocess.run(
        ["bash", str(SCRIPT), str(sidecar), "--archs", sidecar_archs],
        capture_output=True,
        text=True,
        env=env,
        check=False,
    )
    return result, marker.exists()


def case(name: str, **kwargs):
    with tempfile.TemporaryDirectory() as tmp:
        result, ran = run(Path(tmp), **kwargs)
    output = result.stdout + result.stderr
    return name, result.returncode, ran, output


def main() -> None:
    name, code, ran, out = case("x86_64 on arm64 without Rosetta", sidecar_archs="x86_64", host_arch="arm64", rosetta=False)
    assert code == 0, f"{name}: exit {code}\n{out}"
    assert not ran, f"{name}: the sidecar must not be executed\n{out}"
    assert "handshake skipped" in out, f"{name}: expected a skipped-handshake note\n{out}"

    name, code, ran, out = case("x86_64 on arm64 with Rosetta", sidecar_archs="x86_64", host_arch="arm64", rosetta=True)
    assert code == 0, f"{name}: exit {code}\n{out}"
    assert ran, f"{name}: the handshake must run under Rosetta\n{out}"
    assert "handshake skipped" not in out, f"{name}\n{out}"

    name, code, ran, out = case("arm64 on arm64", sidecar_archs="arm64", host_arch="arm64", rosetta=False)
    assert code == 0, f"{name}: exit {code}\n{out}"
    assert ran, f"{name}: a native slice must run its handshake\n{out}"

    name, code, ran, out = case("universal on arm64 without Rosetta", sidecar_archs="arm64 x86_64", host_arch="arm64", rosetta=False)
    assert code == 0, f"{name}: exit {code}\n{out}"
    assert ran, f"{name}: the native slice must run its handshake\n{out}"

    name, code, ran, out = case("x86_64 on x86_64", sidecar_archs="x86_64", host_arch="x86_64", rosetta=False)
    assert code == 0, f"{name}: exit {code}\n{out}"
    assert ran, f"{name}: a native slice must run its handshake\n{out}"

    name, code, ran, out = case("arm64 on x86_64", sidecar_archs="arm64", host_arch="x86_64", rosetta=False)
    assert code == 0, f"{name}: exit {code}\n{out}"
    assert not ran, f"{name}: an Intel host cannot run an arm64 sidecar\n{out}"
    assert "handshake skipped" in out, f"{name}\n{out}"

    # Static checks still fail the skipped variant.
    name, code, ran, out = case(
        "x86_64 static failure without Rosetta", sidecar_archs="x86_64", host_arch="arm64", rosetta=False, minos="13.0"
    )
    assert code != 0, f"{name}: a static failure must still fail\n{out}"
    assert "expected 14.0" in out, f"{name}\n{out}"
    assert not ran, f"{name}\n{out}"
    print("ok")


if __name__ == "__main__":
    main()
