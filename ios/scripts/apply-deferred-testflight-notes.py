#!/usr/bin/env python3
"""Apply the argument-only request emitted by upload-testflight.sh after upload."""

import json
from pathlib import Path
import subprocess
import sys


def main():
    arguments = json.loads(Path(sys.argv[1]).read_text())
    allowed = {"--build-number", "--audience", "--bundle-id", "--notes", "--expect-marketing-version"}
    if (not isinstance(arguments, list) or len(arguments) % 2
            or not all(isinstance(value, str) for value in arguments)
            or any(flag not in allowed for flag in arguments[::2])
            or len(set(arguments[::2])) != len(arguments[::2])
            or not {"--build-number", "--audience", "--bundle-id"}.issubset(arguments[::2])):
        raise ValueError("invalid deferred TestFlight notes request")
    result = subprocess.run([str(Path(__file__).with_name("set-testflight-notes.sh")), *arguments])
    if result.returncode:
        print("warning: could not set TestFlight notes (the upload succeeded); "
              "re-run set-testflight-notes.sh after processing completes", file=sys.stderr)
    # The existing setter owns its bounded polling/retry behavior. Its failure
    # remains nonfatal once Apple accepted the IPA, just as on the local path.


if __name__ == "__main__":
    main()
