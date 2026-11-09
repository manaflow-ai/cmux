#!/usr/bin/env python3
"""The UI font of cmux NEXT is the macOS system font, everywhere, with no bundled face before it.

Lawrence (2026-11-07): "default fonts on cmux for everything should be macos default, not inter, this applies to
everything, including markdown viewer, chat trajectory etc". The stack is pinned in
schemas/type-scale/ui-font-pin.json. This check fails when:

  stack     the font stack in schemas/type-scale/type-scale.json is not the pinned one
  css       `--font-ui` in the generated CSS (webviews/src/pages/shared/desktop.css) is not the pinned stack, or a
            step's `--text-<step>--letter-spacing` is not 0em (SF Pro carries its own size-specific tracking)
  bundle    the app bundles an Inter font file again (CmuxNextDesign/Resources)
  inter     a default font stack in the webviews or the OptChat inspector names Inter. The chat's opt-in Inter
            choice (chatUiFont.ts, chatFonts/) and the font study gallery may
  pin       schemas/type-scale/ui-font-pin.json changed (with --base) and no commit of the range that touches it
            carries a `Font-order: <the user's words>` trailer (a `Leo-order:` one, from before, also counts)

    python3 scripts/cmux-next/check-ui-font.py                  # the working tree
    python3 scripts/cmux-next/check-ui-font.py --rev HEAD       # a commit, read from git
    python3 scripts/cmux-next/check-ui-font.py --rev HEAD --base origin/feat-cmux-next
    python3 scripts/cmux-next/check-ui-font.py --repo DIR ...

CMUX_NEXT_CHECKS_SKIP_REASON does not skip it (prepush-gate.py); only a Font-order trailer changes the pin.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

TYPE_SCALE = "schemas/type-scale/type-scale.json"
PIN = "schemas/type-scale/ui-font-pin.json"
CSS = "webviews/src/pages/shared/desktop.css"
DESIGN_RESOURCES = "Packages/macOS/CmuxNext/Sources/CmuxNextDesign/Resources/"
# Where a default font stack may live: the webviews' sources and the OptChat inspector's page.
STACK_ROOTS = ("webviews/src/", "Native/OptChat/")
STACK_SUFFIXES = (".css", ".ts", ".tsx", ".mjs", ".html")
# The chat's opt-in Inter choice and the galleries that compare faces name Inter on purpose.
INTER_ALLOWED = re.compile(r"(^|/)(chatUiFont\.ts|chatFonts/|fontStudy/)|\.gallery\.")
BEGIN = "/* type-scale:begin."
END = "/* type-scale:end */"
INTER_FAMILY = re.compile(r"""(["'])Inter\1|(?<![\w"'.-])Inter(?=\s*[,;)])""")
FONT_FILE = re.compile(r"(^|/)Inter[^/]*\.(ttf|otf|woff2?)$", re.I)
BLOCK_COMMENT = re.compile(r"/\*.*?\*/", re.S)
HTML_COMMENT = re.compile(r"<!--.*?-->", re.S)
LINE_COMMENT = re.compile(r"(?<![:\"'])//.*$", re.M)
FONT_ORDER = re.compile(r"^(Font|Leo)-order:\s*\S", re.M)


class Tree:
    """Files of the working tree (rev None) or of one commit."""

    def __init__(self, repo: Path, rev: str | None):
        self.repo, self.rev = repo, rev
        self.cache: dict[str, bytes | None] = {}

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
        if not wanted or self.rev is None:
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

    def files(self, prefix: str) -> list[str]:
        if self.rev is None:
            found = []
            for root, dirs, names in os.walk(self.repo / prefix):
                dirs[:] = [d for d in dirs if d not in ("node_modules", "dist")]
                found += [os.path.relpath(os.path.join(root, n), self.repo).replace(os.sep, "/") for n in names]
            return sorted(found)
        out = subprocess.run(["git", "-C", str(self.repo), "ls-tree", "-r", "-z", "--name-only", self.rev, "--", prefix],
                             capture_output=True).stdout.decode()
        return sorted(p for p in out.split("\0") if p and "/node_modules/" not in p)


def blank(match: re.Match) -> str:
    """The match with every character but newlines blanked, so line numbers stay."""
    return re.sub(r"[^\n]", " ", match.group(0))


def check_tree(tree: Tree) -> list[str]:
    findings: list[str] = []
    stack_files = [p for root in STACK_ROOTS for p in tree.files(root)
                   if p.endswith(STACK_SUFFIXES) and not INTER_ALLOWED.search(p)]
    tree.load([PIN, TYPE_SCALE, CSS] + stack_files)
    pin_text, scale_text = tree.text(PIN), tree.text(TYPE_SCALE)
    if pin_text is None:
        return [f"{PIN}: missing (the pinned UI font)"]
    if scale_text is None:
        return [f"{TYPE_SCALE}: missing"]
    stack = json.loads(pin_text)["stack"]
    scale = json.loads(scale_text)

    found = scale.get("font", {}).get("stack")
    if found != stack:
        findings.append(f"{TYPE_SCALE}: the UI font stack is {found!r}; the pinned one is {stack!r}")

    css = tree.text(CSS) or ""
    block = css[css.find(BEGIN):css.find(END)] if BEGIN in css and END in css else ""
    font_ui = re.search(r"--font-ui:\s*([^;]+);", block)
    wanted = ", ".join(stack)
    if not font_ui or font_ui.group(1).strip() != wanted:
        findings.append(f"{CSS}: --font-ui is {font_ui.group(1).strip() if font_ui else None!r}; it must be {wanted!r}")
    for step in scale.get("steps", []):
        spacing = re.search(r"--text-%s--letter-spacing:\s*([^;]+);" % re.escape(step["name"]), block)
        value = spacing.group(1).strip() if spacing else None
        if value not in ("0em", "0", "normal"):
            findings.append(f"{CSS}: --text-{step['name']}--letter-spacing is {value}; the system font takes 0em")

    for path in tree.files(DESIGN_RESOURCES):
        if FONT_FILE.search(path):
            findings.append(f"{path}: the app bundles Inter again; the UI font is the system font")

    for path in stack_files:
        text = tree.text(path) or ""
        text = BLOCK_COMMENT.sub(blank, text)
        text = HTML_COMMENT.sub(blank, text)
        if not path.endswith(".css"):
            text = LINE_COMMENT.sub(blank, text)
        for number, line in enumerate(text.split("\n"), 1):
            if INTER_FAMILY.search(line):
                findings.append(f"{path}:{number}: names Inter in a font stack; the UI font is var(--font-ui), "
                                "the system font")
    return findings


def check_pin(repo: Path, base: str, head: str) -> list[str]:
    if Tree(repo, base).read(PIN) == Tree(repo, head).read(PIN):
        return []
    log = subprocess.run(["git", "-C", str(repo), "log", "--format=%B%x00", f"{base}..{head}", "--", PIN],
                         capture_output=True)
    if log.returncode != 0:
        return [f"{PIN}: changed, and the commits of {base}..{head} could not be read "
                f"({log.stderr.decode(errors='replace').strip()}); fetch the range"]
    if any(FONT_ORDER.search(message) for message in log.stdout.decode(errors="replace").split("\0")):
        return []
    return [f"{PIN}: changed in {base[:12]}..{head[:12]} with no `Font-order: <the user's words>` trailer on a "
            "commit that touches it. Only the user's order changes the UI font."]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repo", default=None)
    parser.add_argument("--rev", help="check this commit (default: the working tree)")
    parser.add_argument("--base", help="also require a Font-order trailer when the pin changed since BASE")
    args = parser.parse_args(argv)
    repo = Path(args.repo).resolve() if args.repo else Path(__file__).resolve().parents[2]
    findings = check_tree(Tree(repo, args.rev))
    if args.base:
        findings += check_pin(repo, args.base, args.rev or "HEAD")
    for finding in findings:
        print(finding)
    if findings:
        print(f"ui font: {len(findings)} finding(s). The UI font is the macOS system font ({PIN}); change it only "
              "on the user's order.")
        return 1
    print("ui font: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
