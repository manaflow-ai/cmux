#!/usr/bin/env python3
"""Validate and relocate the app-host test products passed between CI jobs."""

from __future__ import annotations

import json
import os
import platform
import plistlib
import re
import subprocess
import sys
from pathlib import Path

# Run directly by CI and loaded by path from tests; keep the sibling import
# working under both.
sys.path.insert(0, str(Path(__file__).resolve().parent))

import product_input_identity as product_inputs  # noqa: E402

SCHEME_OUTPUTS = {
    "cmux": "CMUX_UI_XCTESTRUN",
    "cmux-unit": "CMUX_APP_HOST_XCTESTRUN",
    # cmuxCLITests has no app host: its bundle is loaded by the platform's own
    # xctest agent, so the manifest names no product as its test host.
    "cmux-cli-tests": "CMUX_CLI_TESTS_XCTESTRUN",
}
OUTPUT_ALIASES = {
    "CMUX_NUMERIC_LOCALE_XCTESTRUN": "CMUX_APP_HOST_XCTESTRUN",
}
RECEIPT = "cmux-test-products.json"


def identity() -> dict[str, str]:
    """Bind the products to their source revision, architecture, and Xcode build."""
    def read(*args: str) -> str:
        return subprocess.check_output(args, text=True).strip()

    return {
        "revision": read("git", "rev-parse", "HEAD"),
        "xcode": read("xcodebuild", "-version"),
        "architecture": platform.machine(),
        "developer": os.environ.get("DEVELOPER_DIR") or read("xcode-select", "-p"),
        "checkout": str(Path.cwd().resolve()),
    }


def xcode_major(version: str | None) -> str | None:
    """The major Xcode version from `xcodebuild -version`, e.g. "26".

    Output that does not parse is compared whole.
    """
    match = re.match(r"Xcode (\d+)(?:\.|\s|$)", version or "")
    return match.group(1) if match else version


def xcode_release(version: str | None) -> tuple[int, ...] | None:
    """The numeric Xcode release from `xcodebuild -version`, e.g. (26, 6)."""
    match = re.match(r"Xcode (\d+(?:\.\d+)*)", version or "")
    return tuple(int(part) for part in match.group(1).split(".")) if match else None


def check_xcode(produced: str | None, current: str) -> None:
    """Refuse products this job's Xcode cannot load.

    A test bundle imports Testing.framework and XCTest symbols from the Xcode
    that linked it, and an older Xcode's frameworks can lack them: a bundle
    linked by 26.6 fails to dlopen under 26.3 before running any test. A
    different major is refused outright; within one major, this job's Xcode
    must be at least the producer's.
    """
    if xcode_major(produced) != xcode_major(current):
        raise ValueError("test products xcode does not match this job")
    built, running = xcode_release(produced), xcode_release(current)
    if built and running and running < built:
        def name(version: str | None) -> str:
            return (version or "").splitlines()[0] if version else "unknown"

        raise ValueError(
            f"test products xcode is {name(produced)}, newer than this job's {name(current)}; "
            "its test bundle cannot load here. Run this job on compile admission's pool with its Xcode."
        )


def manifests(products: Path) -> dict[str, Path]:
    """Require one test manifest per scheme the active profile builds.

    Exactly the profile's schemes, never a subset: a product missing a manifest
    its key claims is a partial product, and a consumer restoring it would test
    something that was never built. The scheme set comes from PRODUCT_PROFILES
    so this check and the build cannot disagree.
    """
    found = {}
    for scheme in product_inputs.profile_schemes():
        matches = list(products.glob(f"{scheme}_*.xctestrun"))
        if len(matches) != 1:
            raise ValueError(f"expected one {scheme} test manifest, found {len(matches)}")
        found[scheme] = matches[0]
    return found


def map_strings(value, replacements: list[tuple[str, str]]):
    """Relocate manifest strings while retaining Xcode's TESTROOT placeholders."""
    if isinstance(value, dict):
        return {key: map_strings(item, replacements) for key, item in value.items()}
    if isinstance(value, list):
        return [map_strings(item, replacements) for item in value]
    if isinstance(value, str):
        for old, new in replacements:
            value = value.replace(old + "/", new + "/") if old != new else value
            if value == old:
                value = new
    return value


