#!/usr/bin/env python3
"""Deterministic guards for the Ghostty-free macOS frontend product."""

from __future__ import annotations

import json
import importlib.util
import os
import plistlib
import re
import stat
import subprocess
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
VERIFIER = ROOT / "scripts" / "verify-cmux-backend-only-product.py"
TERMINAL_PACKAGE = ROOT / "Packages/macOS/CmuxTerminal"
TERMINAL_DOMAIN_CONTRACT = (
    ROOT
    / "Packages/macOS/CmuxTerminalCore"
    / "Sources/CmuxTerminalDomain/Runtime/TerminalExternalRuntime.swift"
)
FRONTEND_EXPORT_TEST = (
    TERMINAL_PACKAGE
    / "Tests/CmuxTerminalFrontendTests/TerminalFrontendDomainExportTests.swift"
)
FRONTEND_DOMAIN_EXPORTS = (
    TERMINAL_PACKAGE
    / "Sources/CmuxTerminalFrontend/Exports/CmuxTerminalDomainExports.swift"
)


def load_verifier_module():
    spec = importlib.util.spec_from_file_location("cmux_backend_only_verifier", VERIFIER)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


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
    frameworks = app / "Contents/Frameworks"
    frameworks.mkdir(parents=True)
    executable = macos / "cmux"
    debug_library = macos / "cmux.debug.dylib"
    nucleo_library = frameworks / "libcmux_command_palette_nucleo_ffi.dylib"
    executable.write_bytes(b"host fixture\n")
    debug_library.write_bytes(b"debug fixture\n")
    nucleo_library.write_bytes(b"nucleo fixture\n")
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
        """mode="${CMUX_PRODUCT_GRAPH_FIXTURE:-clean}"
if [[ "$mode" == "allowed-host-loaders" && "$2" == */MacOS/* ]]; then
  printf '                 U _dlopen\n'
  printf '                 U _dlsym\n'
  printf '                 U _dlclose\n'
elif [[ "$mode" == "unsupported-host-loader" && "$2" == */MacOS/* ]]; then
  printf '                 U _dlmopen\n'
elif [[ "$mode" == "nucleo-loader" && "$2" == */libcmux_command_palette_nucleo_ffi.dylib ]]; then
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
    domain_sources = next(
        source_root
        for source_root in report["source_roots"]
        if source_root["target"] == "CmuxTerminalDomain"
    )
    assert "Runtime/TerminalExternalRuntime.swift" in {
        source["path"] for source in domain_sources["files"]
    }
    assert TERMINAL_DOMAIN_CONTRACT.is_file()

    contract_source = TERMINAL_DOMAIN_CONTRACT.read_text(encoding="utf-8")
    contract_types = set(
        re.findall(
            r"(?m)^public (?:struct|enum|protocol) (Terminal(?:External|Accessibility)\w+)",
            contract_source,
        )
    )
    frontend_alias_source = FRONTEND_DOMAIN_EXPORTS.read_text(encoding="utf-8")
    frontend_aliases = dict(
        re.findall(
            r"(?m)^public typealias (Terminal(?:External|Accessibility)\w+)\s*=\s*"
            r"CmuxTerminalDomain\.(Terminal(?:External|Accessibility)\w+)",
            frontend_alias_source,
        )
    )
    assert len(contract_types) == 40
    assert frontend_aliases == {name: name for name in contract_types}

    export_test = FRONTEND_EXPORT_TEST.read_text(encoding="utf-8")
    imported_modules = {
        line.split()[1]
        for line in export_test.splitlines()
        if line.startswith("import ")
    }
    assert imported_modules == {"CmuxTerminalFrontend", "Testing"}
    exported_value_types = set(
        re.findall(
            r"(?m)^\s+(Terminal(?:External|Accessibility)\w+)\.self,?$",
            export_test,
        )
    )
    assert exported_value_types == contract_types - {
        "TerminalExternalPresentationLease",
        "TerminalExternalRuntime",
    }
    assert "any TerminalExternalPresentationLease" in export_test
    assert "any TerminalExternalRuntime" in export_test
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
            "Contents/Frameworks/libcmux_command_palette_nucleo_ffi.dylib",
        }
        assert artifact["load_edges"] == [
            {
                "from": "Contents/MacOS/cmux",
                "load": "@rpath/cmux.debug.dylib",
                "to": "Contents/MacOS/cmux.debug.dylib",
            }
        ]
        assert artifact["sanctioned_dynamic_loads"] == [
            "Contents/Frameworks/libcmux_command_palette_nucleo_ffi.dylib"
        ]
        assert {item["path"] for item in artifact["dynamic_load_sources"]} == {
            "Sources/SystemCommandRunner.swift",
            (
                "Packages/macOS/CmuxCommandPalette/Sources/CmuxCommandPalette/Search/"
                "Nucleo/CommandPaletteNucleoSearchLibrary.swift"
            ),
        }
        assert len(artifact["attestation_sha256"]) == 64

        environment["CMUX_PRODUCT_GRAPH_FIXTURE"] = "allowed-host-loaders"
        result = run_verifier(package, "--app-bundle", str(app), environment=environment)
        assert result.returncode == 0, result.stderr

        environment["CMUX_PRODUCT_GRAPH_FIXTURE"] = "unsupported-host-loader"
        result = run_verifier(package, "--app-bundle", str(app), environment=environment)
        assert result.returncode != 0
        assert "unapproved dynamic-load symbols: _dlmopen" in result.stderr

        environment["CMUX_PRODUCT_GRAPH_FIXTURE"] = "nucleo-loader"
        result = run_verifier(package, "--app-bundle", str(app), environment=environment)
        assert result.returncode != 0
        assert "unapproved dynamic-load symbols: _dlopen" in result.stderr


def test_dynamic_load_source_policy_is_exact_and_hash_bound() -> None:
    verifier = load_verifier_module()
    with tempfile.TemporaryDirectory() as temporary_directory:
        root = Path(temporary_directory)
        allowed = root / "Sources/AllowedLoader.swift"
        allowed.parent.mkdir(parents=True)
        allowed.write_text('func load() { _ = dlopen("/system", 0) }\n', encoding="utf-8")
        allowed_hash = verifier.sha256_file(allowed)

        verifier.REPOSITORY_ROOT = root
        verifier.ALLOWED_DYNAMIC_LOAD_SOURCES = {
            "Sources/AllowedLoader.swift": allowed_hash,
        }
        report = verifier.verify_dynamic_load_source_policy()
        assert report == [
            {"path": "Sources/AllowedLoader.swift", "sha256": allowed_hash}
        ]

        allowed.write_text('func load() { _ = dlopen("/changed", 0) }\n', encoding="utf-8")
        try:
            verifier.verify_dynamic_load_source_policy()
        except verifier.VerificationError as error:
            assert "reviewed dynamic-load source changed" in str(error)
        else:
            raise AssertionError("changed loader source was accepted")

        unexpected = root / "Sources/UnexpectedLoader.swift"
        unexpected.write_text('func load() { _ = dlsym(nil, "escape") }\n', encoding="utf-8")
        try:
            verifier.verify_dynamic_load_source_policy()
        except verifier.VerificationError as error:
            assert "unreviewed dynamic-load callsites" in str(error)
        else:
            raise AssertionError("unreviewed loader source was accepted")


def main() -> int:
    test_repository_frontend_product_has_a_ghostty_free_closure()
    test_source_policy_rejects_ghostty_and_dynamic_loading()
    test_product_closure_rejects_legacy_targets_even_without_forbidden_imports()
    test_artifact_attestation_binds_graph_to_recursive_host_load_closure()
    test_dynamic_load_source_policy_is_exact_and_hash_bound()
    print("PASS: backend-only product graph and host artifact are bound")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
