#!/usr/bin/env python3
"""Stage the production navigation policy and its value closure for standalone SwiftPM tests.

This is a test fixture, not a shipping package or a replacement for app integration.
The temporary package contains verbatim production declarations and the same fake-capability
tests wired into cmuxTests. It makes the remaining value-package prerequisite explicit while
proving that navigation no longer needs app/window/catalog implementations to execute.
"""

import hashlib
import json
from pathlib import Path


def main():
    root = Path(__file__).resolve().parent.parent
    output = root / ".local" / "cloud-navigation-probe"
    sources = output / "Sources" / "CloudNavigationProbe"
    tests = output / "Tests" / "CloudNavigationProbeTests"
    sources.mkdir(parents=True, exist_ok=True)
    tests.mkdir(parents=True, exist_ok=True)
    manifest = []

    def stage(path, declaration=None, test=False):
        text = (root / path).read_text()
        if declaration:
            # These known value declarations use a column-zero closing brace. Refuse
            # changed declaration anchors instead of silently staging another type.
            start = text.index(declaration)
            end = text.index("\n}", start) + 2
            content = "import Foundation\n\n" + text[start:end] + "\n"
            name = declaration.split(":")[0].split()[-1] + ".swift"
        else:
            content = text
            name = Path(path).name
        if test:
            start = content.index("#if canImport(cmux_DEV)")
            end = content.index("#endif", start) + len("#endif")
            content = content[:start] + "@testable import CloudNavigationProbe" + content[end:]
        target = (tests if test else sources) / name
        # Preserve timestamps for controlled body/interface edit comparisons.
        if not target.exists() or target.read_text() != content:
            target.write_text(content)
        manifest.append({"source": path, "declaration": declaration,
                         "source_sha256": hashlib.sha256(text.encode()).hexdigest(),
                         "staged_sha256": hashlib.sha256(content.encode()).hexdigest()})

    for name in ["CloudTreeTerminalNavigationCoordinator", "CloudTerminalNavigationCatalog",
                 "CloudTerminalNavigationHost", "CloudTerminalNavigationScheduling",
                 "SurfaceResourceGroup+CloudNavigation"]:
        stage(f"Sources/Cloud/{name}.swift")
    stage("Packages/macOS/CmuxSurfaceCatalogModel/Sources/CmuxSurfaceCatalogModel/SurfaceMachineID.swift", "enum SurfaceMachineID:")
    for kind, name in [("enum", "SurfaceResourceKind"),
                       ("enum", "SurfaceLifecycle"), ("struct", "SurfaceAgentBadge"),
                       ("struct", "CloudCreationAttachment"), ("struct", "SurfaceResource"),
                       ("struct", "SurfaceResourceID"), ("struct", "SurfaceRemoteWorkspace"),
                       ("struct", "SurfaceRemoteView"), ("struct", "SurfaceProjection"),
                       ("enum", "SurfaceSplitDirection"), ("enum", "SurfaceCatalogError")]:
        stage("Packages/macOS/CmuxSurfaceCatalogModel/Sources/CmuxSurfaceCatalogModel/SurfaceCatalogModel.swift", f"{kind} {name}:")
    stage("Packages/macOS/CmuxSurfaceCatalogModel/Sources/CmuxSurfaceCatalogModel/SurfaceResourcePlacement.swift")
    stage("Sources/Surfaces/SurfaceCatalog+Groups.swift", "struct SurfaceResourceGroup:")
    stage("Sources/Surfaces/CloudWorkspaceLayoutTranslator.swift", "indirect enum SurfaceProjectionLayout:")
    for name in ["CloudTerminalNavigationFixture", "CloudTerminalNavigationCapabilityTests"]:
        stage(f"cmuxTests/{name}.swift", test=True)
    package = '''// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "CloudNavigationProbe",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "CloudNavigationProbe", swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "CloudNavigationProbeTests", dependencies: ["CloudNavigationProbe"])
    ]
)
'''
    package_path = output / "Package.swift"
    if not package_path.exists() or package_path.read_text() != package:
        package_path.write_text(package)
    (output / "sources.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"Staged {len(manifest)} production/test inputs at {output.relative_to(root)}")
    print("Run SwiftPM tests through the native build owner; this fixture does not validate app/CLI linkage.")


if __name__ == "__main__":
    main()
