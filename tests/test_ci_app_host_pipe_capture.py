#!/usr/bin/env python3
"""Keep app-host xcodebuild invocations off CI-owned pipe chains."""

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = [
    ROOT / ".github/workflows/ci.yml",
    ROOT / ".github/workflows/test-e2e.yml",
]


def named_step_blocks(text: str):
    lines = text.splitlines()
    starts = [
        index for index, line in enumerate(lines)
        if line.startswith("      - name:")
    ]
    starts.append(len(lines))
    for pos in range(len(starts) - 1):
        yield "\n".join(lines[starts[pos]:starts[pos + 1]])


def main() -> None:
    checked = 0
    for path in WORKFLOWS:
        text = path.read_text(encoding="utf-8")
        for block in named_step_blocks(text):
            if "run-app-host-xcodebuild.sh" not in block:
                continue
            checked += 1
            if "| tee" in block or "PIPESTATUS[" in block:
                raise SystemExit(
                    f"{path}: app-host xcodebuild step still uses a CI pipe chain"
                )
        if path.name == "test-e2e.yml":
            if "bash scripts/ci/run-and-capture.sh /tmp/xcodebuild-e2e.log" not in text:
                raise SystemExit(
                    "test-e2e.yml must use file-backed xcodebuild capture"
                )
    if checked == 0:
        raise SystemExit("no app-host xcodebuild workflow steps were found")
    print(f"ok: {checked} app-host workflow step(s) use pipe-safe capture")


if __name__ == "__main__":
    main()
