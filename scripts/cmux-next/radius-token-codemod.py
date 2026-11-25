#!/usr/bin/env python3
"""Swap raw on-scale `border-radius` literals in webviews CSS onto the radius tokens, only where the swap
provably keeps every pixel.

The radius tokens (`--ds-radius-sm|md|lg|xl|2xl`, webviews/src/pages/shared/desktop.css) are flat px at
`:root`, but pageDensity.css rescales them under `:root:has(.settings)` and `:root[data-page-density]`, and
pages/settings/look.css redefines them for Settings' refined look. A literal never scales, so a swap keeps
its value only in a stylesheet whose every document

  (a) loads desktop.css (otherwise the token is undefined and the radius drops to 0), and
  (b) can never hold a `.settings` element (SettingsApp.tsx) or set `data-page-density` (diffSurface.tsx),
      so the tokens there are always desktop.css's flat values and look.css never applies.

The script builds the module graph (ES imports, dynamic import(), `new URL(.., import.meta.url)`,
import.meta.glob, CSS @import, HTML script/link) from every product entry (the HTML pages and
vite.config.ts's JS inputs; the gallery, browser tests and benches are not products), marks each entry
by what it can reach, and swaps only in CSS files every one of whose entries passes (a) and (b).

Only whole px words in a radius declaration are swapped (`6px`, `6px 6px 0 0`, `8px / 4px`); a value with
a function (calc, var, max, ...) is left alone, and so are 14px and 18px (their tokens, --ds-radius-card
and --ds-radius-composer, are named for a planned move, so the swap would not be a pure variable swap).

  radius-token-codemod.py --root REPO            apply
  radius-token-codemod.py --root REPO --check    dry run: print the safe set and counts, write nothing
  radius-token-codemod.py --root REPO --why FILE explain one stylesheet's verdict
"""
from __future__ import annotations

import argparse
import glob as globlib
import os
import re
import sys
from pathlib import Path

TOKENS = {4: "--ds-radius-sm", 6: "--ds-radius-md", 8: "--ds-radius-lg", 12: "--ds-radius-xl", 16: "--ds-radius-2xl"}
RADIUS_PROPERTY = re.compile(r"^border(?:-(?:top|bottom|start|end)-(?:left|right|start|end))?-radius$")
EXTS = ("", ".ts", ".tsx", ".js", ".mjs", ".jsx", ".css", "/index.ts", "/index.tsx", "/index.js")

JS_SPEC = re.compile(
    r"""(?:\bimport\s*(?:[\w*{}\s,$]+?\s*from\s*)?|\bexport\s*[\w*{}\s,$]+?\s*from\s*|\bimport\s*\(\s*)["']([^"'\n]+)["']"""
)
JS_URL = re.compile(r"""new\s+URL\(\s*["']([^"'\n]+)["']\s*,\s*import\.meta\.url""")
JS_GLOB = re.compile(r"""import\.meta\.glob(?:<[^>]*>)?\(\s*(\[[^\]]*\]|["'][^"']+["'])""", re.S)
CSS_IMPORT = re.compile(r"""@import\s+(?:url\()?\s*["']?([^"')\s;]+)""")
HTML_REF = re.compile(r"""<(?:script|link)\b[^>]*?\b(?:src|href)\s*=\s*["']([^"']+)["']""")
COMMENT = re.compile(r"/\*.*?\*/", re.S)


def strip_js_comments(text: str) -> str:
    text = COMMENT.sub("", text)
    return re.sub(r"(?m)^\s*//.*$", "", text)


class Graph:
    def __init__(self, web: Path):
        self.web = web
        self.edges: dict[Path, set[Path]] = {}

    def resolve(self, base: Path, spec: str) -> Path | None:
        spec = spec.split("?")[0].split("#")[0]
        if spec.startswith("/"):
            cand = self.web / spec.lstrip("/")
        elif spec.startswith("."):
            cand = base.parent / spec
        else:
            return None  # a package
        for ext in EXTS:
            p = Path(os.path.normpath(str(cand) + ext))
            if p.is_file():
                return p
        return None

    def deps(self, f: Path) -> set[Path]:
        if f in self.edges:
            return self.edges[f]
        out: set[Path] = set()
        self.edges[f] = out
        try:
            text = f.read_text(encoding="utf-8", errors="replace")
        except OSError:
            return out
        specs: list[str] = []
        if f.suffix == ".css":
            specs = CSS_IMPORT.findall(COMMENT.sub("", text))
        elif f.suffix == ".html":
            specs = HTML_REF.findall(text)
        else:
            code = strip_js_comments(text)
            specs = JS_SPEC.findall(code) + JS_URL.findall(code)
            for arg in JS_GLOB.findall(code):
                for pat in re.findall(r"""["']([^"']+)["']""", arg):
                    if pat.startswith("!"):
                        continue
                    root = f.parent if pat.startswith(".") else self.web
                    for hit in globlib.glob(str(root / pat.lstrip("/")), recursive=True):
                        out.add(Path(os.path.normpath(hit)))
        for spec in specs:
            p = self.resolve(f, spec)
            if p is not None:
                out.add(p)
        return out

    def reach(self, entry: Path) -> set[Path]:
        seen = {entry}
        stack = [entry]
        while stack:
            for d in self.deps(stack.pop()):
                if d not in seen and d.suffix in (".ts", ".tsx", ".js", ".mjs", ".jsx", ".css", ".html"):
                    seen.add(d)
                    stack.append(d)
        return seen


