#!/usr/bin/env python3
"""Leo's bans: the UI font of cmux NEXT is Inter, bundled, with its calculated tracking.

Leo (2026-10-21, ask-52da478628): "WE ALREADY HAD THE FONTS. WE SAID INTER, WITH SOME AMOUNT [of
tracking], AND WE BUNDLED SOME STUFF IN." The UI font and the tracking table are pinned in
schemas/type-scale/leo-bans.json. This check fails when:

  family     the UI family in schemas/type-scale/type-scale.json is not the pinned one
  tracking   the tracking constants (a + b * e^(c * size), em) or a step's tracking differ from the pin,
             or the pin's table is not what its constants give
  css        `--font-ui` in the generated CSS (webviews/src/pages/shared/desktop.css) does not start
             with the pinned family, or a step's `--text-<step>--letter-spacing` differs from the pin
  swift      TypeScale.generated.swift does not name the pinned family and tracking, or CheckedFont
             no longer draws the default design in the bundled face (`BundledFonts.uiFont`)
  bundle     the bundled font files are missing, or the TTF's family is not the pinned one
  system-ui  a webviews stylesheet names the system font (system-ui, -apple-system,
             BlinkMacSystemFont) instead of `var(--font-ui)`; monospace stacks never name them. The
             fallback of `var(--font-ui, ...)` may, for a page that loads no desktop.css
  pin        schemas/type-scale/leo-bans.json changed (with --base) and no commit of the range that
             touches it carries a `Leo-order: <Leo's words>` trailer

    python3 scripts/cmux-next/check-leo-bans.py                  # the working tree
    python3 scripts/cmux-next/check-leo-bans.py --rev HEAD       # a commit, read from git
    python3 scripts/cmux-next/check-leo-bans.py --rev HEAD --base origin/feat-cmux-next
    python3 scripts/cmux-next/check-leo-bans.py --repo DIR ...

CMUX_NEXT_CHECKS_SKIP_REASON does not skip it (prepush-gate.py); only a Leo-order trailer changes the pin.
"""
from __future__ import annotations

import argparse
import json
import math
import os
import re
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

TYPE_SCALE = "schemas/type-scale/type-scale.json"
PIN = "schemas/type-scale/leo-bans.json"
CSS = "webviews/src/pages/shared/desktop.css"
SWIFT = "Packages/macOS/CmuxNext/Sources/CmuxNextDesign/TypeScale.generated.swift"
CHECKED_FONT = "Packages/macOS/CmuxNext/Sources/CmuxNextDesign/CheckedFont.swift"
FONTS = "Packages/macOS/CmuxNext/Sources/CmuxNextDesign/Resources/Fonts/"
WEB_ROOT = "webviews/src/"
BEGIN = "/* type-scale:begin."
END = "/* type-scale:end */"
SYSTEM_FONT = re.compile(r"(?<![\w-])(system-ui|-apple-system|BlinkMacSystemFont)(?![\w-])")
CSS_COMMENT = re.compile(r"/\*.*?\*/", re.S)
LEO_ORDER = re.compile(r"^Leo-order:\s*\S", re.M)
FONT_UI_FALLBACK = re.compile(r"var\(\s*--font-ui\s*,[^()]*\)")


class Tree:
    """Files of the working tree (rev None) or of one commit."""

    def __init__(self, repo: Path, rev: str | None):
        self.repo, self.rev = repo, rev
        self.cache: dict[str, bytes | None] = {}
        self.listed: dict[tuple[str, str], list[str]] = {}

    def read(self, path: str) -> bytes | None:
        if self.rev is None:
            full = self.repo / path
            return full.read_bytes() if full.is_file() else None
        if path not in self.cache:
            self.load([path])
        return self.cache[path]

    def load(self, paths: list[str]) -> None:
        """Reads `paths` at the rev with one `git cat-file --batch` (missing ones read as None)."""
        wanted = [p for p in paths if p not in self.cache]
        if not wanted:
            return
        request = "".join(f"{self.rev}:{p}\n" for p in wanted).encode()
        # The request goes through a file, never `input=` (git_batch.py): over a pipe, Python can
        # block writing it while git blocks writing a big blob back, and the push hangs for good.
        with tempfile.TemporaryFile() as stdin:
            stdin.write(request)
            stdin.seek(0)
            out = subprocess.run(["git", "-C", str(self.repo), "cat-file", "--batch"], stdin=stdin,
                                 capture_output=True).stdout
        cursor = 0
        for path in wanted:
            end = out.index(b"\n", cursor)
            header = out[cursor:end].split()
            cursor = end + 1
            if len(header) < 3 or header[1] != b"blob":
                self.cache[path] = None
                continue
            size = int(header[2])
            self.cache[path] = out[cursor:cursor + size]
            cursor += size + 1

    def text(self, path: str) -> str | None:
        data = self.read(path)
        return None if data is None else data.decode("utf-8", errors="replace")

    def files(self, prefix: str, suffix: str) -> list[str]:
        if (prefix, suffix) not in self.listed:
            self.listed[(prefix, suffix)] = self.list(prefix, suffix)
        return self.listed[(prefix, suffix)]

    def list(self, prefix: str, suffix: str) -> list[str]:
        if self.rev is None:
            base = self.repo / prefix
            found = []
            for root, dirs, names in os.walk(base):
                dirs[:] = [d for d in dirs if d != "node_modules"]
                for name in names:
                    if name.endswith(suffix):
                        found.append(os.path.relpath(os.path.join(root, name), self.repo).replace(os.sep, "/"))
            return sorted(found)
        out = subprocess.run(["git", "-C", str(self.repo), "ls-tree", "-r", "-z", "--name-only", self.rev, "--", prefix],
                             capture_output=True).stdout.decode()
        return sorted(p for p in out.split("\0") if p.endswith(suffix) and "/node_modules/" not in p)


