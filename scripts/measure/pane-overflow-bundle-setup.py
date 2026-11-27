#!/usr/bin/env python3
"""Keep historical bundle installation from deleting its tracked placeholder docs.

Only missing GENERATED.md documents are restored, byte-for-byte from HEAD, before
compilation. Existing modifications and every other tracked path remain untouched
and subject to the measurement's strict source fence.
"""
from pathlib import Path
import subprocess
import sys


def main():
    builder = Path.cwd() / "scripts/cmux-next/build-web-bundles.sh"
    docs = {}
    if sys.argv[1:2] == ["--from"]:
        for folder in ("CmuxNextAgentPane/Resources/agent-pane", "CmuxNextPages/Resources/pages",
                       "CmuxNextAgentActivity/Resources/agent-activity"):
            path = Path("Packages/macOS/CmuxNext/Sources") / folder / "GENERATED.md"
            expected = subprocess.check_output(["git", "show", f"HEAD:{path}"])
            if not path.is_file() or path.read_bytes() != expected:
                print(f"NATIVE_FADE_SETUP_DOC_CHANGED {path}", file=sys.stderr)
                return 2
            docs[path] = expected
    result = subprocess.run([str(builder), *sys.argv[1:]])
    if result.returncode:
        return result.returncode if result.returncode > 0 else 128 - result.returncode
    for path, expected in docs.items():
        if not path.exists() and not path.is_symlink():
            path.write_bytes(expected)
            print(f"NATIVE_FADE_RESTORED_SETUP_DOC {path}", flush=True)
        elif not path.is_file() or path.read_bytes() != expected:
            print(f"NATIVE_FADE_SETUP_DOC_CHANGED {path}", file=sys.stderr)
            return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