def targets(value):
    """Read targets from both classic and TestConfigurations xctestrun formats."""
    if isinstance(value, dict):
        if "TestBundlePath" in value:
            yield value
        for item in value.values():
            yield from targets(item)
    elif isinstance(value, list):
        for item in value:
            yield from targets(item)


def hosted_by_product(target) -> bool:
    """False when the platform's xctest agent loads the bundle directly.

    A unit-test target without TEST_HOST is hosted by
    __PLATFORMS__/.../Agents/xctest, which lives inside Xcode and not inside
    Build/Products. Such a target has no product test host to validate, only a
    bundle.
    """
    host = target.get("TestHostPath", "")
    return bool(host) and "__PLATFORMS__" not in host


def validate_manifest(value, products: Path) -> None:
    """Prove that the relocated manifest references an existing app and test bundle."""
    found = list(targets(value))
    if not found:
        raise ValueError("test manifest contains no test targets")
    for target in found:
        host = target.get("TestHostPath", "").replace("__TESTROOT__", str(products))
        bundle = target["TestBundlePath"].replace("__TESTROOT__", str(products)).replace("__TESTHOST__", host)
        paths = [("host", host), ("bundle", bundle)] if hosted_by_product(target) else [("bundle", bundle)]
        if "UITargetAppPath" in target:
            app = target["UITargetAppPath"].replace("__TESTROOT__", str(products))
            paths.append(("UI target app", app))
        for label, raw_path in paths:
            path = Path(raw_path).resolve()
            if not raw_path or products.resolve() not in path.parents or not path.exists():
                raise ValueError(f"missing or unscoped test {label}: {raw_path}")


def stamp(derived: Path, current: dict[str, str]) -> None:
    """Validate producer output and record where the manifests were generated."""
    products = derived / "Build" / "Products"
    for manifest in manifests(products).values():
        validate_manifest(plistlib.loads(manifest.read_bytes()), products)
    (products / RECEIPT).write_text(json.dumps({**current, "derived": str(derived.resolve())}))


def restore(derived: Path, current: dict[str, str]) -> dict[str, str]:
    """Reject mismatched products and relocate each test manifest for this worker."""
    products = derived / "Build" / "Products"
    receipt = json.loads((products / RECEIPT).read_text())
    for key in ("revision", "architecture"):
        if receipt.get(key) != current[key]:
            raise ValueError(f"test products {key} does not match this job")
    check_xcode(receipt.get("xcode"), current["xcode"])
    replacements = [(receipt["derived"], str(derived.resolve()))]
    replacements += [(receipt[key], current[key]) for key in ("checkout", "developer")]
    outputs = {}
    for scheme, manifest in manifests(products).items():
        value = map_strings(plistlib.loads(manifest.read_bytes()), replacements)
        validate_manifest(value, products)
        manifest.write_bytes(plistlib.dumps(value))
        outputs[SCHEME_OUTPUTS[scheme]] = str(manifest.resolve())
    # The numeric-locale gate selects only GhosttyNumericLocaleTests and
    # disables parallel testing at invocation time. Its scheme has the same
    # app/test product contract as cmux-unit; tests lock that equivalence.
    # A profile without cmux-unit (the cli profile) has no numeric-locale gate.
    for alias, source in OUTPUT_ALIASES.items():
        if source in outputs:
            outputs[alias] = outputs[source]
    return outputs


def main() -> None:
    """Stamp or restore a trusted artifact downloaded by its workflow artifact ID."""
    if len(sys.argv) != 3 or sys.argv[1] not in {"stamp", "restore"}:
        raise SystemExit("usage: app_host_test_products.py stamp|restore DERIVED_DATA")
    derived = Path(sys.argv[2]).resolve()
    current = identity()
    if sys.argv[1] == "stamp":
        stamp(derived, current)
    else:
        outputs = restore(derived, current)
        with Path(os.environ["GITHUB_ENV"]).open("a") as output:
            for name, value in outputs.items():
                output.write(f"{name}={value}\n")
    print(f"Validated app-host test products for {current['revision']}")


if __name__ == "__main__":
    main()
