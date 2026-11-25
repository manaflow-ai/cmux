#!/usr/bin/env python3
"""chat-probe.sh hands its prompt to acpmux as text, never as a flag.

The controller allowlists scripts/ci/chat-probe.sh with pinned arguments, and
the probe runs acpmux under a mini's real home. A decoded prompt such as
`--cwd=/etc` or `--prompt-file=...` must not become an acpmux flag there, so
the run line passes `--` before "$prompt". This test runs that exact line with
a fake acpmux that records its argv and checks the prompt arrives last, after
`--`, unchanged.
"""

from __future__ import annotations

import os
import pathlib
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "ci" / "chat-probe.sh"


def run_line() -> str:
    lines = SCRIPT.read_text().splitlines()
    for i, line in enumerate(lines):
        if '"$acpmux" --json run' in line:
            # The env prefix line before it, the run line, then the redirect line.
            return "\n".join(lines[i - 1 : i + 2])
    raise SystemExit("chat-probe.sh: no acpmux run line found")


def main() -> int:
    line = run_line()
    failures = 0
    with tempfile.TemporaryDirectory() as tmp:
        work = pathlib.Path(tmp)
        fake = work / "acpmux"
        fake.write_text('#!/bin/bash\nprintf "%s\\0" "$@" > "$ARGV_OUT"\n')
        fake.chmod(0o755)
        for prompt in ["--cwd=/etc", "--prompt-file=/etc/passwd", "-m", "--", "hello"]:
            argv_out = work / "argv"
            body = (
                f"acpmux={fake}\nreal_home={work}\nacpmux_home={work}/h\nwork={work}\n"
                'harness=claude\nseconds=30\nprompt="$1"\n'
                f"{line}\nwait $!\n"
            )
            subprocess.run(
                ["bash", "-c", body, "probe", prompt],
                check=True,
                env={**os.environ, "ARGV_OUT": str(argv_out)},
            )
            argv = argv_out.read_bytes().split(b"\0")[:-1]
            got = [a.decode() for a in argv]
            if got[-2:] != ["--", prompt]:
                print(f"FAIL: prompt {prompt!r} reached acpmux as {got!r}", file=sys.stderr)
                failures += 1
    if failures:
        return 1
    print("PASS: chat-probe.sh passes every prompt to acpmux after --")
    return 0


if __name__ == "__main__":
    sys.exit(main())
