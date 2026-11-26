#!/usr/bin/env python3
"""Swap raw on-scale `border-radius` literals in webviews CSS onto the radius tokens, only where the swap
provably keeps every pixel.

The radius tokens (`--ds-radius-sm|md|lg|xl|2xl`, webviews/src/pages/shared/desktop.css) are flat px at
`:root`, but pageDensity.css rescales them under `:root:has(.settings)` and `:root[data-page-density]`, and
pages/settings/look.css redefines them for Settings' refined look. A literal never scales, so a swap keeps
its value only in a stylesheet whose every document

  (a) loads desktop.css (otherwise the token is undefined and the radius drops to 0), and
  (b) can never hold a `.settings` element (SettingsApp.tsx) or set `data-page-density` (diffSurface.tsx),
      so the tokens there are always desktop.css's flat values and look.css never applies, and
  (c) is not a surface a shipped look restyles with its own radius tokens: examples/looks/*/<surface>/*.css
      and the cmux-customize-recipes apps (Lamina's agent pane sets --ds-radius-md: 4px, Hairline's ties it
      to --cmux-button-radius), so a literal there would follow the look after a swap. Today that is the
      agent pane (every entry under src/agent-session/); a look surface the script cannot map fails closed.

The script builds the module graph (ES imports, dynamic import(), `new URL(.., import.meta.url)`,
import.meta.glob, CSS @import, HTML script/link) from every product entry (the HTML pages and
vite.config.ts's JS inputs; the gallery, browser tests and benches are not products), marks each entry
by what it can reach, and swaps only in CSS files every one of whose entries passes (a) and (b).

A declaration check-concentric-containers.py lists (its baseline keys a site by the literal's text) keeps its
literal: that debt is fixed by deriving the corner from --ds-radius-control, not by a swap.

Only whole px words in a radius declaration are swapped (`6px`, `6px 6px 0 0`, `8px / 4px`); a value with
a function (calc, var, max, ...) is left alone, and so are 14px and 18px (their tokens, --ds-radius-card
and --ds-radius-composer, are named for a planned move, so the swap would not be a pure variable swap).

  radius-token-codemod.py --root REPO            apply
  radius-token-codemod.py --root REPO --check    dry run: print the safe set and counts, write nothing
  radius-token-codemod.py --root REPO --why FILE explain one stylesheet's verdict
  radius-token-codemod.py --root REPO --prove REV  after applying: every changed radius declaration since REV
                                                 resolves (token -> desktop.css's :root value) to the same px,
                                                 and no stylesheet any of its entries loads redefines a token
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


# A look's surface folder -> the entries whose documents load that surface's look CSS.
LOOK_SURFACES = {"agent-pane": "src/agent-session/"}
TOKEN_DEF = re.compile(r"--ds-radius-(?:sm|md|lg|xl|2xl)\s*:")


def look_themed_prefixes(root: Path) -> list[str]:
    """The entry prefixes a shipped look restyles with its own radius tokens. Exits on an unmapped surface."""
    surfaces: set[str] = set()
    for css in (root / "examples/looks").glob("*/*/*.css"):
        if TOKEN_DEF.search(css.read_text(errors="replace")):
            surfaces.add(css.parent.name)
    for css in (root / "cmux-tui/crates/cmux-customize-recipes/recipes").rglob("*.css"):
        if TOKEN_DEF.search(css.read_text(errors="replace")):
            surfaces.add(css.stem)
    unknown = surfaces - LOOK_SURFACES.keys()
    if unknown:
        sys.exit(f"radius-token-codemod: looks redefine the radius tokens on {sorted(unknown)}; map them in LOOK_SURFACES")
    return [LOOK_SURFACES[s] for s in sorted(surfaces)]


def analyze(root: Path):
    web = root / "webviews"
    src = web / "src"
    g = Graph(web)
    desktop_css = src / "pages/shared/desktop.css"
    density_sources = {src / "pages/settings/components/SettingsApp.tsx", src / "surfaces/diffSurface.tsx",
                       src / "pages/settings/look.css"}
    themed = look_themed_prefixes(root)
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
        rel = str(entry.relative_to(web))
        if any(rel.startswith(prefix) for prefix in themed):
            problems.append("a shipped look redefines the radius tokens here")
        why = "; ".join(problems) or "ok"
        for f in reached:
            if f.suffix == ".css":
                verdict.setdefault(f, []).append((entry, why))
    return src, verdict


DECL = re.compile(r"(?P<prop>[-a-zA-Z]+)\s*:\s*(?P<value>[^;{}]*?)(?P<end>\s*(?:!important\s*)?[;}])")
WORD = re.compile(r"(?<![\w.-])(\d+)px(?![\w.-])")


def concentric_checker(root: Path):
    """check-concentric-containers.py's css_findings: its baseline keys a site by the declaration's text, so a
    swap at a listed site would read as a new site. Those declarations keep their literal."""
    import importlib.util

    path = root / "scripts/cmux-next/check-concentric-containers.py"
    spec = importlib.util.spec_from_file_location("check_concentric_containers", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.css_findings


def swap_text(text: str, css_findings=None) -> tuple[str, int, list[tuple[str, str]]]:
    """Swaps in one stylesheet, comments untouched. Returns the new text, the count and (before, after)."""
    bare = COMMENT.sub(lambda m: re.sub(r"[^\n]", " ", m.group()), text)
    edits = []  # (start, end, new value, literals swapped, before, after)
    for m in DECL.finditer(bare):
        prop, value = m.group("prop"), m.group("value")
        if not RADIUS_PROPERTY.match(prop.lower()) or "(" in value:
            continue
        words = re.split(r"(\s+|/)", value.strip())
        if not all(w == "" or w.isspace() or w == "/" or re.fullmatch(r"0|\d+(?:\.\d+)?(?:px|%)", w) for w in words):
            continue
        local = 0

        def tok(w: re.Match) -> str:
            nonlocal local
            n = int(w.group(1))
            if n in TOKENS:
                local += 1
                return f"var({TOKENS[n]})"
            return w.group(0)

        new_value = WORD.sub(tok, value)
        if local:
            edits.append((m.start("value"), m.end("value"), new_value, local,
                          f"{prop}: {value.strip()}", f"{prop}: {new_value.strip()}"))

    def apply(chosen) -> str:
        out, pos = [], 0
        for a, b, v, *_ in chosen:
            out.append(text[pos:a])
            out.append(v)
            pos = b
        out.append(text[pos:])
        return "".join(out)

    if css_findings is not None:
        before = sorted(css_findings(text))
        edits = [e for e in edits if sorted(css_findings(apply([e]))) == before]
    return apply(edits), sum(e[3] for e in edits), [(e[4], e[5]) for e in edits]


def declarations(text: str) -> list[tuple[str, str]]:
    text = COMMENT.sub("", text)
    return [(m.group("prop").lower(), " ".join(m.group("value").split())) for m in DECL.finditer(text)]


def prove(root: Path, src: Path, verdict, rev: str) -> int:
    import subprocess

    desktop = (src / "pages/shared/desktop.css").read_text()
    flat = {}
    for name in TOKENS.values():
        defs = re.findall(re.escape(name) + r"\s*:\s*([^;]+);", COMMENT.sub("", desktop))
        if len(defs) != 1 or not re.fullmatch(r"\d+px", defs[0].strip()):
            print(f"FAIL {name}: desktop.css defines it {defs!r}, not once as a flat px")
            return 1
        flat[name] = defs[0].strip()
    changed = subprocess.run(["git", "-C", str(root), "diff", "--name-only", rev, "--", "webviews/src"],
                             capture_output=True, text=True, check=True).stdout.split()
    failures = checked = 0
    for rel in changed:
        if not rel.endswith(".css"):
            continue
        f = root / rel
        before = subprocess.run(["git", "-C", str(root), "show", f"{rev}:{rel}"], capture_output=True,
                                text=True, check=True).stdout
        old, new = declarations(before), declarations(f.read_text())
        if len(old) != len(new):
            print(f"FAIL {rel}: declaration count {len(old)} -> {len(new)}")
            failures += 1
            continue
        for (p0, v0), (p1, v1) in zip(old, new):
            if (p0, v0) == (p1, v1):
                continue
            resolved = re.sub(r"var\((--ds-radius-[a-z0-9]+)\)", lambda m: flat.get(m.group(1), m.group(0)), v1)
            checked += 1
            if p0 != p1 or not RADIUS_PROPERTY.match(p0) or resolved != v0:
                print(f"FAIL {rel}: {p0}: {v0} -> {p1}: {v1} (resolves to {resolved})")
                failures += 1
        # Every document that loads this sheet: desktop.css loaded, no other sheet redefining a radius token.
        rows = verdict.get(f.resolve(), [])
        if not rows or any(why != "ok" for _, why in rows):
            print(f"FAIL {rel}: entries {rows}")
            failures += 1
    g = Graph(root / "webviews")
    redefiners = sorted(str(p.relative_to(root)) for p in (src.rglob("*.css")) if p.name != "desktop.css"
                        and TOKEN_DEF.search(COMMENT.sub("", p.read_text(errors="replace"))))
    touched = {(root / r).resolve() for r in changed}
    for entry in product_entries(root / "webviews"):
        reached = g.reach(entry)
        if reached & touched:
            bad = [r for r in redefiners if (root / r).resolve() in reached]
            if bad:
                print(f"FAIL {entry.relative_to(root)} loads a touched sheet and {bad}")
                failures += 1
    print(f"{checked} changed radius declarations in {len(changed)} files; {failures} failures; "
          f"token values {flat}; sheets redefining the tokens (none loaded beside a touched sheet): {redefiners}")
    return 1 if failures else 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[2])
    ap.add_argument("--check", action="store_true", help="dry run: print the safe set and counts")
    ap.add_argument("--why", help="print one stylesheet's entries and verdicts")
    ap.add_argument("--prove", metavar="REV", help="prove the swaps since REV keep every radius")
    args = ap.parse_args()
    root = args.root.resolve()
    src, verdict = analyze(root)
    if args.prove:
        return prove(root, src, verdict, args.prove)
    if args.why:
        f = Path(os.path.normpath(root / args.why))
        for entry, why in sorted(verdict.get(f, [])):
            print(f"{entry.relative_to(root)}: {why}")
        return 0
    safe = sorted(f for f, rows in verdict.items() if all(why == "ok" for _, why in rows)
                  and src in f.parents and f.name != "desktop.css")
    total = 0
    css_findings = concentric_checker(root)
    for f in safe:
        text = f.read_text(encoding="utf-8")
        new, n, _ = swap_text(text, css_findings)
        if not n:
            continue
        total += n
        print(f"{n:4d}  {f.relative_to(root)}")
        if not args.check:
            f.write_text(new, encoding="utf-8")
    unsafe = sum(1 for f in verdict if f not in safe)
    print(f"{'would swap' if args.check else 'swapped'} {total} literals; {len(safe)} stylesheets value-safe, "
          f"{unsafe} not (density, a token redefinition, a look, or no desktop.css in some entry)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
