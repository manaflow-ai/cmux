#!/usr/bin/env python3
"""Decode a cmux iOS structured diagnostic export blob into readable rows.

The iOS feedback pane ("Send to agent") submits `DiagnosticLog.export()`, an
opaque integer CSV, to the paired Mac. The Mac writes it to
`~/.cache/cmux-dogfood-feedback/<ISO8601>_<shortid>/diagnostic.log`. This script
turns that blob (or the whole bundle dir) into named events so the keyboard-input
evidence (hold-backspace call count, dictation firing, first-responder identity)
is human-readable.

Usage:
    scripts/decode-ios-diagnostic.py <diagnostic.log | bundle-dir>
    scripts/decode-ios-diagnostic.py            # newest bundle under the cache dir

Blob format (one header line + one row per event):
    cmuxdiag v1 anchorWallNs=<n> anchorMonoNs=<n> count=<n> build=<...>
    <tNanos>,<code>,<surface>,<ms>,<a>,<b>,<c>

Empty fields mean the field was absent. Keep this in sync with
Packages/CMUXMobileCore/Sources/CMUXMobileCore/DiagnosticEventCode.swift and the
InputResponderIdentity / InputCommitSink enums.
"""

from __future__ import annotations

import os
import sys

# DiagnosticEventCode raw value -> (name, slot legend).
EVENT_CODES = {
    1: ("connect", ""),
    2: ("pairOk", ""),
    3: ("pairFail", ""),
    4: ("renderGridLag", ""),
    5: ("livenessResubscribe", ""),
    6: ("streamEnded", ""),
    7: ("inputSeqBehind", "a=localSeq b=remoteSeq"),
    8: ("byteGap", ""),
    9: ("error", ""),
    10: ("inputKeyboardUp", "a=responderIdentity"),
    11: ("inputDeleteBackward", "a=responderIdentity b=imeComposing"),
    12: ("inputBackspaceEmitted", "ms=emittedBytes"),
    13: ("inputInsertText", "a=utf8Len b=imeComposing"),
    14: ("inputDictationPlaceholder", ""),
    15: ("inputDictationRemove", "a=willInsertResult"),
    16: ("inputBecomeFirstResponder", "a=became b=responderIdentity"),
    17: ("inputCommitRouted", "a=utf8Len b=commitSink"),
}

# InputResponderIdentity raw value -> name.
RESPONDER_IDENTITY = {
    0: "none",
    1: "terminalInputProxy",
    2: "ghosttySurface",
    3: "uiTextField",
    4: "uiTextView",
    9: "other",
}

# InputCommitSink raw value -> name.
COMMIT_SINK = {
    0: "text(perKey)",
    1: "pasteText(bracketed)",
    2: "escapeSequence",
}

# Codes whose `a` slot encodes an InputResponderIdentity.
RESPONDER_A_CODES = {10, 11}
# Codes whose `b` slot encodes an InputResponderIdentity.
RESPONDER_B_CODES = {16}


def _annotate(code: int, a: str, b: str) -> str:
    notes: list[str] = []
    if code in RESPONDER_A_CODES and a != "":
        notes.append(f"responder={RESPONDER_IDENTITY.get(int(a), '?')}")
    if code in RESPONDER_B_CODES and b != "":
        notes.append(f"responder={RESPONDER_IDENTITY.get(int(b), '?')}")
    if code == 17 and b != "":
        notes.append(f"sink={COMMIT_SINK.get(int(b), '?')}")
    return "  ".join(notes)


def _resolve_path(arg: str | None) -> str:
    if arg is None:
        root = os.path.expanduser("~/.cache/cmux-dogfood-feedback")
        if not os.path.isdir(root):
            sys.exit(f"no bundle dir and {root} does not exist")
        dirs = sorted(
            (os.path.join(root, d) for d in os.listdir(root)),
            reverse=True,
        )
        dirs = [d for d in dirs if os.path.isdir(d)]
        if not dirs:
            sys.exit(f"no bundles under {root}")
        return os.path.join(dirs[0], "diagnostic.log")
    if os.path.isdir(arg):
        return os.path.join(arg, "diagnostic.log")
    return arg


def main() -> None:
    path = _resolve_path(sys.argv[1] if len(sys.argv) > 1 else None)
    try:
        with open(path, "r", encoding="utf-8") as handle:
            lines = handle.read().splitlines()
    except OSError as error:
        sys.exit(f"cannot read {path}: {error}")

    if not lines:
        sys.exit(f"{path} is empty")

    print(f"# {path}")
    print(f"# {lines[0]}")
    print()

    # Counters for the hold-backspace + dictation summary.
    delete_calls = 0
    bytes_emitted = 0
    insert_calls = 0
    dictation_placeholder = 0
    dictation_results = 0

    base_ns: int | None = None
    for raw in lines[1:]:
        if not raw.strip():
            continue
        fields = raw.split(",")
        if len(fields) < 2:
            continue
        t_ns = int(fields[0])
        code = int(fields[1])
        surface, ms, a, b, c = (fields + ["", "", "", "", ""])[2:7]
        if base_ns is None:
            base_ns = t_ns
        rel_ms = (t_ns - base_ns) / 1_000_000.0

        name, legend = EVENT_CODES.get(code, (f"code{code}", ""))
        annotation = _annotate(code, a, b)
        slots = []
        if surface:
            slots.append(f"surface={surface}")
        if ms:
            slots.append(f"ms={ms}")
        if a:
            slots.append(f"a={a}")
        if b:
            slots.append(f"b={b}")
        if c:
            slots.append(f"c={c}")
        slot_text = " ".join(slots)
        tail = "  ".join(p for p in (slot_text, annotation, f"({legend})" if legend else "") if p)
        print(f"+{rel_ms:9.2f}ms  {name:<26} {tail}")

        if code == 11:
            delete_calls += 1
        elif code == 12:
            bytes_emitted += 1
        elif code == 13:
            insert_calls += 1
        elif code == 14:
            dictation_placeholder += 1
        elif code == 15 and a == "1":
            dictation_results += 1

    print()
    print("# hold-backspace + dictation summary")
    print(f"#   deleteBackward calls : {delete_calls}")
    print(f"#   DEL bytes emitted    : {bytes_emitted}")
    print(f"#   insertText calls     : {insert_calls}")
    print(f"#   dictation placeholder: {dictation_placeholder}")
    print(f"#   dictation results    : {dictation_results}")
    if delete_calls <= 1:
        print("#   -> hold-backspace did NOT auto-repeat (<=1 deleteBackward call)")
    elif delete_calls == bytes_emitted:
        print("#   -> deleteBackward repeated AND every call emitted a DEL byte; hunt is downstream of the iOS view")
    else:
        print(f"#   -> deleteBackward repeated ({delete_calls}) but only {bytes_emitted} bytes left the view")


if __name__ == "__main__":
    main()
