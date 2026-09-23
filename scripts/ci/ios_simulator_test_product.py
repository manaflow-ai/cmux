#!/usr/bin/env python3
"""Stamp, verify, and relocate the same-run iOS Simulator test product."""

from __future__ import annotations

import hashlib
import json
import os
import platform
import plistlib
import re
import shutil
import stat
import subprocess
import sys
from pathlib import Path

RECEIPT = "cmux-ios-test-product.json"
PLATFORM_XCTEST_HOST = "__PLATFORMS__/iPhoneSimulator.platform/Developer/Library/Xcode/Agents/xctest"
PACKAGE_RESOLVED = Path("ios/cmux.xcworkspace/xcshareddata/swiftpm/Package.resolved")
GHOSTTY_CHECKSUMS = Path("scripts/ghosttykit-checksums.txt")
IDENTITY_KEYS = (
    "source_revision",
    "source_tree",
    "xcode",
    "sdk_version",
    "sdk_build_version",
    "architecture",
    "package_resolved_sha256",
    "ghostty_revision",
    "ghosttykit_checksums_sha256",
    "scheme",
    "configuration",
    "build_action",
    "test_plan",
    "test_filter",
    "ios_version",
)


def read(*args: str) -> str:
    return subprocess.check_output(args, text=True).strip()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def identity() -> dict[str, str]:
    developer = os.environ.get("DEVELOPER_DIR") or read("xcode-select", "-p")
    return {
        "source_revision": read("git", "rev-parse", "HEAD"),
        "source_tree": read("git", "rev-parse", "HEAD^{tree}"),
        "xcode": read("xcodebuild", "-version"),
        "sdk_version": read("xcrun", "--sdk", "iphonesimulator", "--show-sdk-version"),
        "sdk_build_version": read("xcrun", "--sdk", "iphonesimulator", "--show-sdk-build-version"),
        "architecture": platform.machine(),
        "package_resolved_sha256": sha256_file(PACKAGE_RESOLVED),
        "ghostty_revision": read("git", "rev-parse", "HEAD:ghostty"),
        "ghosttykit_checksums_sha256": sha256_file(GHOSTTY_CHECKSUMS),
        "scheme": "cmux-ios",
        "configuration": "Debug",
        "build_action": "build-for-testing",
        "test_plan": os.environ.get("CMUX_IOS_TEST_PLAN", ""),
        "test_filter": os.environ.get("CMUX_IOS_TEST_FILTER", ""),
        "ios_version": os.environ.get("CMUX_IOS_VERSION", ""),
        "checkout": str(Path.cwd().resolve()),
        "developer": str(Path(developer).resolve()),
    }


def product_digest(products: Path) -> str:
    """Hash staged product bytes, executable modes, paths, and symlink targets."""
    digest = hashlib.sha256()
    entries = sorted(products.rglob("*"), key=lambda path: path.relative_to(products).as_posix())
    for path in entries:
        relative = path.relative_to(products).as_posix()
        if relative == RECEIPT:
            continue
        info = path.lstat()
        if stat.S_ISDIR(info.st_mode):
            kind = b"D"
            payload_digest = hashlib.sha256(b"").digest()
        elif stat.S_ISLNK(info.st_mode):
            kind = b"L"
            payload_digest = hashlib.sha256(os.readlink(path).encode()).digest()
        elif stat.S_ISREG(info.st_mode):
            kind = b"F"
            payload_digest = bytes.fromhex(sha256_file(path))
        else:
            raise ValueError(f"unsupported product entry: {relative}")
        digest.update(kind + b"\0" + relative.encode() + b"\0")
        digest.update(f"{stat.S_IMODE(info.st_mode):04o}".encode() + b"\0")
        digest.update(payload_digest)
    return digest.hexdigest()


def manifests(products: Path) -> list[Path]:
    found = sorted(products.glob("*.xctestrun"))
    if len(found) != 1:
        raise ValueError(f"expected exactly one .xctestrun, found {len(found)}")
    return found


def map_strings(value, replacements: list[tuple[str, str]]):
    if isinstance(value, dict):
        return {key: map_strings(item, replacements) for key, item in value.items()}
    if isinstance(value, list):
        return [map_strings(item, replacements) for item in value]
    if isinstance(value, str):
        for old, new in replacements:
            if old == new:
                continue
            value = value.replace(old + "/", new + "/")
            if value == old:
                value = new
    return value