def tracking(constants: dict, size: float) -> float:
    return round(constants["a"] + constants["b"] * math.exp(constants["c"] * size), 4)


def ttf_family(data: bytes) -> str | None:
    """The family (name ID 1, Windows platform) of a TrueType/OpenType font."""
    try:
        count = struct.unpack(">H", data[4:6])[0]
        for i in range(count):
            tag, _, offset, _ = struct.unpack(">4sIII", data[12 + 16 * i:28 + 16 * i])
            if tag != b"name":
                continue
            _, records, strings = struct.unpack(">HHH", data[offset:offset + 6])
            for j in range(records):
                at = offset + 6 + 12 * j
                platform, _, _, name_id, length, start = struct.unpack(">HHHHHH", data[at:at + 12])
                if platform == 3 and name_id == 1:
                    begin = offset + strings + start
                    return data[begin:begin + length].decode("utf-16-be")
    except (struct.error, UnicodeDecodeError):
        return None
    return None


def check_tree(tree: Tree) -> list[str]:
    findings: list[str] = []
    if tree.rev is not None:
        # One git read for every file the check needs (a loaded machine takes seconds per git call).
        tree.load([PIN, TYPE_SCALE, CSS, SWIFT, CHECKED_FONT, FONTS + "InterVariable.ttf", FONTS + "InterVariable.woff2"]
                  + tree.files(WEB_ROOT, ".css"))
    pin_text, scale_text = tree.text(PIN), tree.text(TYPE_SCALE)
    if pin_text is None:
        return [f"{PIN}: missing (the pinned UI font and tracking)"]
    if scale_text is None:
        return [f"{TYPE_SCALE}: missing"]
    pin, scale = json.loads(pin_text), json.loads(scale_text)
    family, file_family = pin["uiFont"]["family"], pin["uiFont"]["fileFamily"]
    constants, table = pin["tracking"], pin["trackingTable"]

    # family and tracking in the one source
    font = scale.get("font", {})
    if font.get("family") != family or font.get("fileFamily") != file_family:
        findings.append(f"{TYPE_SCALE}: UI font is {font.get('family')!r} ({font.get('fileFamily')!r}); "
                        f"Leo's is {family!r} ({file_family!r})")
    scale_tracking = scale.get("tracking", {})
    for key in ("a", "b", "c"):
        if scale_tracking.get(key) != constants[key]:
            findings.append(f"{TYPE_SCALE}: tracking.{key} is {scale_tracking.get(key)!r}; Leo's is {constants[key]!r}")
    steps = {step["name"]: step for step in scale.get("steps", [])}
    if sorted(steps) != sorted(table):
        findings.append(f"{TYPE_SCALE}: steps {sorted(steps)} differ from the pinned tracking table {sorted(table)}")
    for name, step in steps.items():
        if name in table and step.get("tracking") != table[name]:
            findings.append(f"{TYPE_SCALE}: step {name} tracking is {step.get('tracking')!r}; Leo's is {table[name]!r}")
        if name in table and tracking(constants, step["size"]) != table[name]:
            findings.append(f"{PIN}: trackingTable.{name} is {table[name]!r}, but the pinned constants give "
                            f"{tracking(constants, step['size'])!r} at {step['size']}")

    # generated CSS
    css = tree.text(CSS) or ""
    block = css[css.find(BEGIN):css.find(END)] if BEGIN in css and END in css else ""
    stack = re.search(r"--font-ui:\s*([^;]+);", block)
    first = stack.group(1).split(",")[0].strip().strip("\"'") if stack else None
    if first != family:
        findings.append(f"{CSS}: --font-ui starts with {first!r}; it must start with {family!r}")
    for name, value in table.items():
        found = re.search(r"--text-%s--letter-spacing:\s*(-?[\d.]+)em;" % re.escape(name), block)
        if not found or float(found.group(1)) != value:
            findings.append(f"{CSS}: --text-{name}--letter-spacing is {found.group(1) + 'em' if found else None}; "
                            f"Leo's is {value}em")

    # generated Swift and the native font path
    swift = tree.text(SWIFT) or ""
    for name, value in (("family", family), ("fileFamily", file_family)):
        found = re.search(r"public static let %s = \"([^\"]*)\"" % name, swift)
        if not found or found.group(1) != value:
            findings.append(f"{SWIFT}: TypeScale.{name} is {found.group(1) if found else None!r}; Leo's is {value!r}")
    for key in ("a", "b", "c"):
        found = re.search(r"public static let tracking%s: CGFloat = (-?[\d.]+)" % key.upper(), swift)
        if not found or float(found.group(1)) != constants[key]:
            findings.append(f"{SWIFT}: TypeScale.tracking{key.upper()} is {found.group(1) if found else None}; "
                            f"Leo's is {constants[key]}")
    if "BundledFonts.uiFont(" not in (tree.text(CHECKED_FONT) or ""):
        findings.append(f"{CHECKED_FONT}: the default design no longer draws in the bundled UI font (BundledFonts.uiFont)")

    # the bundled files
    files = font.get("files", {})
    native = tree.read(FONTS + files.get("native", "")) if files.get("native") else None
    if native is None:
        findings.append(f"{FONTS}: the bundled TTF {files.get('native')!r} is missing")
    elif ttf_family(native) != file_family:
        findings.append(f"{FONTS}{files['native']}: its family is {ttf_family(native)!r}; Leo's is {file_family!r}")
    web = tree.read(FONTS + files.get("web", "")) if files.get("web") else None
    if web is None or not web.startswith(b"wOF2"):
        findings.append(f"{FONTS}: the bundled WOFF2 {files.get('web')!r} is missing or not WOFF2")

    # no stylesheet names the system font
    for path in tree.files(WEB_ROOT, ".css"):
        text = tree.text(path) or ""
        if path == CSS and BEGIN in text and END in text:
            start, stop = text.index(BEGIN), text.index(END)
            text = text[:start] + re.sub(r"[^\n]", " ", text[start:stop]) + text[stop:]
        text = CSS_COMMENT.sub(lambda m: re.sub(r"[^\n]", " ", m.group(0)), text)
        text = FONT_UI_FALLBACK.sub(lambda m: re.sub(r"[^\n]", " ", m.group(0)), text)
        for number, line in enumerate(text.split("\n"), 1):
            hit = SYSTEM_FONT.search(line)
            if hit:
                findings.append(f"{path}:{number}: names the system font ({hit.group(1)}); use var(--font-ui)")
    return findings


