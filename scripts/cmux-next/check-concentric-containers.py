#!/usr/bin/env python3
"""Containers that hold buttons are concentric with them (Lawrence 2026-11-15, on the "Option or Shift + drag
selects text | Don't Show Again | x" hint: "all dialogs needs concentric padding with buttons inside").

The rule: a container's corner is its buttons' corner plus the padding between its edge and them, the padding the
same on the top, the bottom and the near side. Swift reads it from `Metrics.buttonContainer(padding:)` (a
`ConcentricContainer`: `.outerRadius` for the container, `.childRadius` for the buttons, `.textInset` for leading
text); CSS from `calc(var(--ds-radius-control) + <padding>)` (or `--concentric-padding` / `--ui-dialog-padding`).
The laid-out toasts and dialog card are measured in ConcentricButtonContainerTests; this guard stops a new
container from taking a corner of its own.

Fails on:
  Swift (Packages/macOS/CmuxNext/Sources): in a file that holds buttons (`...Button(`, `...ButtonView(`,
          `NSButton`, SwiftUI `Button(`), a container surface made or rounded with a corner that is not derived
          from the buttons: `Glass.makeOverlayPanel(` / `Glass.makeSurface(` / `Glass.makePanel(` /
          `CardSurfaceView(` / `OverlaySurfaceView(` (with no corner, they take the panel's own), or
          `surface|glass|card|panel|container ... .cornerRadius =`, unless the line reads `buttonContainer(`,
          `ConcentricContainer`, `geometry`, `outerRadius`, a `...CornerRadius` token of this file or type that is
          itself declared from `buttonContainer(`, or says why: `// concentric-allow: <reason>`.
  CSS (webviews/src, *.css): a `border-radius` in a rule whose subject is a container that holds buttons (a class
          naming dialog, toast, notice, hint, banner, sheet, prompt, tip, strip or card) that does not read
          `--ds-radius-control`, `--concentric-padding` or `--ui-dialog-padding`, or says why:
          `/* concentric-allow: <reason> */`.

Keycap and shortcut chips inside buttons are concentric with their button too (Lawrence 2026-11-15, the quit
dialog's "Cancel esc" and "Quit ↩" chips had square-ish corners): the chip is the button's corner less its inset.
  Swift: in a file whose name names a keycap or shortcut chip (Keycap, KeyChip, ShortcutChip, KeyHint), a
          `cornerRadius =` / `cornerRadius:` that is not derived (`ConcentricContainer`, a `.keycap` container,
          `childRadius`, `nestedIn:`, `outerRadius`), or says why.
  CSS: a `border-radius` in a rule whose subject is a keycap (a class naming keycap, keyhint, kbd or
          shortcut-chip, or a `kbd` element) that does not read `--ds-radius-control`, or says why.

A card's or a toast's close x sits in its corner concentric with it (Lawrence 2026-11-15, the "Updated to
Nightly" card's x): the same inset from the top and the side, its hover the corner less it.
  Swift: in a file that draws a card surface (`CardSurfaceView(`, `GlassPanelView(`, `OverlaySurfaceView(`,
          `Glass.make...(`), a close or dismiss x placed by `close...frame =` / `dismiss...frame =` that does not
          read `cornerControl(`, `topTrailingFrame(`, `ConcentricContainer` or `geometry`, or says why.
  CSS: a close or dismiss button (a class ending in close or dismiss) rounded by a corner of its own (`50%`, a
          literal) instead of `--ds-radius-control` (the corner less the padding), or says why.

Surfaces that predate the rule are listed in concentric-containers-baseline.txt (path and the line's text); the
list may only shrink: a listed site that is fixed must leave it (the guard says so), and a new site fails.

  python3 scripts/cmux-next/check-concentric-containers.py [ROOT] [--write-baseline]
"""
import os
import re
import sys

SWIFT_ROOT = "Packages/macOS/CmuxNext/Sources"
WEB_ROOT = "webviews/src"
BASELINE = "scripts/cmux-next/concentric-containers-baseline.txt"

ALLOW_SWIFT = re.compile(r"//\s*concentric-allow:\s*\S")
ALLOW_CSS = re.compile(r"/\*\s*concentric-allow:\s*\S")

HOLDS_BUTTONS = re.compile(r"\b\w*Button(?:View)?\(|\bNSButton\b|\bButton\s*\(")
SURFACE_CALL = re.compile(r"\bGlass\.make(?:OverlayPanel|Surface|Panel)\(|\bCardSurfaceView\(|\bOverlaySurfaceView\(")
SURFACE_RADIUS = re.compile(r"\b(?:surface|glass|card|panel|container)\w*\??\.(?:layer\??\.)?cornerRadius\s*=")
# Derived from the buttons: the container geometry, `inner + padding` written out (`buttonCornerRadius + padding`),
# a nested corner (`nestedIn:`), or a capsule around capsule controls (`height / 2`, `capsuleRadius`).
DERIVED = re.compile(r"buttonContainer\(|ConcentricContainer|\bgeometry\b|outerRadius|nestedIn:"
                     r"|\w*[Rr]adius\s*\+\s*[\w.]*[Pp]adding|/\s*2\b|capsuleRadius")
