#!/usr/bin/env python3
"""The x86_64 nightly variant is prepared on Apple silicon minis that may lack
Rosetta. Running its sidecar handshake there fails with "Bad CPU type"
(exit 126), so the verifier must skip only the handshake when this host
cannot execute any of the sidecar's slices, and keep every static check."""
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "verify-diff-sidecar-artifact.sh"


def main() -> None:
    text = SCRIPT.read_text()
    guard = text.find('arch -x86_64 /usr/bin/true')
    handshake = text.find('HANDSHAKE="$("$BINARY" handshake)"')
    static_checks = text.find('LOCAL_SYMBOLS=')
    assert guard != -1, "verifier must check the host can run the sidecar before its handshake"
    assert handshake != -1, "verifier lost its handshake check"
    assert static_checks < guard < handshake, "Rosetta guard must sit after static checks and before the handshake"
    assert 'uname -m' in text, "guard must compare against the host architecture"
    print("ok")


if __name__ == "__main__":
    main()
