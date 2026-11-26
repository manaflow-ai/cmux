#!/usr/bin/env python3
"""
Regression test (#6447): `cmux claude-teams` grants the Claude trust-gate bypass
(CLAUDE_CODE_SANDBOXED) only when THIS invocation opts in with
--dangerously-skip-permissions, and clears any ambient opt-in marker inherited
from a parent session when it does not, so the bypass never leaks across launches.
"""

from __future__ import annotations

import os
import subprocess
import tempfile
from pathlib import Path

from claude_teams_test_utils import resolve_cmux_cli


def run(cli_path: str, args: list[str], extra_env: dict[str, str]) -> tuple[str, str]:
    with tempfile.TemporaryDirectory(prefix="cmux-teams-trust-") as td:
        tmp = Path(td)
        real_bin = tmp / "bin"
        real_bin.mkdir()
        sandboxed_log = tmp / "sandboxed.log"
        marker_log = tmp / "marker.log"
        fake = real_bin / "claude"
        fake.write_text(
            "#!/usr/bin/env bash\n"
            'printf "%s" "${CLAUDE_CODE_SANDBOXED-__UNSET__}" > "$L1"\n'
            'printf "%s" "${CMUX_CLAUDE_TEAMS_SANDBOXED-__UNSET__}" > "$L2"\n',
            encoding="utf-8",
        )
        fake.chmod(0o755)
        env = dict(os.environ)
        env.update(extra_env)
        env["PATH"] = f"{real_bin}:{env.get('PATH', '/usr/bin:/bin')}"
        env["HOME"] = str(tmp / "home")
        Path(env["HOME"]).mkdir(parents=True, exist_ok=True)
        env["L1"] = str(sandboxed_log)
        env["L2"] = str(marker_log)
        subprocess.run(
            [cli_path, "--socket", str(tmp / "s.sock"), "claude-teams"] + args,
            env=env,
            capture_output=True,
            text=True,
            timeout=30,
            check=False,
        )

        def read(p: Path) -> str:
            return p.read_text(encoding="utf-8") if p.exists() else "__NOLOG__"

        return read(sandboxed_log), read(marker_log)


def main() -> int:
    cli = resolve_cmux_cli()

    # Opted in: both the Claude env var and the cmux propagation marker are set.
    sandboxed, marker = run(cli, ["--dangerously-skip-permissions", "--version"], {})
    if sandboxed != "1" or marker != "1":
        print(f"FAIL: opted-in launch must set markers, got sandboxed={sandboxed!r} marker={marker!r}")
        return 1

    # Not opted in, but a parent set the markers: they must be CLEARED, not inherited.
    sandboxed, marker = run(
        cli,
        ["--version"],
        {"CLAUDE_CODE_SANDBOXED": "1", "CMUX_CLAUDE_TEAMS_SANDBOXED": "1"},
    )
    if sandboxed != "__UNSET__" or marker != "__UNSET__":
        print(f"FAIL: non-opted launch must clear ambient markers, got sandboxed={sandboxed!r} marker={marker!r}")
        return 1

    print("PASS: cmux claude-teams gates the trust bypass on the current opt-in and clears ambient markers")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