KEYCAP_FILE = re.compile(r"(?:Keycap|KeyChip|ShortcutChip|KeyHint)\w*\.swift$")
KEYCAP_RADIUS = re.compile(r"\bcornerRadius\s*[:=](?!=)")
KEYCAP_DERIVED = re.compile(r"ConcentricContainer|\.keycap\b|keycapCornerRadius\(|childRadius|nestedIn:|outerRadius|buttonContainer\(")
DRAWS_CARD = re.compile(r"\bCardSurfaceView\(|\bGlassPanelView\(|\bOverlaySurfaceView\(|\bGlass\.make\w*\(")
CLOSE_FRAME = re.compile(r"\b(?:close|dismiss)\w*\.frame\s*=(?!=)")
CLOSE_DERIVED = re.compile(r"cornerControl\(|topTrailingFrame\(|ConcentricContainer|\bgeometry\b")
TOKEN_DECL = re.compile(r"\b(?:var|let)\s+(\w*[Cc]ornerRadius)\b[^\n]*buttonContainer\(")


def keycap_swift_findings(text):
    out = []
    for raw in text.splitlines():
        code = raw.split("//", 1)[0]
        if not code.strip() or ALLOW_SWIFT.search(raw) or not KEYCAP_RADIUS.search(code):
            continue
        if re.search(r"\b(?:var|let|func)\b", code) and not re.search(r"=\s*\S", code.split("cornerRadius", 1)[1]):
            continue  # a declaration with no value
        if not KEYCAP_DERIVED.search(code):
            out.append(raw.strip())
    return out


def close_swift_findings(text):
    if not DRAWS_CARD.search(text):
        return []
    out = []
    for raw in text.splitlines():
        code = raw.split("//", 1)[0]
        if CLOSE_FRAME.search(code) and not ALLOW_SWIFT.search(raw) and not CLOSE_DERIVED.search(code):
            out.append(raw.strip())
    return out


def swift_findings(text, derived_tokens=frozenset()):
    if not HOLDS_BUTTONS.search(text):
        return []
    derived_tokens = set(derived_tokens) | {t for t in TOKEN_DECL.findall(text) if t != "cornerRadius"}
    out = []
    for raw in text.splitlines():
        code = raw.split("//", 1)[0]
        if not code.strip() or ALLOW_SWIFT.search(raw):
            continue
        if not (SURFACE_CALL.search(code) or SURFACE_RADIUS.search(code)):
            continue
        if DERIVED.search(code) or any(re.search(r"\b%s\b" % token, code) for token in derived_tokens):
            continue
        out.append(raw.strip())
    return out


CSS_COMMENT = re.compile(r"/\*.*?\*/", re.S)
# A container class: its last word names one (`.share-dialog`, `.ui-notice`, `.acpmux-cloud-hint`), never a BEM
# element of one (`.pr-card__ref`).
CONTAINER_SUBJECT = re.compile(r"^[.#](?:[\w]+-)*[\w]*(?:dialog|toast|notice|hint|banner|sheet|prompt|tip|strip|card)$")
RADIUS_DECL = re.compile(r"(?<![\w-])border(?:-(?:top|bottom|start|end)-(?:left|right|start|end))?-radius\s*:\s*([^;}]*)")
CLOSE_SUBJECT = re.compile(r"^[.#][\w-]*(?:close|dismiss)$")
CLOSE_CSS_PASS = re.compile(r"--ds-radius-control\b")
KEYCAP_SUBJECT = re.compile(r"^(?:kbd|[.#][\w-]*(?:keycap|keyhint|kbd|shortcut-chip)[\w-]*)$")
CSS_PASS = re.compile(r"--ds-radius-control\b|--concentric-padding\b|--ui-dialog-padding\b")
CSS_KEYWORD = re.compile(r"^\s*(?:0|0px|inherit|unset|initial|50%|999px|9999px)\s*(?:!important)?\s*$")


def subject_is_keycap(selector):
    for part in selector.split(","):
        compound = re.split(r"\s*[\s>+~]\s*", part.strip())[-1] if part.strip() else ""
        compound = re.sub(r"::?[\w-]+(\([^)]*\))?|\[[^\]]*\]", "", compound)
        if any(KEYCAP_SUBJECT.match(c) for c in re.findall(r"^kbd\b|[.#][\w-]+", compound)):
            return True
    return False


def subject_is_close(selector):
    for part in selector.split(","):
        compound = re.split(r"\s*[\s>+~]\s*", part.strip())[-1] if part.strip() else ""
        compound = re.sub(r"::?[\w-]+(\([^)]*\))?|\[[^\]]*\]", "", compound)
        if any(CLOSE_SUBJECT.match(c) for c in re.findall(r"[.#][\w-]+", compound)):
            return True
    return False


