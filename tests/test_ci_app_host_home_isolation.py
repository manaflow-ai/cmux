#!/usr/bin/env python3
"""Guard app-host XCTest against persistent console-user configuration."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = (ROOT / ".github/workflows/ci.yml").read_text(encoding="utf-8")
CONSOLE_WRAPPER = (ROOT / "scripts/ci/run-in-console-session.sh").read_text(
    encoding="utf-8"
)


def require(text: str, needle: str, context: str) -> None:
    if needle not in text:
        raise SystemExit(f"FAIL: {context} is missing {needle!r}")


def main() -> int:
    requirements = {
        "isolated app-host setup step": "- name: Prepare isolated app-host home",
        "per-shard app-host home": (
            "APP_HOST_HOME=\"${RUNNER_TEMP}/cmux-app-host-home-"
            "${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}-shard-${{ matrix.shard }}\""
        ),
        "Core Foundation home redirect": (
            'echo "CFFIXED_USER_HOME=$APP_HOST_HOME" >> "$GITHUB_ENV"'
        ),
        "XDG configuration redirect": (
            'echo "XDG_CONFIG_HOME=$APP_HOST_HOME/.config" >> "$GITHUB_ENV"'
        ),
        "console-user write access": 'chmod -R a+rwX "$APP_HOST_HOME"',
        "real Cargo toolchain home": 'echo "CARGO_HOME=${HOME}/.cargo" >> "$GITHUB_ENV"',
        "real rustup toolchain home": 'echo "RUSTUP_HOME=${HOME}/.rustup" >> "$GITHUB_ENV"',
    }
    for context, needle in requirements.items():
        require(WORKFLOW, needle, context)

    require(
        CONSOLE_WRAPPER,
        "CFFIXED_USER_HOME XDG_CONFIG_HOME CARGO_HOME RUSTUP_HOME",
        "console-session environment forwarding",
    )
    require(
        CONSOLE_WRAPPER,
        "unset SSH_AUTH_SOCK",
        "ambient SSH agent removal",
    )
    require(
        CONSOLE_WRAPPER,
        'env HOME="$console_home"',
        "console-session Unix home preservation",
    )

    print("PASS: app-host XCTest uses isolated Apple state and preserved toolchains")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
