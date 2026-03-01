#!/usr/bin/env python3
"""Static regression checks for re-entrant terminal focus guard.

Guards the fix for split-drag focus churn where:
becomeFirstResponder -> onFocus -> Workspace.focusPanel -> refocus side-effects
could repeatedly re-enter and spike CPU.
"""

from __future__ import annotations

import subprocess
from pathlib import Path


def repo_root() -> Path:
    result = subprocess.run(
        ["git", "rev-parse", "--show-toplevel"],
        capture_output=True,
        text=True,
    )
    if result.returncode == 0:
        return Path(result.stdout.strip())
    return Path(__file__).resolve().parents[1]


def main() -> int:
    root = repo_root()
    failures: list[str] = []

    workspace_path = root / "Sources" / "Workspace.swift"
    workspace_source = workspace_path.read_text(encoding="utf-8")

    required_workspace_snippets = [
        "enum FocusPanelTrigger {",
        "case terminalFirstResponder",
        "trigger: FocusPanelTrigger = .standard",
        "let shouldSuppressReentrantRefocus = trigger == .terminalFirstResponder && selectionAlreadyConverged",
        "if let targetPaneId, !shouldSuppressReentrantRefocus {",
        "reason=firstResponderAlreadyConverged",
    ]
    for snippet in required_workspace_snippets:
        if snippet not in workspace_source:
            failures.append(f"Workspace focus guard missing snippet: {snippet}")

    workspace_content_view_path = root / "Sources" / "WorkspaceContentView.swift"
    workspace_content_view_source = workspace_content_view_path.read_text(encoding="utf-8")
    focus_callback_snippet = "workspace.focusPanel(panel.id, trigger: .terminalFirstResponder)"
    if focus_callback_snippet not in workspace_content_view_source:
        failures.append(
            "WorkspaceContentView terminal onFocus callback no longer passes .terminalFirstResponder trigger"
        )

    if failures:
        print("FAIL: focus-panel re-entrant guard regression checks failed")
        for item in failures:
            print(f" - {item}")
        return 1

    print("PASS: focus-panel re-entrant guard is in place")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
