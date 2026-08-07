#!/usr/bin/env python3
"""Clean captured agent-session screens and regenerate the base64-embedded
fixtures in TerminalPreviewTranscripts.swift.

Usage: embed_sessions.py <sessions_dir>   (dir with claude/codex/opencode/pi.ans)
"""
import base64
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SWIFT = os.path.normpath(os.path.join(
    HERE, "..", "..", "..",
    "Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/TerminalPreviewTranscripts.swift"))

AGENTS = ["claude", "codex", "opencode", "pi"]
NOISE = re.compile(
    r"(Update Available|New version|Changelog:|pi update|tmux extended-keys|Add `set -g"
    r"|restart tmux|Tip:|/feedback|connectors are disabled|Churned for|Working \("
    r"|Press enter|tab to queue|esc to interrupt|app-landing-page|Run 'codex)", re.I)


def strip_ansi(s):
    return re.sub(r"\x1b\[[0-9;]*m", "", s)


def clean(path):
    lines = open(path, encoding="utf-8", errors="replace").read().split("\n")
    out = [ln for ln in lines if not NOISE.search(strip_ansi(ln).strip())]
    blank = lambda l: strip_ansi(l).strip() == ""
    while out and blank(out[0]):
        out.pop(0)
    while out and blank(out[-1]):
        out.pop()
    return ("\r\n".join(out) + "\r\n").encode("utf-8")


def main():
    src = sys.argv[1]
    b64 = {}
    for a in AGENTS:
        p = os.path.join(src, f"{a}.ans")
        if not os.path.exists(p):
            raise SystemExit(f"missing capture: {p}")
        data = clean(p)
        b64[a] = base64.b64encode(data).decode()
        print(f"{a}: {len(data)} bytes -> {len(b64[a])} b64")

    doc = ['#if canImport(UIKit) && DEBUG', 'import Foundation', '',
           '/// Real captured agent-session screens (ANSI), recorded from the actual CLIs',
           '/// (claude, codex, opencode, pi) via `tmux capture-pane -e -p` at the iOS',
           '/// terminal grid width, then base64-embedded so the App Store terminal',
           '/// screenshots show genuine TUIs (no hand-authored transcripts). Re-record with',
           '/// ios/fastlane/frame_assets/record_sessions.sh. Selected via',
           '/// `CMUX_UITEST_TERMINAL_TRANSCRIPT` (claude | codex | opencode | pi).',
           'enum TerminalPreviewTranscripts {',
           '    static func transcript(named name: String) -> Data {',
           '        let b64: String',
           '        switch name.lowercased() {',
           '        case "codex": b64 = codexB64',
           '        case "opencode": b64 = opencodeB64',
           '        case "pi": b64 = piB64',
           '        default: b64 = claudeB64',
           '        }',
           '        return Data(base64Encoded: b64) ?? Data()',
           '    }', '']
    for a in AGENTS:
        doc.append(f'    private static let {a}B64 = "{b64[a]}"')
        doc.append('')
    doc += ['}', '#endif', '']
    open(SWIFT, "w").write("\n".join(doc))
    print(f"wrote {SWIFT}")


if __name__ == "__main__":
    main()
