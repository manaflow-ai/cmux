#!/usr/bin/env python3

import argparse
import pathlib
import re
import sys


CLASS_PATTERN = re.compile(
    r"^(?:final\s+)?class\s+([A-Za-z_][A-Za-z0-9_]*)\s*:\s*XCTestCase\b",
    re.MULTILINE,
)


def discover_test_classes(test_root: pathlib.Path) -> list[str]:
    classes: set[str] = set()
    for path in sorted(test_root.glob("*.swift")):
        contents = path.read_text(encoding="utf-8")
        classes.update(CLASS_PATTERN.findall(contents))
    return sorted(classes)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Emit xcodebuild -only-testing arguments for one cmux-unit shard."
    )
    parser.add_argument("--shard-index", type=int, required=True)
    parser.add_argument("--shard-count", type=int, required=True)
    parser.add_argument("--target", default="cmuxTests")
    args = parser.parse_args()

    if args.shard_count <= 0:
        parser.error("--shard-count must be positive")
    if args.shard_index < 0 or args.shard_index >= args.shard_count:
        parser.error("--shard-index must be within [0, shard-count)")

    repo_root = pathlib.Path(__file__).resolve().parents[1]
    test_root = repo_root / "cmuxTests"
    test_classes = discover_test_classes(test_root)
    if not test_classes:
        print("No XCTestCase subclasses found under cmuxTests", file=sys.stderr)
        return 1

    shard_classes = [
        class_name
        for idx, class_name in enumerate(test_classes)
        if idx % args.shard_count == args.shard_index
    ]
    if not shard_classes:
        print(
            f"Shard {args.shard_index} of {args.shard_count} has no assigned test classes",
            file=sys.stderr,
        )
        return 1

    for class_name in shard_classes:
        print(f"-only-testing:{args.target}/{class_name}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
