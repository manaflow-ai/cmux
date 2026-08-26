#!/usr/bin/env python3
"""Guard the exhaustive Dock ownership and dispatcher-gate audit."""

from pathlib import Path
import re
import unittest


REPO_ROOT = Path(__file__).resolve().parents[1]
ROUTING_SOURCE = REPO_ROOT / "Sources" / "AppDelegate+DockShortcutRouting.swift"
ACTION_SOURCE = REPO_ROOT / "Sources" / "KeyboardShortcutSettings.swift"
MOVEMENT_SOURCE = REPO_ROOT / "Sources" / "SurfacePaneMovement.swift"
DISPATCH_SOURCES = tuple((REPO_ROOT / "Sources").glob("AppDelegate*.swift")) + (
    REPO_ROOT / "Sources" / "Workspace+DockBrowserLookup.swift",
)
GATE_CALLS = (
    "focusedDockStoreForShortcut",
    "performFocusedDockShortcut",
    "routeCreateToFocusedDock",
    "routeSplitToFocusedDock",
)


def source_between(
    source: str,
    start_anchor: str,
    end_anchor: str,
    source_name: str,
) -> str:
    _, start_separator, remainder = source.partition(start_anchor)
    if not start_separator:
        raise AssertionError(
            f"{source_name}: missing start anchor {start_anchor!r}"
        )
    body, end_separator, _ = remainder.partition(end_anchor)
    if not end_separator:
        raise AssertionError(
            f"{source_name}: missing end anchor {end_anchor!r}"
        )
    return body


def action_cases() -> set[str]:
    source = ACTION_SOURCE.read_text(encoding="utf-8")
    enum_body = source_between(
        source,
        "enum Action: String, CaseIterable, Identifiable {",
        "var id: String",
        ACTION_SOURCE.name,
    )
    actions: set[str] = set()
    for line in enum_body.splitlines():
        stripped = line.strip()
        if not stripped.startswith("case "):
            continue
        declarations = stripped.removeprefix("case ").split("=", maxsplit=1)[0]
        actions.update(
            declaration.strip()
            for declaration in declarations.split(",")
        )
    return actions


def disposition_actions() -> dict[str, set[str]]:
    source = ROUTING_SOURCE.read_text(encoding="utf-8")
    property_body = source_between(
        source,
        "var dockShortcutRoutingDisposition:",
        "extension AppDelegate {",
        ROUTING_SOURCE.name,
    )
    result: dict[str, set[str]] = {}
    for cases, disposition in re.findall(
        r"case\s+(.*?)\s*:\s*\.(dockScoped|focusResolved|mainContainer)",
        property_body,
        flags=re.DOTALL,
    ):
        result.setdefault(disposition, set()).update(
            re.findall(r"\.([A-Za-z][A-Za-z0-9_]*)", cases)
        )
    return result


def balanced_call_bodies(source: str, call_name: str) -> list[str]:
    # Gate calls currently use ordinary quoted strings. This lightweight scanner
    # intentionally does not parse Swift multiline or raw string delimiters.
    bodies: list[str] = []
    pattern = re.compile(r"\b" + re.escape(call_name) + r"\s*\(")
    for match in pattern.finditer(source):
        opening = source.find("(", match.start())
        depth = 1
        index = opening + 1
        in_string = False
        escaped = False
        line_comment = False
        block_comment_depth = 0
        while index < len(source) and depth:
            character = source[index]
            following = source[index + 1] if index + 1 < len(source) else ""
            if line_comment:
                if character == "\n":
                    line_comment = False
                index += 1
                continue
            if block_comment_depth:
                if character == "/" and following == "*":
                    block_comment_depth += 1
                    index += 2
                elif character == "*" and following == "/":
                    block_comment_depth -= 1
                    index += 2
                else:
                    index += 1
                continue
            if in_string:
                if escaped:
                    escaped = False
                elif character == "\\":
                    escaped = True
                elif character == '"':
                    in_string = False
                index += 1
                continue
            if character == "/" and following == "/":
                line_comment = True
                index += 2
                continue
            if character == "/" and following == "*":
                block_comment_depth = 1
                index += 2
                continue
            if character == '"':
                in_string = True
            elif character == "(":
                depth += 1
            elif character == ")":
                depth -= 1
            index += 1
        if depth == 0:
            bodies.append(source[opening + 1:index - 1])
    return bodies


def movement_shortcut_actions() -> set[str]:
    source = MOVEMENT_SOURCE.read_text(encoding="utf-8")
    property_body = source_between(
        source,
        "var shortcutAction: KeyboardShortcutSettings.Action {",
        "init?(shortcutAction:",
        MOVEMENT_SOURCE.name,
    )
    return set(
        re.findall(
            r"case\s+\.[A-Za-z][A-Za-z0-9_]*\s*:\s*"
            r"\.([A-Za-z][A-Za-z0-9_]*)",
            property_body,
        )
    )


def explicitly_gated_actions() -> set[str]:
    actions: set[str] = set()
    has_movement_gate = False
    for path in DISPATCH_SOURCES:
        source = path.read_text(encoding="utf-8")
        for call_name in GATE_CALLS:
            for body in balanced_call_bodies(source, call_name):
                actions.update(
                    re.findall(
                        r"\baction\s*:\s*\.([A-Za-z][A-Za-z0-9_]*)",
                        body,
                    )
                )
                if re.search(
                    r"\baction\s*:\s*movement\.shortcutAction\b",
                    body,
                ):
                    has_movement_gate = True
    if has_movement_gate:
        actions.update(movement_shortcut_actions())
    return actions


class DockShortcutRoutingGuardTests(unittest.TestCase):
    def test_every_action_has_one_explicit_ownership_disposition(self) -> None:
        dispositions = disposition_actions()
        classified = set().union(*dispositions.values())
        duplicate_actions = set()
        disposition_names = tuple(dispositions)
        for index, name in enumerate(disposition_names):
            for other_name in disposition_names[index + 1:]:
                duplicate_actions.update(
                    dispositions[name] & dispositions[other_name]
                )

        self.assertEqual(duplicate_actions, set())
        self.assertEqual(classified, action_cases())

    def test_every_dock_scoped_action_reaches_the_focused_dock_gate(self) -> None:
        dock_scoped = disposition_actions()["dockScoped"]
        gated = explicitly_gated_actions()

        self.assertEqual(
            gated,
            dock_scoped,
            "Every dockScoped action must appear in an action-aware Dock gate "
            "call. Add the route before adding its main-area fallback.",
        )


if __name__ == "__main__":
    unittest.main()