def targets(value):
    if isinstance(value, dict):
        if "TestBundlePath" in value:
            yield value
        for item in value.values():
            yield from targets(item)
    elif isinstance(value, list):
        for item in value:
            yield from targets(item)


def expand_path(raw: str, products: Path, host: str = "") -> str:
    return raw.replace("__TESTROOT__", str(products)).replace("__TESTHOST__", host)


def validate_manifest(value, products: Path, developer: Path) -> None:
    found = list(targets(value))
    if not found:
        raise ValueError("test manifest contains no test targets")
    root = products.resolve()
    for target in found:
        raw_host = target.get("TestHostPath", "")
        host = expand_path(raw_host, products)
        candidates: list[tuple[str, str]] = []
        if raw_host == PLATFORM_XCTEST_HOST:
            # Unhosted SwiftPM tests use Xcode's platform runner, not an app
            # inside the product. Preserve the macro for Xcode, but validate
            # the exact executable in this machine's identity-checked toolchain.
            developer_root = developer.resolve()
            runner = (developer_root / "Platforms" / raw_host.removeprefix("__PLATFORMS__/")).resolve()
            if developer_root not in runner.parents:
                raise ValueError(f"unscoped platform test host: {runner}")
            if not runner.is_file() or not os.access(runner, os.X_OK):
                raise ValueError(f"missing or non-executable platform test host: {runner}")
            host = str(runner)
        elif host:
            candidates.append(("host", host))
        bundle = expand_path(target.get("TestBundlePath", ""), products, host)
        candidates.append(("bundle", bundle))
        if target.get("UITargetAppPath"):
            candidates.append(("UI target app", expand_path(target["UITargetAppPath"], products, host)))
        for label, raw in candidates:
            if not raw:
                raise ValueError(f"missing test {label} path")
            path = Path(raw).resolve()
            if path != root and root not in path.parents:
                raise ValueError(f"unscoped test {label}: {raw}")
            if not path.exists():
                raise ValueError(f"missing test {label}: {raw}")


def relocate_manifest(
    manifest: Path, products: Path, replacements: list[tuple[str, str]], developer: Path
) -> None:
    value = map_strings(plistlib.loads(manifest.read_bytes()), replacements)
    validate_manifest(value, products, developer)
    manifest.write_bytes(plistlib.dumps(value))


def prune_compile_products(products: Path) -> dict:
    """Remove only unreferenced loose compiler outputs, never bundle contents."""
    roots = [products] + [
        path for path in products.iterdir()
        if path.is_dir() and not path.is_symlink() and path.name.endswith("-iphonesimulator")
    ]
    candidates = [
        path for root in roots for path in root.iterdir()
        if not path.is_symlink() and (
            (path.is_file() and path.suffix in {".a", ".o"})
            or (path.is_dir() and path.suffix == ".swiftmodule")
        )
    ]

    def strings(value, key=""):
        if isinstance(value, dict):
            for child_key, child in value.items():
                yield from strings(child, child_key)
        elif isinstance(value, list):
            for child in value:
                yield from strings(child, key)
        elif isinstance(value, str):
            yield key, value

    references = list(strings(plistlib.loads(manifests(products)[0].read_bytes())))
    # Resolve only understood manifest syntax before touching any candidate.
    # Unknown macros could hide a reference to a compiler output.
    skipped_reason = None
    for _, raw in references:
        unknown = set(re.findall(r"__[A-Z][A-Z0-9_]*__", raw)) - {
            "__TESTROOT__", "__TESTHOST__", "__PLATFORMS__",
        }
        if candidates and unknown:
            skipped_reason = "unfamiliar manifest macro"
            break
        if candidates and "__TESTROOT__" in raw and any(char in raw for char in "*?["):
            skipped_reason = "wildcard manifest reference"
            break

    loader_search_paths = {
        "DYLD_FRAMEWORK_PATH", "DYLD_LIBRARY_PATH",
        "DYLD_FALLBACK_FRAMEWORK_PATH", "DYLD_FALLBACK_LIBRARY_PATH",
    }

    def referenced(candidate):
        for key, raw in references:
            # Also protect paths in future/unknown fields, command arguments,
            # __TESTHOST__ references and relative DependentProductPaths.
            if candidate.name in raw:
                return True
            for part in raw.replace("__TESTROOT__", str(products)).split(":"):
                if not part.startswith("/"):
                    continue
                path = Path(part).resolve()
                if path.is_relative_to(candidate):
                    return True
                # dyld searches directories for runtime libraries; it cannot
                # load loose .a/.o files or Swift compiler module metadata.
                if key not in loader_search_paths and candidate.is_relative_to(path):
                    return True
        return False

    def file_bytes(root):
        if root.is_file():
            return root.stat().st_size
        return sum(path.lstat().st_size for path in root.rglob("*") if path.is_file() and not path.is_symlink())

    before = file_bytes(products)
    if skipped_reason:
        # Pruning is optional. Unknown references keep the complete product;
        # ordinary manifest and identity validation still run unchanged.
        return {
            "before_bytes": before, "after_bytes": before,
            "removed_count": 0, "removed_bytes": 0, "removed": [],
            "skipped_reason": skipped_reason,
        }
    removed = []
    for path in candidates:
        if referenced(path):
            continue
        removed.append({"path": path.relative_to(products).as_posix(), "bytes": file_bytes(path)})
    # All references have been checked before the first removal.
    for item in removed:
        path = products / item["path"]
        shutil.rmtree(path) if path.is_dir() else path.unlink()
    return {
        "before_bytes": before, "after_bytes": file_bytes(products),
        "removed_count": len(removed), "removed_bytes": sum(item["bytes"] for item in removed),
        "removed": removed,
    }


