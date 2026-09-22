#!/usr/bin/env python3
"""Validate and relocate the app-host test products passed between CI jobs."""

from __future__ import annotations

import json
import os
import platform
import plistlib
import subprocess
import sys
from pathlib import Path

SCHEMES = {"cmux": "CMUX_UI_XCTESTRUN", "cmux-unit": "CMUX_APP_HOST_XCTESTRUN", "cmux-numeric-locale": "CMUX_NUMERIC_LOCALE_XCTESTRUN"}
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


def manifests(products: Path) -> dict[str, Path]:
    """Require one test manifest for each scheme, never silently select an old one."""
    found = {}
    for scheme in SCHEMES:
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


def validate_manifest(value, products: Path) -> None:
    """Prove that the relocated manifest references an existing app and test bundle."""
    found = list(targets(value))
    if not found:
        raise ValueError("test manifest contains no test targets")
    for target in found:
        host = target.get("TestHostPath", "").replace("__TESTROOT__", str(products))
        bundle = target["TestBundlePath"].replace("__TESTROOT__", str(products)).replace("__TESTHOST__", host)
        paths = [("host", host), ("bundle", bundle)]
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
    for key in ("revision", "xcode", "architecture"):
        if receipt.get(key) != current[key]:
            raise ValueError(f"test products {key} does not match this job")
    replacements = [(receipt["derived"], str(derived.resolve()))]
    replacements += [(receipt[key], current[key]) for key in ("checkout", "developer")]
    outputs = {}
    for scheme, manifest in manifests(products).items():
        value = map_strings(plistlib.loads(manifest.read_bytes()), replacements)
        validate_manifest(value, products)
        manifest.write_bytes(plistlib.dumps(value))
        outputs[SCHEMES[scheme]] = str(manifest.resolve())
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
