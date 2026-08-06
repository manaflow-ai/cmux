#!/usr/bin/env python3
"""Guard platform WebAuthn replies against the crashing attachment getter."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "Sources" / "Panels" / "BrowserWebAuthnSupport.swift"


def main() -> None:
    source = SOURCE.read_text(encoding="utf-8")
    start = source.index("    func successCredentialReply(")
    end = source.index("\n    func registrationReply(", start)
    body = source[start:end]

    forbidden = [
        "registration.attachment",
        "assertion.attachment",
    ]
    observed = [expression for expression in forbidden if expression in body]
    if observed:
        raise AssertionError(
            "platform credential replies still read the crashing framework getter: "
            + ", ".join(observed)
        )
    if body.count('attachment: "platform"') != 2:
        raise AssertionError(
            "platform registration and assertion replies must derive attachment from "
            "their concrete credential class"
        )

    print("PASS: platform WebAuthn replies avoid the redundant attachment getter")


if __name__ == "__main__":
    main()
