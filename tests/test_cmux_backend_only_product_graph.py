#!/usr/bin/env python3
"""Deterministic guards for the Ghostty-free macOS frontend product."""

from __future__ import annotations

import json
import os
import plistlib
import stat
import subprocess
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
VERIFIER = ROOT / "scripts" / "verify-cmux-backend-only-product.py"
TERMINAL_PACKAGE = ROOT / "Packages/macOS/CmuxTerminal"


def run_verifier(
    package_path: Path,
    *arguments: str,
    environment: dict[str, str] | None = None,
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [
            sys.executable,
            str(VERIFIER),
            "--package-path",
            str(package_path),
            "--product",
            "CmuxTerminalFrontend",
            *arguments,
        ],
        cwd=ROOT,
        env=environment,
        text=True,
        capture_output=True,
        check=False,
    )


def write_fixture_package(root: Path, *, frontend_dependency: str = "CmuxTerminalDomain") -> Path:
    package = root / "CmuxTerminal"
    (package / "Sources/CmuxTerminalDomain").mkdir(parents=True)
    (package / "Sources/CmuxTerminalFrontend").mkdir(parents=True)
    if frontend_dependency != "CmuxTerminalDomain":
        (package / f"Sources/{frontend_dependency}").mkdir(parents=True)

    extra_target = ""
    if frontend_dependency != "CmuxTerminalDomain":
        extra_target = f',\n        .target(name: "{frontend_dependency}")'
        (package / f"Sources/{frontend_dependency}/Fixture.swift").write_text(
            "public struct Fixture {}\n",
            encoding="utf-8",
        )

    (package / "Package.swift").write_text(
        f"""// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CmuxTerminal",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CmuxTerminalDomain", targets: ["CmuxTerminalDomain"]),
        .library(name: "CmuxTerminalFrontend", targets: ["CmuxTerminalFrontend"]),
    ],
    targets: [
        .target(name: "CmuxTerminalDomain"),
        .target(
            name: "CmuxTerminalFrontend",
            dependencies: ["{frontend_dependency}"]
        ){extra_target},
    ]
)
""",
        encoding="utf-8",
    )
    (package / "Sources/CmuxTerminalDomain/TerminalIdentity.swift").write_text(
        "import Foundation\npublic struct TerminalIdentity: Sendable {}\n",
        encoding="utf-8",
    )
    (package / "Sources/CmuxTerminalFrontend/TerminalView.swift").write_text(
        "import AppKit\nimport CmuxTerminalDomain\npublic final class TerminalView: NSView {}\n",
        encoding="utf-8",
    )
    return package


