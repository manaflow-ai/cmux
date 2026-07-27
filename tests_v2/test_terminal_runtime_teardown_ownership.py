#!/usr/bin/env python3
"""Regression: terminal models must delegate native frees to the teardown owner."""

import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SURFACE_DIRECTORY = ROOT / "Packages/macOS/CmuxTerminal/Sources/CmuxTerminal/Surface"
SURFACE_SOURCES = sorted(SURFACE_DIRECTORY.rglob("*.swift"))
ALLOWED_TEST_HELPERS = {
    Path("Packages/macOS/CmuxTerminal/Sources/CmuxTerminal/Surface/TerminalSurface+Debug.swift"): {
        "releaseSurfaceForTesting",
        "replaceSurfaceWithFreedPointerForTesting",
    }
}


def _swift_code_mask(source: str) -> str:
    """Preserve executable Swift code while blanking comments and string literals."""
    masked = ["\n" if character == "\n" else " " for character in source]
    contexts: list[dict[str, int | str | None]] = [{"kind": "code", "paren_depth": None}]
    index = 0

    while index < len(source):
        context = contexts[-1]
        kind = context["kind"]

        if kind == "line_comment":
            if source[index] == "\n":
                contexts.pop()
            index += 1
            continue

        if kind == "block_comment":
            if source.startswith("/*", index):
                context["depth"] = int(context["depth"]) + 1
                index += 2
            elif source.startswith("*/", index):
                context["depth"] = int(context["depth"]) - 1
                index += 2
                if context["depth"] == 0:
                    contexts.pop()
            else:
                index += 1
            continue

        if kind == "string":
            hash_count = int(context["hash_count"])
            quote_count = int(context["quote_count"])
            closing_delimiter = ('"' * quote_count) + ("#" * hash_count)
            interpolation_opener = "\\" + ("#" * hash_count) + "("

            if source.startswith(closing_delimiter, index):
                index += len(closing_delimiter)
                contexts.pop()
            elif source.startswith(interpolation_opener, index):
                index += len(interpolation_opener)
                contexts.append({"kind": "code", "paren_depth": 1})
            elif source[index] == "\\":
                escape_prefix = "\\" + ("#" * hash_count)
                if source.startswith(escape_prefix, index):
                    index += min(len(escape_prefix) + 1, len(source) - index)
                else:
                    index += 1
            else:
                index += 1
            continue

        if source.startswith("//", index):
            contexts.append({"kind": "line_comment", "depth": None})
            index += 2
            continue
        if source.startswith("/*", index):
            contexts.append({"kind": "block_comment", "depth": 1})
            index += 2
            continue

        hash_count = 0
        while index + hash_count < len(source) and source[index + hash_count] == "#":
            hash_count += 1
        quote_index = index + hash_count
        if quote_index < len(source) and source[quote_index] == '"':
            quote_count = 3 if source.startswith('"""', quote_index) else 1
            contexts.append(
                {
                    "kind": "string",
                    "hash_count": hash_count,
                    "quote_count": quote_count,
                }
            )
            index = quote_index + quote_count
            continue

        paren_depth = context["paren_depth"]
        if paren_depth is not None and source[index] == ")":
            if paren_depth == 1:
                contexts.pop()
                index += 1
                continue
            context["paren_depth"] = int(paren_depth) - 1
        elif paren_depth is not None and source[index] == "(":
            context["paren_depth"] = int(paren_depth) + 1

        masked[index] = source[index]
        index += 1

    return "".join(masked)


def _matching_delimiter(code: str, opening_index: int, opening: str, closing: str) -> int:
    """Return the matching delimiter index in lexically masked Swift code."""
    depth = 0
    for index in range(opening_index, len(code)):
        if code[index] == opening:
            depth += 1
        elif code[index] == closing:
            depth -= 1
            if depth == 0:
                return index
    return -1


def _allowed_function_bodies(code: str, function_names: set[str]) -> list[tuple[int, int]]:
    """Find exact body ranges for allowlisted Swift functions."""
    ranges = []
    for function_name in function_names:
        declaration = re.compile(rf"\bfunc\s+{re.escape(function_name)}\s*\(")
        for match in declaration.finditer(code):
            parameters_open = code.find("(", match.start(), match.end())
            parameters_close = _matching_delimiter(code, parameters_open, "(", ")")
            if parameters_close < 0:
                continue
            body_open = code.find("{", parameters_close + 1)
            if body_open < 0:
                continue
            body_close = _matching_delimiter(code, body_open, "{", "}")
            if body_close >= 0:
                ranges.append((body_open, body_close))
    return ranges


def _direct_free_lines(source: str, allowed_helpers: set[str]) -> list[int]:
    """Return lines containing non-allowlisted direct Ghostty frees."""
    code = _swift_code_mask(source)
    allowed_ranges = _allowed_function_bodies(code, allowed_helpers)
    violations = []
    for match in re.finditer(r"\bghostty_surface_free\s*\(", code):
        if any(start <= match.start() <= end for start, end in allowed_ranges):
            continue
        violations.append(source.count("\n", 0, match.start()) + 1)
    return violations


def _self_check_scanner() -> None:
    """Prove lexical decoys cannot hide or fabricate a direct-free violation."""
    sample = r'''
// func allowed() { ghostty_surface_free(pointer) }
/* outer
   /* func allowed() { ghostty_surface_free(pointer) } */
*/
let ordinary = "func allowed() { ghostty_surface_free(pointer) }"
let multiline = """
func allowed() { ghostty_surface_free(pointer) }
"""
let raw = #"func allowed() { ghostty_surface_free(pointer) }"#
func allowed() {
    ghostty_surface_free(pointer)
}
func blocked() {
    let interpolated = "\(ghostty_surface_free(pointer))"
    ghostty_surface_free(pointer)
}
'''
    violation_lines = _direct_free_lines(sample, {"allowed"})
    if violation_lines != [15, 16]:
        raise AssertionError(
            "Swift lexical scanner self-check failed: "
            f"expected violations on lines 15 and 16, found {violation_lines}"
        )


def main() -> int:
    """Reject direct native frees outside the two explicit DEBUG test helpers."""
    _self_check_scanner()
    if not SURFACE_SOURCES:
        raise AssertionError(f"No Swift surface sources found under {SURFACE_DIRECTORY.relative_to(ROOT)}")

    violations = []
    for source in SURFACE_SOURCES:
        relative_source = source.relative_to(ROOT)
        source_text = source.read_text(encoding="utf-8")
        allowed_helpers = ALLOWED_TEST_HELPERS.get(relative_source, set())
        source_lines = source_text.splitlines()
        for line_number in _direct_free_lines(source_text, allowed_helpers):
            violations.append(f"{relative_source}:{line_number}: {source_lines[line_number - 1].strip()}")

    if violations:
        details = "\n".join(violations)
        raise AssertionError(
            "TerminalSurface owns model state, but it must not directly free Ghostty runtime surfaces. "
            "Queue every native free through TerminalSurfaceRuntimeTeardownCoordinator so Ghostty thread joins "
            f"cannot block the main actor:\n{details}"
        )

    print("PASS: terminal runtime frees are owned by the teardown coordinator")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