def product_entries(web: Path) -> list[Path]:
    skip = ("node_modules", "dist", "bench", "test", "gallery")
    entries = []
    for p in sorted(web.rglob("*.html")):
        rel = p.relative_to(web).parts
        if any(part in skip for part in rel[:-1]) or any(part.startswith("dist") for part in rel):
            continue
        entries.append(p)
    # vite.config.ts's JS inputs (the agent session bundle and its workers).
    config = (web / "vite.config.ts").read_text()
    for spec in re.findall(r"""^\s*["']?[\w-]+["']?\s*:\s*["'](src/[^"']+\.(?:tsx?|mjs|js))["']""", config, re.M):
        if (web / spec).is_file():
            entries.append(web / spec)
    return entries


def analyze(root: Path):
    web = root / "webviews"
    src = web / "src"
    g = Graph(web)
    desktop_css = src / "pages/shared/desktop.css"
    density_sources = {src / "pages/settings/components/SettingsApp.tsx", src / "surfaces/diffSurface.tsx",
                       src / "pages/settings/look.css"}
    verdict: dict[Path, list[tuple[Path, str]]] = {}
    for entry in product_entries(web):
        reached = g.reach(entry)
        problems = []
        if desktop_css not in reached:
            problems.append("no desktop.css")
        hits = sorted(str(d.relative_to(src)) for d in density_sources & reached)
        if hits:
            problems.append("density/redefinition: " + ", ".join(hits))
        if entry.suffix == ".html" and "data-page-density" in entry.read_text():
            problems.append("data-page-density in html")
        why = "; ".join(problems) or "ok"
        for f in reached:
            if f.suffix == ".css":
                verdict.setdefault(f, []).append((entry, why))
    return src, verdict


DECL = re.compile(r"(?P<prop>[-a-zA-Z]+)\s*:\s*(?P<value>[^;{}]*?)(?P<end>\s*(?:!important\s*)?[;}])")
WORD = re.compile(r"(?<![\w.-])(\d+)px(?![\w.-])")


def swap_text(text: str) -> tuple[str, int, list[tuple[str, str]]]:
    """Swaps in one stylesheet, comments untouched. Returns the new text, the count and (before, after)."""
    out, pos, count, pairs = [], 0, 0, []
    pieces = re.split(r"(/\*.*?\*/)", text, flags=re.S)
    for piece in pieces:
        if piece.startswith("/*"):
            out.append(piece)
            continue

        def repl(m: re.Match) -> str:
            nonlocal count
            prop, value = m.group("prop"), m.group("value")
            if not RADIUS_PROPERTY.match(prop.lower()) or "(" in value:
                return m.group(0)
            words = re.split(r"(\s+|/)", value.strip())
            if not all(w == "" or w.isspace() or w == "/" or re.fullmatch(r"0|\d+(?:\.\d+)?(?:px|%)", w) for w in words):
                return m.group(0)
            local = 0

            def tok(w: re.Match) -> str:
                nonlocal local
                n = int(w.group(1))
                if n in TOKENS:
                    local += 1
                    return f"var({TOKENS[n]})"
                return w.group(0)

            new_value = WORD.sub(tok, value)
            if not local:
                return m.group(0)
            count += local
            pairs.append((f"{prop}: {value.strip()}", f"{prop}: {new_value.strip()}"))
            return m.group(0).replace(value, new_value, 1)

        out.append(DECL.sub(repl, piece))
    return "".join(out), count, pairs


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[2])
    ap.add_argument("--check", action="store_true", help="dry run: print the safe set and counts")
    ap.add_argument("--why", help="print one stylesheet's entries and verdicts")
    args = ap.parse_args()
    root = args.root.resolve()
    src, verdict = analyze(root)
    if args.why:
        f = Path(os.path.normpath(root / args.why))
        for entry, why in sorted(verdict.get(f, [])):
            print(f"{entry.relative_to(root)}: {why}")
        return 0
    safe = sorted(f for f, rows in verdict.items() if all(why == "ok" for _, why in rows)
                  and src in f.parents and f.name != "desktop.css")
    total = 0
    for f in safe:
        text = f.read_text(encoding="utf-8")
        new, n, _ = swap_text(text)
        if not n:
            continue
        total += n
        print(f"{n:4d}  {f.relative_to(root)}")
        if not args.check:
            f.write_text(new, encoding="utf-8")
    unsafe = sum(1 for f in verdict if f not in safe)
    print(f"{'would swap' if args.check else 'swapped'} {total} literals; {len(safe)} stylesheets value-safe, "
          f"{unsafe} not (density, a token redefinition, or no desktop.css in some entry)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