def subject_is_container(selector):
    for part in selector.split(","):
        compound = re.split(r"\s*[\s>+~]\s*", part.strip())[-1] if part.strip() else ""
        compound = re.sub(r"::?[\w-]+(\([^)]*\))?|\[[^\]]*\]", "", compound)
        classes = re.findall(r"[.#][\w-]+", compound)
        if any(CONTAINER_SUBJECT.match(c) for c in classes):
            return True
    return False


def css_findings(text):
    allowed = {text.count("\n", 0, m.start()) + 1 for m in ALLOW_CSS.finditer(text)}
    bare = CSS_COMMENT.sub(lambda m: re.sub(r"[^\n]", " ", m.group()), text)
    out, stack, start = [], [], 0
    for index, char in enumerate(bare):
        if char == "{":
            stack.append(bare[start:index].strip().split(";")[-1].strip())
            start = index + 1
        elif char == "}":
            body = bare[start:index]
            if stack:
                selector = stack.pop()
                close = not selector.startswith("@") and subject_is_close(selector)
                if not selector.startswith("@") and (subject_is_container(selector) or subject_is_keycap(selector) or close):
                    for match in RADIUS_DECL.finditer(body):
                        value = match.group(1)
                        line = bare.count("\n", 0, start + match.start()) + 1
                        if line in allowed or CSS_PASS.search(value):
                            continue
                        # A round close x (50%) is not concentric with a rounded card: only the container keywords pass.
                        if CSS_KEYWORD.match(value) and not (close and "50%" in value):
                            continue
                        flat = " ".join(selector.split())[:100]
                        out.append(f"{flat} {{ border-radius: {' '.join(value.split())} }}")
            start = index + 1
    return out


def walk(root, base, suffix):
    for directory, dirs, files in os.walk(os.path.join(root, base)):
        dirs[:] = [d for d in dirs if d not in ("node_modules", "dist", "build", "__tests__", "test", "tests",
                                                 "gallery", "prototypes", "prototype", "Playground", "Debug")]
        for name in sorted(files):
            if name.endswith(suffix) and ".test." not in name and ".gallery" not in name and "Gallery" not in name \
                    and "Playground" not in name:
                path = os.path.join(directory, name)
                yield os.path.relpath(path, root).replace(os.sep, "/"), path


def findings(root):
    found = []
    sources = []
    for rel, path in walk(root, SWIFT_ROOT, ".swift"):
        with open(path, encoding="utf-8") as handle:
            sources.append((rel, handle.read()))
    # A corner token declared from the buttons anywhere (`BrowserMetrics.promptCornerRadius`) is derived everywhere.
    # The bare name `cornerRadius` is every view's own; it never counts as a token.
    derived = frozenset(token for _, text in sources for token in TOKEN_DECL.findall(text) if token != "cornerRadius")
    for rel, text in sources:
        found += [f"{rel}: {line}" for line in swift_findings(text, derived)]
        found += [f"{rel}: {line}" for line in close_swift_findings(text)]
        if KEYCAP_FILE.search(rel):
            found += [f"{rel}: {line}" for line in keycap_swift_findings(text)]
    for rel, path in walk(root, WEB_ROOT, ".css"):
        with open(path, encoding="utf-8") as handle:
            found += [f"{rel}: {line}" for line in css_findings(handle.read())]
    return found


def main(argv):
    args = [a for a in argv[1:] if not a.startswith("--")]
    root = os.path.abspath(args[0] if args else os.path.join(os.path.dirname(__file__), "..", ".."))
    found = findings(root)
    baseline_path = os.path.join(root, BASELINE)
    if "--write-baseline" in argv:
        with open(baseline_path, "w", encoding="utf-8") as handle:
            handle.write("# Containers with buttons that predate the concentric rule (check-concentric-containers.py).\n"
                         "# This list may only shrink: fix a surface (Metrics.buttonContainer / calc(var(--ds-radius-control) + pad))\n"
                         "# and remove its line.\n")
            handle.writelines(line + "\n" for line in sorted(set(found)))
        print(f"check-concentric-containers: wrote {len(set(found))} baseline line(s)")
        return 0
    known = set()
    if os.path.exists(baseline_path):
        with open(baseline_path, encoding="utf-8") as handle:
            known = {line.rstrip("\n") for line in handle if line.strip() and not line.startswith("#")}
    new = sorted(set(found) - known)
    gone = sorted(known - set(found))
    for line in new:
        print(f"  {line}")
    if new:
        print(f"check-concentric-containers: {len(new)} container corner(s) not concentric with their buttons. Round the "
              "container from them (Metrics.buttonContainer(padding:).outerRadius; CSS calc(var(--ds-radius-control) + "
              "<padding>)) or say why on the line (concentric-allow: <reason>).")
    for line in gone:
        print(f"  fixed, remove from {BASELINE}: {line}")
    if gone:
        print(f"check-concentric-containers: {len(gone)} baseline line(s) no longer found; the list only shrinks, "
              "remove them.")
    if new or gone:
        return 1
    print(f"check-concentric-containers: ok ({len(known)} known site(s) left in the baseline)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
