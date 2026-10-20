#!/usr/bin/env python3
"""Dialog key hints (u2647): every dialog button shows the key that presses it.

Each dialog, sheet, confirmation and approval button goes through one shared component that draws
the key and binds it, so a button never presses on a key it does not show:

  native dialogs   CmuxDialogSpec / CmuxDialogButtonView (CmuxNextDesign/Dialog), which derive the
                   key from CmuxDialogKeys
  AppKit sheets    ThemedBezelButton.keyHint (binds keyEquivalent and draws the keycap)
  SwiftUI sheets   CmuxDialogActionButton(title, hint:)
  web dialogs      ui/DialogButton (webviews/src/ui/DialogButton.tsx)

Fails on a dialog button made around them:
  swift-shortcut   `.keyboardShortcut(.defaultAction|.cancelAction)` on a plain SwiftUI Button
  swift-key        `keyEquivalent = "\\r"` or `"\\u{1b}"` set by hand on an NSButton
  swift-system     SwiftUI `.alert(` / `.confirmationDialog(` or `NSAlert(`: system dialogs that
                   cannot show their keys (R96: every dialog is a cmux dialog)
  web-button       a raw <button> with a dialog button class in a file that renders <Dialog>,
                   <Sheet> or <FormDialog>
A line (or the line above it) holding `dialog-keys-exempt: <reason>` is skipped.

  python3 scripts/cmux-next/check-dialog-key-hints.py [REPO_ROOT]
"""
import os
import re
import sys

SWIFT_ROOT = os.path.join("Packages", "macOS", "CmuxNext", "Sources")
WEB_ROOT = os.path.join("webviews", "src")
# The shared components themselves.
SWIFT_OWNERS = (
    os.path.join("CmuxNextDesign", "Dialog") + os.sep,
    os.path.join("CmuxNextDesign", "ThemedControls.swift"),
)
WEB_OWNERS = (os.path.join("ui", "DialogButton.tsx"),)
EXEMPT = "dialog-keys-exempt:"

SWIFT_RULES = [
    ("swift-shortcut", re.compile(r"\.keyboardShortcut\(\s*\.(defaultAction|cancelAction)\b"),
     "a dialog button binds Return/Escape through CmuxDialogActionButton(title, hint:), which also shows the key"),
    ("swift-key", re.compile(r"keyEquivalent\s*=\s*\"(\\r|\\u\{1[bB]\})\""),
     "set `button.keyHint = .return/.escape` on a ThemedBezelButton (or use CmuxDialogButtonView(standalone:)), which also shows the key"),
    ("swift-system", re.compile(r"^\s*\.(alert|confirmationDialog)\(|\bNSAlert\s*\("),
     "a system alert cannot show its keys: present a CmuxDialogSpec through CmuxDialogCenter"),
]
WEB_DIALOG = re.compile(r"<(Dialog|Sheet|FormDialog)\b")
WEB_BUTTON = re.compile(r"<button\b")
WEB_DIALOG_CLASS = re.compile(r"className=\"[^\"]*\b(hc-text-button|cloud-button|ve-button|lg-form-button)\b")


def exempt(lines, index):
    return EXEMPT in lines[index] or (index > 0 and EXEMPT in lines[index - 1])


def swift_findings(root):
    base = os.path.join(root, SWIFT_ROOT)
    for directory, _, files in os.walk(base):
        for name in sorted(files):
            if not name.endswith(".swift"):
                continue
            path = os.path.join(directory, name)
            relative = os.path.relpath(path, base)
            if relative.startswith(SWIFT_OWNERS):
                continue
            with open(path, encoding="utf-8") as handle:
                lines = handle.read().split("\n")
            for index, line in enumerate(lines):
                code = line.split("//", 1)[0] if not line.lstrip().startswith("///") else ""
                for rule, pattern, fix in SWIFT_RULES:
                    if pattern.search(code) and not exempt(lines, index):
                        yield os.path.relpath(path, root), index + 1, rule, fix


def web_findings(root):
    base = os.path.join(root, WEB_ROOT)
    for directory, _, files in os.walk(base):
        if "node_modules" in directory:
            continue
        for name in sorted(files):
            if not name.endswith(".tsx") or name.endswith((".test.tsx", ".gallery.tsx")):
                continue
            path = os.path.join(directory, name)
            if os.path.relpath(path, base) in WEB_OWNERS:
                continue
            with open(path, encoding="utf-8") as handle:
                text = handle.read()
            if not WEB_DIALOG.search(text):
                continue
            lines = text.split("\n")
            for index, line in enumerate(lines):
                if not WEB_BUTTON.search(line):
                    continue
                # The opening tag may span lines: read up to its end.
                tag = " ".join(lines[index:index + 8]).split(">", 1)[0]
                if WEB_DIALOG_CLASS.search(tag) and not exempt(lines, index):
                    yield (os.path.relpath(path, root), index + 1, "web-button",
                           "use <DialogButton dialogKey=...> from ui/DialogButton, which shows and names the key")


def main(argv):
    root = os.path.abspath(argv[1] if len(argv) > 1 else os.path.join(os.path.dirname(__file__), "..", ".."))
    findings = list(swift_findings(root)) + list(web_findings(root))
    for path, line, rule, fix in findings:
        print(f"{path}:{line}: {rule}: {fix}", file=sys.stderr)
    if findings:
        print(f"check-dialog-key-hints: {len(findings)} dialog button(s) without the shared key hint "
              f"(u2647; mark a real exception with `{EXEMPT} <reason>`)", file=sys.stderr)
        return 1
    print("check-dialog-key-hints: every dialog button shows its key")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