def check_pin(repo: Path, base: str, head: str) -> list[str]:
    if Tree(repo, base).read(PIN) == Tree(repo, head).read(PIN):
        return []
    log = subprocess.run(["git", "-C", str(repo), "log", "--format=%B%x00", f"{base}..{head}", "--", PIN],
                         capture_output=True)
    if log.returncode != 0:
        return [f"{PIN}: changed, and the commits of {base}..{head} could not be read "
                f"({log.stderr.decode(errors='replace').strip()}); fetch the range"]
    if any(LEO_ORDER.search(message) for message in log.stdout.decode(errors="replace").split("\0")):
        return []
    return [f"{PIN}: changed in {base[:12]}..{head[:12]} with no `Leo-order: <Leo's words>` trailer on a commit "
            "that touches it. Only Leo changes the UI font or its tracking."]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repo", default=None)
    parser.add_argument("--rev", help="check this commit (default: the working tree)")
    parser.add_argument("--base", help="also require a Leo-order trailer when the pin changed since BASE")
    args = parser.parse_args(argv)
    repo = Path(args.repo).resolve() if args.repo else Path(__file__).resolve().parents[2]
    findings = check_tree(Tree(repo, args.rev))
    if args.base:
        findings += check_pin(repo, args.base, args.rev or "HEAD")
    for finding in findings:
        print(finding)
    if findings:
        print(f"leo bans: {len(findings)} finding(s). The UI font is Inter with its calculated tracking "
              f"({PIN}); change it only with Leo's order.")
        return 1
    print("leo bans: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
