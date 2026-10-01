#!/usr/bin/env python3
"""Check public socket dispatcher cases against v2 capability discovery.

The public namespaces covered here are the ones consumed by the Cloud/CLI
contract. Internal debug, mobile-host, and simulator dispatchers have separate
authorization surfaces and are intentionally outside this check.
"""

import argparse
import pathlib
import re
import sys

PUBLIC_PREFIXES = (
    "vm.",
    "browser.profiles.",
    "browser.import.",
    "workspace.move",
    "workspace.status.",
    "workspace.todo.",
    "notification.feed.",
    "surface.ssh_session_attach.",
)


def switch_cases(source):
    methods = set()
    for match in re.finditer(r"switch\s+(?:request\.)?method\b", source):
        opening = source.find("{", match.end())
        if opening < 0:
            continue
        depth = 0
        closing = None
        for index in range(opening, len(source)):
            if source[index] == "{":
                depth += 1
            elif source[index] == "}":
                depth -= 1
                if depth == 0:
                    closing = index
                    break
        if closing is None:
            continue
        methods.update(re.findall(r'case\s+"([A-Za-z0-9_.-]+)"', source[opening:closing]))
    return methods


def capability_methods(source):
    anchor = source.find("var methods: [String] = [")
    if anchor < 0:
        raise ValueError("v2 capability method list is missing")
    closing = source.find("\n        ]", anchor)
    if closing < 0:
        raise ValueError("v2 capability method list is unclosed")
    return set(re.findall(r'"([A-Za-z0-9_.-]+)"', source[anchor:closing]))


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", default=pathlib.Path(__file__).resolve().parents[1])
    args = parser.parse_args(argv)
    root = pathlib.Path(args.root).resolve()
    capability_path = root / "Sources/TerminalController+Capabilities.swift"
    capability_text = capability_path.read_text(encoding="utf-8")
    advertised = capability_methods(capability_text)

    dispatched = set()
    for relative in (
        "Sources/TerminalController.swift",
        "Sources/Cloud",
        "Sources/Surfaces",
        "Packages/macOS/CmuxControlSocket/Sources/CmuxControlSocket/Coordinator",
    ):
        path = root / relative
        paths = [path] if path.is_file() else sorted(path.rglob("*.swift"))
        for source_path in paths:
            dispatched.update(switch_cases(source_path.read_text(encoding="utf-8")))

    public = {method for method in dispatched if method.startswith(PUBLIC_PREFIXES)}
    missing = sorted(public - advertised)
    if missing:
        print("Missing advertised capabilities:", file=sys.stderr)
        for method in missing:
            print("  - " + method, file=sys.stderr)
        return 1
    print("socket capability parity: ok ({0} public dispatcher methods)".format(len(public)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