def stamp(derived: Path, source_derived: Path) -> None:
    products = derived / "Build" / "Products"
    current = identity()
    manifest = manifests(products)[0]
    relocate_manifest(
        manifest, products, [(str(source_derived.resolve()), str(derived.resolve()))],
        Path(current["developer"]),
    )
    staging = prune_compile_products(products)
    digest = product_digest(products)
    receipt = {
        "schema": 1,
        "identity": current,
        "producer_derived": str(derived.resolve()),
        "product_digest": f"sha256:{digest}",
        "xctestrun": manifest.name,
        "staging": staging,
    }
    (products / RECEIPT).write_text(json.dumps(receipt, sort_keys=True, indent=2) + "\n")
    print(f"Stamped iOS simulator product {receipt['product_digest']}")
    print("IOS_BUILD_ONCE_STAGING " + json.dumps(staging, sort_keys=True))


def restore(derived: Path) -> None:
    products = derived / "Build" / "Products"
    receipt_path = products / RECEIPT
    receipt = json.loads(receipt_path.read_text())
    if receipt.get("schema") != 1:
        raise ValueError("unsupported iOS test product receipt schema")
    current = identity()
    recorded = receipt.get("identity") or {}
    for key in IDENTITY_KEYS:
        if recorded.get(key) != current.get(key):
            raise ValueError(
                f"iOS test product {key} mismatch: expected {current.get(key)!r}, got {recorded.get(key)!r}"
            )
    actual_digest = f"sha256:{product_digest(products)}"
    if receipt.get("product_digest") != actual_digest:
        raise ValueError(
            f"iOS test product digest mismatch: expected {receipt.get('product_digest')}, got {actual_digest}"
        )
    manifest = manifests(products)[0]
    if receipt.get("xctestrun") != manifest.name:
        raise ValueError("iOS test product .xctestrun identity mismatch")
    replacements = [
        (str(receipt["producer_derived"]), str(derived.resolve())),
        (str(recorded.get("checkout", "")), str(current["checkout"])),
        (str(recorded.get("developer", "")), str(current["developer"])),
    ]
    relocate_manifest(manifest, products, replacements, Path(current["developer"]))
    github_env = os.environ.get("GITHUB_ENV")
    if github_env:
        with Path(github_env).open("a") as output:
            output.write(f"CMUX_IOS_XCTESTRUN={manifest.resolve()}\n")
            output.write(f"CMUX_IOS_PRODUCT_DIGEST={actual_digest}\n")
    print(f"Verified iOS simulator product {actual_digest}")


def main() -> None:
    if len(sys.argv) not in {3, 4} or sys.argv[1] not in {"stamp", "restore"}:
        raise SystemExit(
            "usage: ios_simulator_test_product.py stamp DERIVED_DATA SOURCE_DERIVED_DATA | restore DERIVED_DATA"
        )
    command = sys.argv[1]
    derived = Path(sys.argv[2]).resolve()
    if command == "stamp":
        if len(sys.argv) != 4:
            raise SystemExit("stamp requires SOURCE_DERIVED_DATA")
        stamp(derived, Path(sys.argv[3]))
    else:
        if len(sys.argv) != 3:
            raise SystemExit("restore accepts only DERIVED_DATA")
        restore(derived)


if __name__ == "__main__":
    main()
