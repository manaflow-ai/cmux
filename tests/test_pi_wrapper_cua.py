#!/usr/bin/env python3
"""Pi Computer Use attachment must be session-scoped and fail closed."""

import shutil
import socket
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WRAPPER = ROOT / "Resources/bin/cmux-pi-wrapper"


def run_case(*, live: bool, trusted: bool, enabled: bool, credential: bool, token_mode: int = 0o600) -> list[str]:
    with tempfile.TemporaryDirectory(prefix="cmux-pi-cua-") as directory:
        root = Path(directory)
        resources = root / "Resources"
        (resources / "bin").mkdir(parents=True)
        (resources / "cmux-cua").mkdir()
        shutil.copy2(WRAPPER, resources / "bin/cmux-pi-wrapper")
        shutil.copy2(ROOT / "Resources/bin/cmux-pi-cua-extension.ts", resources / "bin/cmux-pi-cua-extension.ts")
        policy = resources / "cmux-cua/client-policy.sh"
        policy.write_text('cmux_computer_use_resolve_client() {\n  [ "${CMUX_TEST_TRUSTED:-}" = "1" ] || return 1\n  printf "%s" "$CMUX_CUA_CLIENT_PATH"\n}\n')
        bin_dir = root / "bin"
        bin_dir.mkdir()
        log = root / "args"
        fake_pi = bin_dir / "pi"
        fake_pi.write_text(f'#!/bin/sh\nprintf "%s\\n" "$@" > "{log}"\n')
        fake_pi.chmod(0o700)
        client = root / "installed-client"
        client.write_text("#!/bin/sh\n")
        client.chmod(0o700)
        token_file = root / "token"
        if credential:
            token_file.write_text("test-only-token\n")
            token_file.chmod(token_mode)
        surface = root / "surface.sock"
        native = root / "native.sock"
        listeners = []
        try:
            for path in (surface, native):
                listener = socket.socket(socket.AF_UNIX)
                listener.bind(str(path))
                listener.listen(1)
                listeners.append(listener)
            if not live:
                listeners[0].close()
                listeners.pop(0)
                surface.unlink()
            home = root / "home"
            setting = home / "Library/Application Support/cmux/cmux-cua/enabled"
            setting.parent.mkdir(parents=True)
            setting.write_text("1\n" if enabled else "0\n")
            env = {
                "HOME": str(home), "PATH": f"{bin_dir}:/usr/bin:/bin",
                "CMUX_SURFACE_ID": "surface-test", "CMUX_SOCKET_PATH": str(surface),
                "CMUX_CUA_SOCKET_PATH": str(native), "CMUX_CUA_CLIENT_PATH": str(client),
                "CMUX_CUA_AUTH_TOKEN_FILE": str(token_file),
                "CMUX_TEST_TRUSTED": "1" if trusted else "0",
            }
            subprocess.run([str(resources / "bin/cmux-pi-wrapper"), "--print", "hello"], env=env, check=True)
            return log.read_text().splitlines()
        finally:
            for listener in listeners:
                listener.close()


def main() -> None:
    positive = run_case(live=True, trusted=True, enabled=True, credential=True)
    if "-e" not in positive or not any(arg.endswith("cmux-pi-cua-extension.ts") for arg in positive):
        raise AssertionError(f"live trusted cmux session did not attach Pi Computer Use: {positive}")
    for name, options in {
        "stale surface": {"live": False},
        "untrusted client": {"trusted": False},
        "disabled in cmux": {"enabled": False},
        "missing credential": {"credential": False},
        "public credential": {"token_mode": 0o644},
    }.items():
        args = run_case(**({"live": True, "trusted": True, "enabled": True, "credential": True} | options))
        if any(arg.endswith("cmux-pi-cua-extension.ts") for arg in args):
            raise AssertionError(f"{name} unexpectedly attached Computer Use: {args}")
    print("Pi Computer Use wrapper: positive and five fail-closed cases passed")


if __name__ == "__main__":
    main()