def write_fake_tool(path: Path, body: str) -> None:
    path.write_text("#!/usr/bin/env bash\nset -euo pipefail\n" + body, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


def write_artifact_fixture(root: Path) -> tuple[Path, Path]:
    app = root / "cmux.app"
    macos = app / "Contents/MacOS"
    macos.mkdir(parents=True)
    executable = macos / "cmux"
    debug_library = macos / "cmux.debug.dylib"
    executable.write_bytes(b"host fixture\n")
    debug_library.write_bytes(b"debug fixture\n")
    with (app / "Contents/Info.plist").open("wb") as stream:
        plistlib.dump(
            {
                "CFBundleExecutable": "cmux",
                "CMUXTerminalBackendServiceEnabled": True,
                "CMUXTerminalRuntimeOwnership": "backend-only",
            },
            stream,
        )

    tools = root / "tools"
    tools.mkdir()
    write_fake_tool(tools / "file", "printf '%s: Mach-O 64-bit executable arm64\\n' \"$1\"\n")
    write_fake_tool(
        tools / "nm",
        """if [[ "${CMUX_PRODUCT_GRAPH_FIXTURE:-clean}" == "dlopen" ]]; then
  printf '                 U _dlopen\n'
fi
""",
    )
    write_fake_tool(
        tools / "otool",
        """mode="$1"
binary="$2"
if [[ "$mode" == "-L" ]]; then
  printf '%s:\n' "$binary"
  if [[ "$binary" == */MacOS/cmux ]]; then
    printf '\t@rpath/cmux.debug.dylib (compatibility version 0.0.0, current version 0.0.0)\n'
  fi
  printf '\t/usr/lib/libSystem.B.dylib (compatibility version 1.0.0, current version 1.0.0)\n'
elif [[ "$mode" == "-l" ]]; then
  printf 'Load command 0\n'
  printf '          cmd LC_RPATH\n'
  printf '      cmdsize 40\n'
  printf '         path @executable_path (offset 12)\n'
else
  exit 2
fi
""",
    )
    write_fake_tool(tools / "strings", ":\n")
    return app, tools


def test_repository_frontend_product_has_a_ghostty_free_closure() -> None:
    result = run_verifier(TERMINAL_PACKAGE)
    assert result.returncode == 0, result.stderr
    report = json.loads(result.stdout)
    target_names = {node["target"] for node in report["product_closure"]["nodes"]}
    assert "CmuxTerminalFrontend" in target_names
    assert "CmuxTerminalDomain" in target_names
    assert target_names.isdisjoint(
        {"CmuxTerminal", "CmuxTerminalCore", "GhosttyKit", "GhosttyRuntimeTestStubs"}
    )
    assert len(report["graph_sha256"]) == 64


def test_source_policy_rejects_ghostty_and_dynamic_loading() -> None:
    with tempfile.TemporaryDirectory() as temporary_directory:
        package = write_fixture_package(Path(temporary_directory))
        source = package / "Sources/CmuxTerminalFrontend/TerminalView.swift"

        source.write_text("import AppKit\nimport GhosttyKit\n", encoding="utf-8")
        result = run_verifier(package)
        assert result.returncode != 0
        assert "forbidden import GhosttyKit" in result.stderr

        source.write_text(
            "import AppKit\nfunc loadRuntime(_ path: String) { _ = dlopen(path, RTLD_NOW) }\n",
            encoding="utf-8",
        )
        result = run_verifier(package)
        assert result.returncode != 0
        assert "dynamic-load escape hatch" in result.stderr


def test_product_closure_rejects_legacy_targets_even_without_forbidden_imports() -> None:
    with tempfile.TemporaryDirectory() as temporary_directory:
        package = write_fixture_package(
            Path(temporary_directory),
            frontend_dependency="CmuxTerminalCore",
        )
        result = run_verifier(package)
        assert result.returncode != 0
        assert "forbidden target CmuxTerminalCore" in result.stderr


def test_artifact_attestation_binds_graph_to_recursive_host_load_closure() -> None:
    with tempfile.TemporaryDirectory() as temporary_directory:
        temporary_root = Path(temporary_directory)
        package = write_fixture_package(temporary_root)
        app, tools = write_artifact_fixture(temporary_root)
        environment = dict(os.environ)
        environment["PATH"] = f"{tools}:{environment['PATH']}"

        result = run_verifier(package, "--app-bundle", str(app), environment=environment)
        assert result.returncode == 0, result.stderr
        report = json.loads(result.stdout)
        artifact = report["host_artifact"]
        assert artifact["executable"] == "Contents/MacOS/cmux"
        assert {item["path"] for item in artifact["load_closure"]} == {
            "Contents/MacOS/cmux",
            "Contents/MacOS/cmux.debug.dylib",
        }
        assert artifact["load_edges"] == [
            {
                "from": "Contents/MacOS/cmux",
                "load": "@rpath/cmux.debug.dylib",
                "to": "Contents/MacOS/cmux.debug.dylib",
            }
        ]
        assert len(artifact["attestation_sha256"]) == 64

        environment["CMUX_PRODUCT_GRAPH_FIXTURE"] = "dlopen"
        result = run_verifier(package, "--app-bundle", str(app), environment=environment)
        assert result.returncode != 0
        assert "dynamic-load symbol _dlopen" in result.stderr


def main() -> int:
    test_repository_frontend_product_has_a_ghostty_free_closure()
    test_source_policy_rejects_ghostty_and_dynamic_loading()
    test_product_closure_rejects_legacy_targets_even_without_forbidden_imports()
    test_artifact_attestation_binds_graph_to_recursive_host_load_closure()
    print("PASS: backend-only product graph and host artifact are bound")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
