#!/usr/bin/env python3
"""Regression test: socket password keychain entries are scoped per debug instance."""

from __future__ import annotations

import subprocess
from pathlib import Path


def get_repo_root() -> Path:
    result = subprocess.run(
        ["git", "rev-parse", "--show-toplevel"],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode == 0:
        return Path(result.stdout.strip())
    return Path.cwd()


def require(content: str, needle: str, message: str, failures: list[str]) -> None:
    if needle not in content:
        failures.append(message)


def reject(content: str, needle: str, message: str, failures: list[str]) -> None:
    if needle in content:
        failures.append(message)


def main() -> int:
    repo_root = get_repo_root()
    cli_path = repo_root / "CLI" / "cmux.swift"
    settings_path = repo_root / "Sources" / "SocketControlSettings.swift"

    missing = [str(path) for path in (cli_path, settings_path) if not path.exists()]
    if missing:
        print("FAIL: missing expected files:")
        for path in missing:
            print(f"- {path}")
        return 1

    cli = cli_path.read_text(encoding="utf-8")
    settings = settings_path.read_text(encoding="utf-8")
    failures: list[str] = []

    require(
        cli,
        "static func resolve(explicit: String?, socketPath: String) -> String?",
        "CLI resolver must accept socketPath to determine scoped keychain service",
        failures,
    )
    require(
        cli,
        "private static func keychainServices(socketPath: String) -> [String]",
        "CLI must derive keychain services from socket context",
        failures,
    )
    require(
        cli,
        'return ["\\(service).\\(scope)"]',
        "CLI should use only the scoped keychain service when scope is present",
        failures,
    )
    require(
        cli,
        "URL(fileURLWithPath: socketPath).lastPathComponent",
        "CLI scope detection should parse the socket file name",
        failures,
    )
    require(
        cli,
        "kSecUseAuthenticationContext as String: authContext",
        "CLI keychain lookup must fail fast without interactive keychain prompts",
        failures,
    )
    require(
        cli,
        "SocketPasswordResolver.resolve(explicit: socketPasswordArg, socketPath: socketPath)",
        "CLI run path must pass socketPath into password resolution",
        failures,
    )

    require(
        settings,
        "private static func keychainScope(environment: [String: String]) -> String?",
        "App keychain store should compute a scoped keychain namespace",
        failures,
    )
    require(
        settings,
        "environment[SocketControlSettings.launchTagEnvKey]",
        "App keychain scope should prioritize CMUX_TAG",
        failures,
    )
    require(
        settings,
        "URL(fileURLWithPath: socketPath).lastPathComponent",
        "App keychain scope should parse the socket file name",
        failures,
    )
    require(
        settings,
        "private static func keychainService(environment: [String: String]) -> String",
        "App keychain service should be derived from environment scope",
        failures,
    )
    require(
        settings,
        'return "\\(service).\\(scope)"',
        "App keychain service should append the scoped suffix",
        failures,
    )
    require(
        settings,
        "kSecAttrService as String: keychainService(environment: environment)",
        "App keychain queries should use mode-specific scoped service",
        failures,
    )
    require(
        settings,
        "return try? loadPassword(environment: environment)",
        "configuredPassword should read keychain from matching scoped service",
        failures,
    )

    reject(
        settings,
        "private static var baseQuery: [String: Any]",
        "Legacy global baseQuery should not remain as a static unscoped property",
        failures,
    )

    if failures:
        print("FAIL: keychain scope regression(s) detected")
        for failure in failures:
            print(f"- {failure}")
        return 1

    print("PASS: socket password keychain service is scoped by tagged debug instance")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
