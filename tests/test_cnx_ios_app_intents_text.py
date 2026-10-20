#!/usr/bin/env python3
"""cnx-ios/scripts/check-app-intents-text.py refuses device names in App Intents metadata.

App Store Connect rejected cmux INTERNAL builds with error 90626 because the
"Record Voice Note for Chief" description said "transcribed on this iPhone".
The checker runs on the built app in testflight-build.sh; this test runs it on
app bundles shaped like Xcode's output (Metadata.appintents/extract.actionsdata).
"""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CHECKER = ROOT / "cnx-ios/scripts/check-app-intents-text.py"


def app_with(description: str, root: Path, name: str) -> Path:
    app = root / f"{name}.app"
    (app / "Metadata.appintents").mkdir(parents=True)
    actions = {
        "actions": {
            "RecordChiefVoiceNoteIntent": {
                "title": {"key": "Record Voice Note for Chief"},
                "descriptionMetadata": {"descriptionText": {"key": description}},
            }
        }
    }
    (app / "Metadata.appintents/extract.actionsdata").write_text(json.dumps(actions), encoding="utf-8")
    return app


def run(app: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run([sys.executable, "-I", str(CHECKER), str(app)], capture_output=True, text=True)


def main() -> int:
    failures: list[str] = []
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        rejected = run(app_with("It is transcribed on this iPhone and sent to your Chief.", root, "bad"))
        if rejected.returncode != 1 or "this iPhone" not in rejected.stderr:
            failures.append(f"an iPhone description passed (exit {rejected.returncode}): {rejected.stderr}")
        accepted = run(app_with("It is transcribed on this device and sent to your Chief.", root, "good"))
        if accepted.returncode != 0:
            failures.append(f"a device-neutral description failed: {accepted.stderr}")
        empty = root / "none.app"
        empty.mkdir()
        if run(empty).returncode != 0:
            failures.append("an app without App Intents failed")
    for failure in failures:
        print(f"FAIL: {failure}")
    if not failures:
        print("PASS: App Intents text checker")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
