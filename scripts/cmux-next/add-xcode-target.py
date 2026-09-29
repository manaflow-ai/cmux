#!/usr/bin/env python3
"""Add the `cmux-next` app target to cmux.xcodeproj (plans/cmux-next/shell.md 1.3).

Additive text edit of project.pbxproj so the diff stays small and rebases onto
main without conflicts. Never let Xcode re-save the project on this branch: it
would rewrite the file to a newer objectVersion.

The target compiles only App/main.swift and links the CmuxNextApp product of
Packages/macOS/CmuxNext plus GhosttyKit.xcframework. Its Debug/Release build
configurations are copied from the legacy `cmux` target (A5001082/A5001083) so
PRODUCT_NAME, bundle IDs, Info.plist, and entitlements match what
scripts/reload.sh and cmux-ci expect. Only the deployment target, Swift
version, and bridging header differ.

Idempotent: exits 0 without changes when the target already exists.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PBXPROJ = ROOT / "cmux.xcodeproj" / "project.pbxproj"


def oid(n: int) -> str:
    return f"CE7A{n:020X}"


FILE_MAIN = oid(1)
BF_MAIN = oid(2)
GROUP_APP = oid(3)
PRODUCT = oid(4)
TARGET = oid(5)
CONFIG_LIST = oid(6)
CFG_DEBUG = oid(7)
CFG_RELEASE = oid(8)
PHASE_SOURCES = oid(9)
PHASE_FRAMEWORKS = oid(10)
PHASE_RESOURCES = oid(11)
PHASE_COPY_CLI = oid(12)
PHASE_REJECT = oid(13)
BF_CLI = oid(14)
DEP_CLI = oid(15)
PROXY_CLI = oid(16)
BF_GHOSTTY = oid(17)
BF_PKG = oid(18)
PKG_REF = oid(19)
PRODUCT_DEP = oid(20)
BF_ASSETS = oid(21)
PHASE_BUNDLE_TUI = oid(22)
PHASE_EMBED_CEF = oid(23)

# Existing objects reused by reference.
LEGACY_DEBUG = "A5001082"
LEGACY_RELEASE = "A5001083"
CLI_TARGET = "B9000005A1B2C3D4E5F60719"
CLI_PRODUCT = "B9000004A1B2C3D4E5F60719"
GHOSTTY_XCFRAMEWORK = "A5001016"
ASSETS = "A5001101"
PROJECT = "A5001070"
MAIN_GROUP = "A5001040"
PRODUCTS_GROUP = "A5001042"
LEGACY_REJECT = "A9E030000000000000000009"


def insert_before(text: str, marker: str, block: str) -> str:
    index = text.index(marker)
    return text[:index] + block + text[index:]


def object_block(text: str, object_id: str, comment: str) -> str:
    """Return the full `\t\tID /* comment */ = {...};\n` block for an object."""
    start = text.index(f"\t\t{object_id} /* {comment} */ = {{\n")
    end = text.index("\n\t\t};\n", start) + len("\n\t\t};\n")
    return text[start:end]


def append_to_list(text: str, owner_marker: str, list_key: str, entry: str) -> str:
    """Append `entry` to the `list_key = (` list inside the object starting at owner_marker."""
    owner = text.index(owner_marker)
    list_start = text.index(f"\t{list_key} = (\n", owner)
    close = text.index("\t\t\t);\n", list_start)
    return text[:close] + entry + text[close:]


def derive_config(block: str, legacy_id: str, new_id: str) -> str:
    block = block.replace(f"\t\t{legacy_id} /* ", f"\t\t{new_id} /* ", 1)
    block = re.sub(r"\t\t\t\tSWIFT_OBJC_BRIDGING_HEADER = [^\n]*\n", "", block)
    block = re.sub(r"\t\t\t\tSWIFT_OBJC_INTERFACE_HEADER_NAME = [^\n]*\n", "", block)
    block = re.sub(r"SWIFT_VERSION = [^;]*;", "SWIFT_VERSION = 6.0;", block)
    assert "MACOSX_DEPLOYMENT_TARGET" not in block
    block = block.replace(
        "\t\t\t\tMARKETING_VERSION =",
        "\t\t\t\tMACOSX_DEPLOYMENT_TARGET = 26.0;\n\t\t\t\tMARKETING_VERSION =",
        1,
    )
    return block


def add_bundle_tui_phase(text: str) -> str:
    """Add the "Bundle cmux-tui" script phase (scripts/cmux-next/bundle-cmux-tui.sh).

    Idempotent on its own, so it also upgrades projects that already have
    the target from an earlier run of this script.
    """
    if PHASE_BUNDLE_TUI in text:
        return text
    text = insert_before(text, "/* End PBXShellScriptBuildPhase section */", (
        f"\t\t{PHASE_BUNDLE_TUI} /* Bundle cmux-tui */ = {{\n"
        "\t\t\tisa = PBXShellScriptBuildPhase;\n"
        "\t\t\talwaysOutOfDate = 1;\n"
        "\t\t\tbuildActionMask = 2147483647;\n"
        "\t\t\tfiles = (\n"
        "\t\t\t);\n"
        "\t\t\tinputFileListPaths = (\n"
        "\t\t\t);\n"
        "\t\t\tinputPaths = (\n"
        "\t\t\t);\n"
        "\t\t\tname = \"Bundle cmux-tui\";\n"
        "\t\t\toutputFileListPaths = (\n"
        "\t\t\t);\n"
        "\t\t\toutputPaths = (\n"
        "\t\t\t);\n"
        "\t\t\trunOnlyForDeploymentPostprocessing = 0;\n"
        "\t\t\tshellPath = /bin/sh;\n"
        "\t\t\tshellScript = \"exec \\\"${SRCROOT}/scripts/cmux-next/bundle-cmux-tui.sh\\\"\\n\";\n"
        "\t\t};\n"
    ))
    return append_to_list(
        text,
        f"\t\t{TARGET} /* cmux-next */ = {{\n",
        "buildPhases",
        f"\t\t\t\t{PHASE_BUNDLE_TUI} /* Bundle cmux-tui */,\n",
    )


def add_embed_cef_phase(text: str) -> str:
    """Add the "Embed CEF" script phase (scripts/cmux-next/embed-cef.sh).

    Idempotent. The phase embeds the Chromium framework, the CEF shim, and
    the helper apps only when the pinned artifact is available.
    """
    if PHASE_EMBED_CEF in text:
        return text
    text = insert_before(text, "/* End PBXShellScriptBuildPhase section */", (
        f"\t\t{PHASE_EMBED_CEF} /* Embed CEF */ = {{\n"
        "\t\t\tisa = PBXShellScriptBuildPhase;\n"
        "\t\t\talwaysOutOfDate = 1;\n"
        "\t\t\tbuildActionMask = 2147483647;\n"
        "\t\t\tfiles = (\n"
        "\t\t\t);\n"
        "\t\t\tinputFileListPaths = (\n"
        "\t\t\t);\n"
        "\t\t\tinputPaths = (\n"
        "\t\t\t);\n"
        "\t\t\tname = \"Embed CEF\";\n"
        "\t\t\toutputFileListPaths = (\n"
        "\t\t\t);\n"
        "\t\t\toutputPaths = (\n"
        "\t\t\t);\n"
        "\t\t\trunOnlyForDeploymentPostprocessing = 0;\n"
        "\t\t\tshellPath = /bin/sh;\n"
        "\t\t\tshellScript = \"exec \\\"${SRCROOT}/scripts/cmux-next/embed-cef.sh\\\"\\n\";\n"
        "\t\t};\n"
    ))
    return append_to_list(
        text,
        f"\t\t{TARGET} /* cmux-next */ = {{\n",
        "buildPhases",
        f"\t\t\t\t{PHASE_EMBED_CEF} /* Embed CEF */,\n",
    )


def main() -> int:
    text = PBXPROJ.read_text()
    if TARGET in text:
        upgraded = add_embed_cef_phase(add_bundle_tui_phase(text))
        if upgraded == text:
            print("cmux-next target already present; nothing to do")
        else:
            PBXPROJ.write_text(upgraded)
            print("upgraded cmux-next target phases (Bundle cmux-tui, Embed CEF)")
        return 0
    for n in range(1, 24):
        assert oid(n) not in text, f"ID collision: {oid(n)}"

    text = insert_before(text, "/* End PBXBuildFile section */", "".join([
        f"\t\t{BF_MAIN} /* main.swift in Sources */ = {{isa = PBXBuildFile; fileRef = {FILE_MAIN} /* main.swift */; }};\n",
        f"\t\t{BF_CLI} /* cmux in Copy CLI */ = {{isa = PBXBuildFile; fileRef = {CLI_PRODUCT} /* cmux */; }};\n",
        f"\t\t{BF_GHOSTTY} /* GhosttyKit.xcframework in Frameworks */ = {{isa = PBXBuildFile; fileRef = {GHOSTTY_XCFRAMEWORK} /* GhosttyKit.xcframework */; }};\n",
        f"\t\t{BF_PKG} /* CmuxNextApp in Frameworks */ = {{isa = PBXBuildFile; productRef = {PRODUCT_DEP} /* CmuxNextApp */; }};\n",
        f"\t\t{BF_ASSETS} /* Assets.xcassets in Resources */ = {{isa = PBXBuildFile; fileRef = {ASSETS} /* Assets.xcassets */; }};\n",
    ]))

    text = insert_before(text, "/* End PBXContainerItemProxy section */", (
        f"\t\t{PROXY_CLI} /* PBXContainerItemProxy */ = {{\n"
        "\t\t\tisa = PBXContainerItemProxy;\n"
        f"\t\t\tcontainerPortal = {PROJECT} /* Project object */;\n"
        "\t\t\tproxyType = 1;\n"
        f"\t\t\tremoteGlobalIDString = {CLI_TARGET};\n"
        "\t\t\tremoteInfo = \"cmux-cli\";\n"
        "\t\t};\n"
    ))

    text = insert_before(text, "/* End PBXCopyFilesBuildPhase section */", (
        f"\t\t{PHASE_COPY_CLI} /* Copy CLI */ = {{\n"
        "\t\t\tisa = PBXCopyFilesBuildPhase;\n"
        "\t\t\tbuildActionMask = 2147483647;\n"
        "\t\t\tdstPath = bin;\n"
        "\t\t\tdstSubfolderSpec = 7;\n"
        "\t\t\tfiles = (\n"
        f"\t\t\t\t{BF_CLI} /* cmux in Copy CLI */,\n"
        "\t\t\t);\n"
        "\t\t\tname = \"Copy CLI\";\n"
        "\t\t\trunOnlyForDeploymentPostprocessing = 0;\n"
        "\t\t};\n"
    ))

    text = insert_before(text, "/* End PBXFileReference section */", "".join([
        f"\t\t{FILE_MAIN} /* main.swift */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = main.swift; sourceTree = \"<group>\"; }};\n",
        f"\t\t{PRODUCT} /* cmux-next.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = \"cmux-next.app\"; sourceTree = BUILT_PRODUCTS_DIR; }};\n",
    ]))

    text = insert_before(text, "/* End PBXFrameworksBuildPhase section */", (
        f"\t\t{PHASE_FRAMEWORKS} /* Frameworks */ = {{\n"
        "\t\t\tisa = PBXFrameworksBuildPhase;\n"
        "\t\t\tbuildActionMask = 2147483647;\n"
        "\t\t\tfiles = (\n"
        f"\t\t\t\t{BF_PKG} /* CmuxNextApp in Frameworks */,\n"
        f"\t\t\t\t{BF_GHOSTTY} /* GhosttyKit.xcframework in Frameworks */,\n"
        "\t\t\t);\n"
        "\t\t\trunOnlyForDeploymentPostprocessing = 0;\n"
        "\t\t};\n"
    ))

    text = insert_before(text, "/* End PBXGroup section */", (
        f"\t\t{GROUP_APP} /* App */ = {{\n"
        "\t\t\tisa = PBXGroup;\n"
        "\t\t\tchildren = (\n"
        f"\t\t\t\t{FILE_MAIN} /* main.swift */,\n"
        "\t\t\t);\n"
        "\t\t\tpath = App;\n"
        "\t\t\tsourceTree = \"<group>\";\n"
        "\t\t};\n"
    ))
    text = append_to_list(text, f"\t\t{MAIN_GROUP} = {{\n", "children", f"\t\t\t\t{GROUP_APP} /* App */,\n")
    text = append_to_list(text, f"\t\t{PRODUCTS_GROUP} /* Products */ = {{\n", "children", f"\t\t\t\t{PRODUCT} /* cmux-next.app */,\n")

    text = insert_before(text, "/* End PBXNativeTarget section */", (
        f"\t\t{TARGET} /* cmux-next */ = {{\n"
        "\t\t\tisa = PBXNativeTarget;\n"
        f"\t\t\tbuildConfigurationList = {CONFIG_LIST} /* Build configuration list for PBXNativeTarget \"cmux-next\" */;\n"
        "\t\t\tbuildPhases = (\n"
        f"\t\t\t\t{PHASE_SOURCES} /* Sources */,\n"
        f"\t\t\t\t{PHASE_FRAMEWORKS} /* Frameworks */,\n"
        f"\t\t\t\t{PHASE_RESOURCES} /* Resources */,\n"
        f"\t\t\t\t{PHASE_COPY_CLI} /* Copy CLI */,\n"
        f"\t\t\t\t{PHASE_REJECT} /* Reject Bundled Provider Binaries */,\n"
        "\t\t\t);\n"
        "\t\t\tbuildRules = (\n"
        "\t\t\t);\n"
        "\t\t\tdependencies = (\n"
        f"\t\t\t\t{DEP_CLI} /* PBXTargetDependency */,\n"
        "\t\t\t);\n"
        "\t\t\tname = \"cmux-next\";\n"
        "\t\t\tpackageProductDependencies = (\n"
        f"\t\t\t\t{PRODUCT_DEP} /* CmuxNextApp */,\n"
        "\t\t\t);\n"
        "\t\t\tproductName = \"cmux-next\";\n"
        f"\t\t\tproductReference = {PRODUCT} /* cmux-next.app */;\n"
        "\t\t\tproductType = \"com.apple.product-type.application\";\n"
        "\t\t};\n"
    ))

    text = append_to_list(text, f"\t\t{PROJECT} /* Project object */ = {{\n", "targets", f"\t\t\t\t{TARGET} /* cmux-next */,\n")
    text = append_to_list(
        text,
        f"\t\t{PROJECT} /* Project object */ = {{\n",
        "packageReferences",
        f"\t\t\t\t{PKG_REF} /* XCLocalSwiftPackageReference \"Packages/macOS/CmuxNext\" */,\n",
    )

    text = insert_before(text, "/* End PBXResourcesBuildPhase section */", (
        f"\t\t{PHASE_RESOURCES} /* Resources */ = {{\n"
        "\t\t\tisa = PBXResourcesBuildPhase;\n"
        "\t\t\tbuildActionMask = 2147483647;\n"
        "\t\t\tfiles = (\n"
        f"\t\t\t\t{BF_ASSETS} /* Assets.xcassets in Resources */,\n"
        "\t\t\t);\n"
        "\t\t\trunOnlyForDeploymentPostprocessing = 0;\n"
        "\t\t};\n"
    ))

    reject = object_block(text, LEGACY_REJECT, "Reject Bundled Provider Binaries")
    text = insert_before(
        text,
        "/* End PBXShellScriptBuildPhase section */",
        reject.replace(f"\t\t{LEGACY_REJECT} /* ", f"\t\t{PHASE_REJECT} /* ", 1),
    )

    text = insert_before(text, "/* End PBXSourcesBuildPhase section */", (
        f"\t\t{PHASE_SOURCES} /* Sources */ = {{\n"
        "\t\t\tisa = PBXSourcesBuildPhase;\n"
        "\t\t\tbuildActionMask = 2147483647;\n"
        "\t\t\tfiles = (\n"
        f"\t\t\t\t{BF_MAIN} /* main.swift in Sources */,\n"
        "\t\t\t);\n"
        "\t\t\trunOnlyForDeploymentPostprocessing = 0;\n"
        "\t\t};\n"
    ))

    text = insert_before(text, "/* End PBXTargetDependency section */", (
        f"\t\t{DEP_CLI} /* PBXTargetDependency */ = {{\n"
        "\t\t\tisa = PBXTargetDependency;\n"
        f"\t\t\ttarget = {CLI_TARGET} /* cmux-cli */;\n"
        f"\t\t\ttargetProxy = {PROXY_CLI} /* PBXContainerItemProxy */;\n"
        "\t\t};\n"
    ))

    debug = derive_config(object_block(text, LEGACY_DEBUG, "Debug"), LEGACY_DEBUG, CFG_DEBUG)
    release = derive_config(object_block(text, LEGACY_RELEASE, "Release"), LEGACY_RELEASE, CFG_RELEASE)
    text = insert_before(text, "/* End XCBuildConfiguration section */", debug + release)

    text = insert_before(text, "/* End XCConfigurationList section */", (
        f"\t\t{CONFIG_LIST} /* Build configuration list for PBXNativeTarget \"cmux-next\" */ = {{\n"
        "\t\t\tisa = XCConfigurationList;\n"
        "\t\t\tbuildConfigurations = (\n"
        f"\t\t\t\t{CFG_DEBUG} /* Debug */,\n"
        f"\t\t\t\t{CFG_RELEASE} /* Release */,\n"
        "\t\t\t);\n"
        "\t\t\tdefaultConfigurationIsVisible = 0;\n"
        "\t\t\tdefaultConfigurationName = Release;\n"
        "\t\t};\n"
    ))

    text = insert_before(text, "/* End XCLocalSwiftPackageReference section */", (
        f"\t\t{PKG_REF} /* XCLocalSwiftPackageReference \"Packages/macOS/CmuxNext\" */ = {{\n"
        "\t\t\tisa = XCLocalSwiftPackageReference;\n"
        "\t\t\trelativePath = Packages/macOS/CmuxNext;\n"
        "\t\t};\n"
    ))

    text = insert_before(text, "/* End XCSwiftPackageProductDependency section */", (
        f"\t\t{PRODUCT_DEP} /* CmuxNextApp */ = {{\n"
        "\t\t\tisa = XCSwiftPackageProductDependency;\n"
        f"\t\t\tpackage = {PKG_REF} /* XCLocalSwiftPackageReference \"Packages/macOS/CmuxNext\" */;\n"
        "\t\t\tproductName = CmuxNextApp;\n"
        "\t\t};\n"
    ))

    text = add_embed_cef_phase(add_bundle_tui_phase(text))
    PBXPROJ.write_text(text)
    print(f"added cmux-next target {TARGET}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
