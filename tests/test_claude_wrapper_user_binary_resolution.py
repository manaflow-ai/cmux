#!/usr/bin/env python3
from __future__ import annotations

import os
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
WRAPPER = ROOT / "Resources" / "bin" / "cmux-claude-wrapper"


def write_executable(path: Path, contents: str) -> None:
    path.write_text(contents, encoding="utf-8")
    path.chmod(0o755)


def run_wrapper(argv: list[str], env: dict[str, str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        argv,
        env=env,
        capture_output=True,
        text=True,
        timeout=8,
        check=False,
    )


def test_wrapper_skips_cmux_shims_and_bundled_claude(failures: list[str]) -> None:
    with tempfile.TemporaryDirectory(prefix="cmux-claude-wrapper-resolution-") as td:
        root = Path(td)
        bundle_bin = root / "cmux.app" / "Contents" / "Resources" / "bin"
        shim_bin = root / "shim-bin"
        real_bin = root / "real-bin"
        for directory in (bundle_bin, shim_bin, real_bin):
            directory.mkdir(parents=True, exist_ok=True)

        wrapper = bundle_bin / "cmux-claude-wrapper"
        wrapper.write_bytes(WRAPPER.read_bytes())
        wrapper.chmod(0o755)

        write_executable(
            bundle_bin / "claude",
            """#!/usr/bin/env bash
echo bundled-claude "$@"
""",
        )
        write_executable(
            real_bin / "claude",
            """#!/usr/bin/env bash
echo real-claude "$@"
""",
        )
        shim = shim_bin / "claude"
        write_executable(
            shim,
            f"""#!/usr/bin/env bash
export CMUX_CLAUDE_WRAPPER_SHIM="{shim}"
export CMUX_CLAUDE_WRAPPER_SHIM_ROOT="{shim_bin}"
exec "{wrapper}" "$@"
""",
        )

        env = dict(os.environ)
        env["PATH"] = f"{shim_bin}:{bundle_bin}:{real_bin}:/usr/bin:/bin"
        env["CMUX_CLAUDE_WRAPPER_SHIM"] = str(shim)
        env["CMUX_CLAUDE_WRAPPER_SHIM_ROOT"] = str(shim_bin)
        env["CMUX_CUSTOM_CLAUDE_PATH"] = str(bundle_bin / "claude")
        env.pop("CMUX_SURFACE_ID", None)
        env.pop("CMUX_SOCKET_PATH", None)

        result = run_wrapper([str(shim), "--version"], env)
        output = (result.stdout + result.stderr).strip()
        if result.returncode != 0:
            failures.append(f"wrapper exited {result.returncode}: {output}")
        if output != "real-claude --version":
            failures.append(f"expected user claude, got {output!r}")


def main() -> int:
    failures: list[str] = []
    test_wrapper_skips_cmux_shims_and_bundled_claude(failures)
    if failures:
        print("FAIL: claude wrapper binary resolution checks failed")
        for failure in failures:
            print(f"- {failure}")
        return 1
    print("PASS: claude wrapper resolves the user-owned claude binary")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
