#!/usr/bin/env python3
"""Every animation of cmux NEXT, its duration and whether it reads the shared motion tokens.

Leo, 2026-11-10: "Like the slow animations, ugly, incoherent UI ... we need to be holding ourselves to high
standards." This module is the inventory behind two tools:

  scripts/cmux-next/motion-coverage.py     the nightly figure: tokened animations / all animations, per surface
  scripts/cmux-next/check-motion-tokens.py the lint: no new raw animation duration, no new raw colour outside
                                           the token files (a shrink-only baseline holds today's hits)

It reads source, no browser and no build, so it runs on any host in about a second.

Surfaces (SURFACES):
  native     Packages/macOS/CmuxNext/Sources. A site is a call into a Motion gate (`Motion.<category>.animate`,
             `.set`, `.animation(...)`, `gate.springAnimation()` ...: tokened, the gate's API takes only tokens)
             or a raw animation check-motion.sh lets through with `motion: allow` (untokened). The token
             definitions are Sources/CmuxNextDesignTokens/Motion (MotionTunables) and Sources/CmuxNextDesign/Motion.
  webviews   webviews/src (tests, galleries and generated files are not the app). A site is one layer of a CSS
             `transition` or `animation` (in a stylesheet or a script's string), a `transition-duration` or
             `animation-duration` item, a Tailwind `duration-N` class, or a Web Animations `.animate()` duration.
             Tokened: it resolves to `--cmux-motion-<step>`, a `--cmux-*-period` loop, or a script's `MOTION_*`
             constant, directly or through a page alias (`--agent-motion-in: var(--cmux-motion-micro)`).
  apps       first-party-apps/*/web-src and the acpmux web page (cmux-tui/crates/acpmux/web), read like webviews.
  rust       the spec's design-tokens.json `motion` (cmux-motion reads it at build time): token definitions only.

A duration is slow when it is a state change (not a loop, a spinner, a breath, a progress fill or a hover-intent
wait) that ends later than SLOW_MS. Off-scale means not 0 and not a step of schemas/motion-scale/motion-scale.json.
"""
from __future__ import annotations

import json
import math
import os
import re
from dataclasses import asdict, dataclass, field
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent

SLOW_MS = 200
LOOP_MIN_MS = 600

NATIVE_SOURCES = "Packages/macOS/CmuxNext/Sources"
NATIVE_TOKEN_DIRS = (f"{NATIVE_SOURCES}/CmuxNextDesign/Motion/", f"{NATIVE_SOURCES}/CmuxNextDesignTokens/Motion/")
WEB_TREES = {
    "webviews": ("webviews/src",),
    "apps": ("first-party-apps", "cmux-tui/crates/acpmux/web"),
}
WEB_SKIP_DIRS = {"gallery", "generated", "node_modules", "dist", "web", "test", "tests", "preview", "fixtures"}
# acpmux/web is a page root, not a build output.
WEB_KEEP_ROOTS = {"cmux-tui/crates/acpmux/web"}
WEB_SUFFIXES = (".css", ".ts", ".tsx", ".html")
WEB_SKIP_FILE = re.compile(r"\.(test|spec|gallery|experiment|stories)\.[^.]+$|\.d\.ts$|\.generated\.[^.]+$")
DESIGN_TOKENS = "plans/cmux-next/spec-proposals/visuals/design-tokens.json"
SCALE_JSON = "schemas/motion-scale/motion-scale.json"

# The places that define motion tokens: a duration there is the token itself.
WEB_MOTION_TOKEN_FILES = ("webviews/src/pages/shared/desktop.css", "webviews/src/motion/")

ALLOW = re.compile(r"motion(?::\s*allow|-allow:)\s*\S")


def load_scale(root: Path) -> dict:
    data = json.loads((root / SCALE_JSON).read_text())
    steps = {step["name"]: step["ms"] for step in data["steps"]}
    steps["send"] = data["send"]["ms"]
    steps["settle"] = data["settle"]["ms"]
    return {"steps": steps, "on_scale": {0, *steps.values()}, "spinner": data["spinner"]["ms"]}


@dataclass
class Site:
    surface: str
    file: str
    line: int
    text: str
    tokened: bool
    ms: float | None = None
    loop: bool = False  # a loop (spinner, breath, shimmer) or a hover-intent ramp: not a state change
    allowed: bool = False
    token: str | None = None
    kind: str = "site"  # "site" (an animation) or "def" (a token or constant that holds a duration)
    literal: bool = False  # a time typed as a literal here (not through a variable)

    @property
    def slow(self) -> bool:
        return self.ms is not None and self.ms > SLOW_MS and not self.loop


# --- Lexing helpers ----------------------------------------------------------------------------------------------

_SCRIPT_LEX = re.compile(r"""("(?:\\.|[^"\\\n])*"|'(?:\\.|[^'\\\n])*'|`(?:\\.|[^`\\])*`)|(/\*[\s\S]*?\*/|(?<!:)//[^\n]*)""")
_CSS_COMMENT = re.compile(r"/\*[\s\S]*?\*/")


def _blank(match: re.Match) -> str:
    return re.sub(r"[^\n]", " ", match.group(0))


def blank_comments(text: str, script: bool) -> str:
    """Comments blanked with spaces, newlines kept. Scripts: // and /* */ outside strings; CSS: /* */."""
    if not script:
        return _CSS_COMMENT.sub(_blank, text)
    return _SCRIPT_LEX.sub(lambda m: m.group(0) if m.group(1) else _blank(m), text)


TOKEN_EXPR = re.compile(r"\bMOTION_[A-Z_]+|\bSPINNER_PERIOD_MS\b|\bmotionMs\(|\bfoldMs\(|--cmux-motion-")


def substitute_js(text: str) -> str:
    """Each `${...}` of a template as var(--jstok) (it reads a motion token) or var(--js), lines kept."""
    def repl(match: re.Match) -> str:
        expr = match.group(1)
        marker = "var(--jstok)" if TOKEN_EXPR.search(expr) else "var(--js)"
        return marker + "\n" * expr.count("\n")
    return re.sub(r"\$\{([^{}]*(?:\{[^{}]*\}[^{}]*)*)\}", repl, text)


def split_top(value: str, sep: str) -> list[str]:
    parts, depth, start = [], 0, 0
    for i, ch in enumerate(value):
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
        elif depth == 0 and (ch == sep or (sep == " " and ch.isspace())):
            parts.append(value[start:i])
            start = i + 1
    parts.append(value[start:])
    return [p.strip() for p in parts if p.strip()]


TIME = re.compile(r"^(-?\d*\.?\d+)(ms|s)$", re.I)


def literal_ms(token: str) -> float | None:
    m = TIME.match(token.strip())
    if not m:
        return None
    return float(m.group(1)) * (1000 if m.group(2).lower() == "s" else 1)


VAR = re.compile(r"^var\(\s*(--[\w-]+)\s*(?:,([\s\S]*))?\)$")
DURATION_NAME = re.compile(r"motion|duration|period|fade|speed|-(?:in|out|open|close|hover|focus|move)\b", re.I)
NOT_DURATION_NAME = re.compile(r"ease|curve|spring|timing|bezier", re.I)
WAIT_NAME = re.compile(r"delay|intent|hold|dwell|wait|grace|timeout", re.I)
LOOP_NAME = re.compile(r"period|loop|spin|breath|pulse|shimmer|sweep|cycle|drift|wiggle", re.I)


def is_time_token(token: str) -> bool:
    if literal_ms(token) is not None:
        return True
    if token in ("var(--js)", "var(--jstok)") or re.match(r"^var\(--js(?:tok)?\)m?s$", token):
        return True
    if token.startswith("calc("):
        return bool(re.search(r"\d(?:ms|s)\b|var\(", token))
    m = VAR.match(token)
    if not m:
        return False
    if m.group(2) and m.group(2).strip():
        return is_time_token(m.group(2).strip())
    return bool(DURATION_NAME.search(m.group(1)) and not NOT_DURATION_NAME.search(m.group(1)))


@dataclass
class Resolved:
    tokened: bool
    ms: float | None
    token: str | None = None
    raw_literal: bool = False  # a literal time is typed here (not through a variable)


class WebDefs:
    """Every custom property definition across the scanned pages: name -> values."""

    def __init__(self, scale: dict):
        self.scale = scale
        self.defs: dict[str, list[str]] = {}

    def add(self, name: str, value: str) -> None:
        self.defs.setdefault(name, []).append(value.strip())

    def resolve(self, token: str, seen: frozenset = frozenset()) -> Resolved:
        token = token.strip()
        ms = literal_ms(token)
        if ms is not None:
            return Resolved(False, ms, raw_literal=True)
        if token in ("var(--jstok)",) or re.match(r"^var\(--jstok\)m?s$", token):
            return Resolved(True, None, "script token")
        if token == "var(--js)" or re.match(r"^var\(--js\)m?s$", token):
            return Resolved(False, None)
        if token.startswith("calc("):
            return self.resolve_calc(token, seen)
        m = VAR.match(token)
        if not m:
            return Resolved(False, None)
        name, fallback = m.group(1), (m.group(2) or "").strip() or None
        step = re.match(r"^--cmux-motion-([\w-]+)$", name)
        if step:
            return Resolved(True, self.scale["steps"].get(step.group(1)), name)
        if re.match(r"^--cmux-[\w-]*period$", name):
            return Resolved(True, self.scale["spinner"] if "spinner" in name else literal_ms(fallback or ""), name)
        if name.startswith("--cmux-") and name in self.defs and name not in seen:
            inner = [self.resolve(value, seen | {name}) for value in self.defs[name]]
            values = [r.ms for r in inner if r.ms is not None]
            return Resolved(True, max(values) if values else None, name)
        if name in self.defs and name not in seen:
            results = [self.resolve(value, seen | {name}) for value in self.defs[name]]
            # A 0 definition is an off switch (motion off, no entrance), not a duration of its own.
            results = [r for r in results if r.tokened or (r.ms is not None and r.ms >= 1)]
            if results:
                tokened = all(r.tokened for r in results)
                values = [r.ms for r in results if r.ms is not None]
                return Resolved(tokened, max(values) if values else None, next((r.token for r in results if r.token), None))
        if fallback:
            inner = self.resolve(fallback, seen)
            return Resolved(inner.tokened, inner.ms, inner.token, inner.raw_literal)
        return Resolved(False, None)

    def resolve_calc(self, token: str, seen: frozenset) -> Resolved:
        body = token[5:-1]
        parts = re.findall(r"var\([^()]*(?:\([^()]*\)[^()]*)*\)|-?\d*\.?\d+(?:ms|s)?|[*/+-]", body)
        tokened, raw_literal, values, ops = True, False, [], []
        for part in parts:
            if part in "*/+-" and len(part) == 1:
                ops.append(part)
                continue
            if part.startswith("var("):
                r = self.resolve(part, seen)
                tokened &= r.tokened
                values.append(r.ms)
                continue
            lit = literal_ms(part)
            if lit is not None:
                tokened, raw_literal = False, True
                values.append(lit)
            else:
                values.append(float(part))
        ms = values[0] if values else None
        for op, value in zip(ops, values[1:]):
            if ms is None or value is None:
                ms = None
                break
            ms = ms * value if op == "*" else ms / value if op == "/" else ms + value if op == "+" else ms - value
        # A token multiplied or offset off the scale is no longer the token.
        if tokened and ms is not None and round(ms) not in self.scale["on_scale"]:
            tokened = False
        token = next((self.resolve(p, seen).token for p in parts if p.startswith("var(")), None)
        return Resolved(tokened, ms, token, raw_literal)


DECLARATION_CSS = re.compile(
    r"(?<![\w-])(?:-webkit-)?(transition|transition-duration|animation|animation-duration|--[\w-]+)\s*:\s*([^;{}]*)")
DECLARATION_SCRIPT = re.compile(
    r"(?<![\w-])[\"']?(?:-webkit-)?(transition|transition-duration|animation|animation-duration|transitionDuration|"
    r"animationDuration|WebkitTransition|--[\w-]+)[\"']?"
    # `transition: ...` in a style object or CSS string, `el.style.transition = "..."`,
    # `style.setProperty("transition", "...")`.
    r"(?:\s*:|\s*=(?![=>])|\s*,)\s*([^;{}\n]*)")
TAILWIND = re.compile(r"(?<![\w-])duration-(\d+|\[[^\]\s]+\]|\([^)\s]+\))(?![\w-])")
SCRIPT_CONST = re.compile(r"\b(?:const|let|var)\s+([A-Z][A-Z0-9_]*_MS)\s*(?::\s*\w+\s*)?=\s*([^;\n]+)")
# test/motion-scale.ts MOTION_CONST: a constant named for a motion's length (a *_SETTLE_MS is a timer, not one).
MOTION_CONST = re.compile(r"(?:^|_)(?:FADE|FOLD|SHIFT|GLIDE|SLIDE|SWIPE|MOTION|ANIM|ANIMATION|TRANSITION)(?:_[A-Z]+)*_MS$")
# A hover-intent ramp or wait: the pointer's stay drives it, so it is not a state change (desktop.css
# --cmux-hover-reveal-in).
INTENT_NAME = re.compile(r"hover-reveal|dwell|intent", re.I)
CAMEL = {"transitionDuration": "transition-duration", "animationDuration": "animation-duration",
         "WebkitTransition": "transition"}
def _line_index(text: str):
    starts = [0]
    for m in re.finditer("\n", text):
        starts.append(m.end())
    import bisect
    return lambda offset: bisect.bisect_right(starts, offset)


def script_number(expr: str, consts: dict[str, str], depth: int = 0) -> tuple[bool, list[float]]:
    """(tokened, literal values) of a script expression: a number, a same-file constant, a MOTION_* read."""
    expr = expr.strip().rstrip(",")
    expr = re.sub(r"\s+as\s+const\b|\s+satisfies\s+\w+", "", expr)
    if TOKEN_EXPR.search(expr):
        return True, []
    if re.fullmatch(r"\d[\d_]*(?:\.\d+)?", expr):
        return False, [float(expr.replace("_", ""))]
    ternary = re.fullmatch(r"[^?]+\?\s*([^:]+):\s*(.+)", expr)
    if ternary and depth < 4:
        a = script_number(ternary.group(1), consts, depth + 1)
        b = script_number(ternary.group(2), consts, depth + 1)
        return a[0] and b[0] if (a[1] or b[1]) else a[0] or b[0], a[1] + b[1]
    if re.fullmatch(r"[A-Za-z_]\w*", expr) and expr in consts and depth < 4:
        return script_number(consts[expr], consts, depth + 1)
    return False, []


def scan_web_file(surface: str, rel: str, text: str, defs: WebDefs, out: list[Site]) -> None:
    script = rel.endswith((".ts", ".tsx"))
    body = blank_comments(text, script)
    if script:
        body = substitute_js(body)
    line_of = _line_index(body)
    lines = text.split("\n")
    token_file = rel.startswith(WEB_MOTION_TOKEN_FILES)

    def allowed(line: int) -> bool:
        here = lines[line - 1] if 0 < line <= len(lines) else ""
        above = lines[line - 2] if line > 1 else ""
        return bool(ALLOW.search(here) or (ALLOW.search(above) and above.strip().startswith(("/*", "//", "*"))))

    def add(line: int, snippet: str, res: Resolved, loop: bool, kind: str = "site") -> None:
        snippet = re.sub(r"\s+", " ", snippet.strip())[:160]
        loop = loop or bool(res.token and INTENT_NAME.search(res.token)) or bool(INTENT_NAME.search(snippet))
        out.append(Site(surface, rel, line, snippet, res.tokened, res.ms, loop, allowed(line), res.token, kind,
                        res.raw_literal))

    pattern = DECLARATION_SCRIPT if script else DECLARATION_CSS
    for m in pattern.finditer(body):
        value = m.group(2).strip()
        if script and value[:1] in "\"'`" and value.endswith(")"):
            value = value[:-1].strip()  # setProperty("transition", "opacity 120ms")
        prop, value = m.group(1), value.strip().strip("\"'`").strip()
        prop = CAMEL.get(prop, prop)
        line = line_of(m.start())
        if prop.startswith("--"):
            if not value or WAIT_NAME.search(prop):
                continue
            first = next((t for t in split_top(split_top(value, ",")[0], " ") if is_time_token(t)), None)
            if first is None:
                continue
            res = defs.resolve(first)
            if res.ms is not None and res.ms < 1:
                continue
            loop = bool(LOOP_NAME.search(prop)) or (res.ms is not None and res.ms >= LOOP_MIN_MS and not res.tokened)
            if token_file and rel.endswith(".css"):
                res = Resolved(True, res.ms, prop, res.raw_literal)
            add(line, f"{prop}: {value}", res, loop and (res.ms is None or res.ms >= LOOP_MIN_MS), "def")
            continue
        if value in ("none", "", "unset", "initial", "inherit"):
            continue
        items = split_top(value, ",")
        for item in items:
            tokens = split_top(item, " ")
            if prop.endswith("-duration"):
                duration = item if is_time_token(item) else None
            else:
                duration = next((t for t in tokens if is_time_token(t)), None)
            if duration is None:
                continue
            res = defs.resolve(duration)
            if res.ms is not None and res.ms < 1:
                continue
            loop = "infinite" in tokens or prop == "animation-duration" and (res.ms or 0) >= LOOP_MIN_MS
            if not loop and m.group(1).startswith("animation") and res.token and LOOP_NAME.search(res.token):
                loop = True
            add(line, f"{prop}: {item}", res, loop)
    for m in TAILWIND.finditer(body):
        raw = m.group(1)
        token = raw[1:-1] if raw.startswith("[") else f"var({raw[1:-1]})" if raw.startswith("(") else f"{raw}ms"
        res = defs.resolve(token)
        if res.ms is not None and res.ms < 1:
            continue
        add(line_of(m.start()), m.group(0), res, False)
    if not script:
        return
    consts = {m.group(1): m.group(2) for m in SCRIPT_CONST.finditer(body)}
    for m in re.finditer(r"\b(?:const|let|var)\s+([A-Za-z_]\w*)\s*(?::\s*\w+\s*)?=\s*([^;\n]+)", body):
        consts.setdefault(m.group(1), m.group(2))
    for m in SCRIPT_CONST.finditer(body):
        name = m.group(1)
        if not MOTION_CONST.search(name) or WAIT_NAME.search(name):
            continue
        tokened, values = script_number(m.group(2), consts)
        if not tokened and not values:
            continue
        ms = max(values) if values else None
        if ms is not None and ms < 1:
            continue
        add(line_of(m.start()), m.group(0), Resolved(tokened or token_file, ms, name if tokened else None, bool(values)),
            False, "def")
    for m in re.finditer(r"\.animate\??\.?\(", body):
        window = body[m.end():m.end() + 900]
        depth, end = 1, len(window)
        for i, ch in enumerate(window):
            if ch in "([{":
                depth += 1
            elif ch in ")]}":
                depth -= 1
                if depth == 0:
                    end = i
                    break
        call = window[:end]
        dur = re.search(r"\bduration\s*:\s*([^,}\n]+)", call)
        if dur is None:
            positional = re.search(r",\s*(\d[\d_]*)\s*$", call)
            if not positional:
                continue
            expr = positional.group(1)
        else:
            expr = dur.group(1)
        tokened, values = script_number(expr, consts)
        if not tokened and not values and re.fullmatch(r"\s*[A-Za-z_][\w.]*\s*", expr):
            # A parameter or computed value: dynamic.
            pass
        ms = max(values) if values else None
        if ms is not None and ms < 1:
            continue
        loop = bool(re.search(r"iterations\s*:\s*Infinity", call))
        add(line_of(m.start()), "animate(" + call.replace("\n", " ")[:120], Resolved(tokened, ms, None, bool(values)), loop)


def web_files(root: Path, trees: tuple[str, ...]) -> list[str]:
    files = []
    for tree in trees:
        base = root / tree
        if not base.exists():
            continue
        for directory, dirs, names in os.walk(base):
            rel_dir = os.path.relpath(directory, root).replace(os.sep, "/")
            dirs[:] = [d for d in dirs if d not in WEB_SKIP_DIRS or f"{rel_dir}/{d}" in WEB_KEEP_ROOTS]
            if tree == "first-party-apps" and "/web-src" not in rel_dir + "/" and rel_dir.count("/") >= 1:
                # first-party apps: only their web panes (web-src) draw UI with CSS.
                if not any(part == "web-src" for part in rel_dir.split("/")):
                    continue
            for name in names:
                if name.endswith(WEB_SUFFIXES) and not WEB_SKIP_FILE.search(name):
                    files.append(f"{rel_dir}/{name}")
    return sorted(files)


def scan_web(root: Path, scale: dict) -> list[Site]:
    defs = WebDefs(scale)
    texts: dict[str, tuple[str, str]] = {}
    for surface, trees in WEB_TREES.items():
        for rel in web_files(root, trees):
            try:
                text = (root / rel).read_text(encoding="utf-8")
            except (UnicodeDecodeError, OSError):
                continue
            texts[rel] = (surface, text)
            script = rel.endswith((".ts", ".tsx"))
            body = blank_comments(text, script)
            for m in re.finditer(r"(?<![\w-])(--[\w-]+)\s*:\s*([^;{}\n]*)", body):
                defs.add(m.group(1), m.group(2).strip().strip("\"'`"))
    sites: list[Site] = []
    for rel, (surface, text) in texts.items():
        scan_web_file(surface, rel, text, defs, sites)
    return sites


# --- Native ------------------------------------------------------------------------------------------------------

GATE_CALL = re.compile(
    r"(?:\bMotion\.[a-z]\w*|\b[a-z]\w*(?:Gate|gate|Motion|motion))\.(animate|animateTimed|animateExit|set|springAnimation|"
    r"scheduledFade|spinAnimation|stepAnimation|framesAnimation|pulseAnimation|flashAnimation|passOverAnimation|"
    r"crossfadeInPlace|animation|attentionAnimation|attentionGlowHold|revealLaunchMark|concealLaunchMark|"
    r"marqueeAnimation|sweepAnimation|wiggleAnimation|nudgeAnimation|transaction|sampledKeyframes|moveAnimation)\(")
LOOP_CALL = re.compile(r"spinAnimation|pulseAnimation|flashAnimation|marqueeAnimation|sweepAnimation|wiggleAnimation|"
                       r"nudgeAnimation|passOverAnimation|stepAnimation|framesAnimation")
RAW_NATIVE = re.compile(
    r"\b(CABasicAnimation|CASpringAnimation|CAKeyframeAnimation|CATransition|CAAnimationGroup)\(|"
    r"\bNSAnimationContext\.(runAnimationGroup|animate)\b|\bwithAnimation\s*[({]|"
    r"(?<![A-Za-z0-9_\)])\.animation\((?!forKey:)(?![^\n]*\bMotion\.[a-z][A-Za-z]*\.animation\()|"
    r"\.(transition|contentTransition|symbolEffect|matchedGeometryEffect)\(|\b(phaseAnimator|keyframeAnimator)\b|"
    r"\.animator\(\)")
NATIVE_PREFILTER = re.compile(r"nimat|[Mm]otion|[Gg]ate\.|ransition|Effect|CA[A-Z]")
NATIVE_ALLOW = re.compile(r"//\s*motion(:\s*allow|-allow:)\s*\S")
NATIVE_LITERAL = re.compile(r"(?<![\w.])(\d*\.\d+|\d+)\b")


def swift_code(line: str) -> str:
    if "//" not in line:
        return line
    in_string = False
    for i, ch in enumerate(line):
        if ch == '"':
            in_string = not in_string
        elif not in_string and line.startswith("//", i):
            return line[:i]
    return line


def scan_native(root: Path) -> list[Site]:
    base = root / NATIVE_SOURCES
    sites: list[Site] = []
    if not base.exists():
        return sites
    for directory, _, names in os.walk(base):
        for name in names:
            if not name.endswith(".swift"):
                continue
            path = Path(directory) / name
            rel = path.relative_to(root).as_posix()
            if rel.startswith(NATIVE_TOKEN_DIRS):
                continue
            lines = path.read_text(encoding="utf-8").splitlines()
            for index, line in enumerate(lines):
                stripped = line.strip()
                if stripped.startswith(("//", "*", "///")):
                    continue
                if not NATIVE_PREFILTER.search(line):
                    continue
                code = swift_code(line)
                allowed = bool(NATIVE_ALLOW.search(line) or (index and NATIVE_ALLOW.search(lines[index - 1])))
                gate = GATE_CALL.findall(code)
                for member in gate:
                    sites.append(Site("native", rel, index + 1, stripped[:160], True, None,
                                      bool(LOOP_CALL.search(member)), allowed, member))
                if not gate and RAW_NATIVE.search(code):
                    window = "\n".join(swift_code(l) for l in lines[max(0, index - 40):index + 41])
                    if ".animator()" in code and re.search(r"\bMotion\.|\bgate\.", window) and not allowed:
                        continue  # an .animator() change inside a gate's group: counted at the gate call
                    if not allowed:
                        continue  # check-motion.sh fails these; nothing unmarked survives on a green base
                    sites.append(Site("native", rel, index + 1, stripped[:160], False, None, False, True))
    return sites


def spring_visible_end(response: float, damping: float) -> float:
    """Seconds until a unit step stays within 0.5% of its target (SpringParameters.perceivedDuration)."""
    omega = 2 * math.pi / max(response, 0.001)
    zeta = damping
    dt, t, last = 1 / 480, 0.0, 0.0
    while t < 3:
        t += dt
        if zeta < 1:
            wd = omega * math.sqrt(1 - zeta * zeta)
            x = 1 - math.exp(-zeta * omega * t) * (math.cos(wd * t) + zeta * omega / wd * math.sin(wd * t))
        elif zeta == 1:
            x = 1 - math.exp(-omega * t) * (1 + omega * t)
        else:
            r1 = -omega * (zeta - math.sqrt(zeta * zeta - 1))
            r2 = -omega * (zeta + math.sqrt(zeta * zeta - 1))
            x = 1 - (r2 * math.exp(r1 * t) - r1 * math.exp(r2 * t)) / (r2 - r1)
        if abs(1 - x) > 0.005:
            last = t
        if t > last + 0.25:
            break
    return last


AMBIENT_NATIVE = {"highlight", "hibernateRing", "focusFlash"}  # MotionScaleTests.ambientFades


def native_tokens(root: Path, scale: dict) -> list[Site]:
    """MotionTunables' fades, springs and loops, with their lengths."""
    path = root / NATIVE_SOURCES / "CmuxNextDesignTokens/Motion/MotionTunables.swift"
    out: list[Site] = []
    if not path.exists():
        return out
    rel = path.relative_to(root).as_posix()
    steps = {f"MotionScale.{k}": v for k, v in scale["steps"].items()}
    steps["MotionScale.spinnerPeriod"] = scale["spinner"]
    section = None
    for index, line in enumerate(path.read_text().splitlines()):
        if "springDefaults:" in line:
            section = "spring"
        elif "fadeDefaults:" in line:
            section = "fade"
        elif "loopDefaults:" in line:
            section = "loop"
        elif line.strip() == "]":
            section = None
        if section == "spring":
            m = re.search(r"\.(\w+):\s*\(SpringParameters\(response:\s*([\d.]+),\s*dampingFraction:\s*([\d.]+)\)", line)
            if m:
                end = spring_visible_end(float(m.group(2)), float(m.group(3))) * 1000
                out.append(Site("native", rel, index + 1, f"spring .{m.group(1)} response {m.group(2)} "
                                f"(ends visibly at {end:.0f} ms)", True, round(end), False, False, f"spring.{m.group(1)}", "def"))
        elif section in ("fade", "loop"):
            m = re.search(r"\.(\w+):\s*\(([\w.]+),", line)
            if m:
                value = m.group(2)
                ms = steps.get(value)
                tokened = ms is not None
                if ms is None:
                    try:
                        ms = float(value) * 1000
                    except ValueError:
                        continue
                loop = section == "loop" or m.group(1) in AMBIENT_NATIVE
                out.append(Site("native", rel, index + 1, f"{section} .{m.group(1)} = {value}", tokened, ms, loop,
                                False, f"{section}.{m.group(1)}", "def"))
    return out


def rust_tokens(root: Path, scale: dict) -> list[Site]:
    path = root / DESIGN_TOKENS
    out: list[Site] = []
    if not path.exists():
        return out
    motion = json.loads(path.read_text()).get("motion", {})
    on_scale = scale["on_scale"]
    for name, entry in motion.get("springs", {}).items():
        value = entry["value"]
        end = round(spring_visible_end(value["response"], value["dampingFraction"]) * 1000)
        out.append(Site("rust", DESIGN_TOKENS, 0, f"motion.springs.{name} response {value['response']} "
                        f"(ends visibly at {end} ms)", True, end, False, False, f"springs.{name}", "def"))
    for name, entry in motion.get("tweens", {}).items():
        if not isinstance(entry, dict) or not isinstance(entry.get("value"), dict):
            continue
        ms = entry["value"]["duration"] * 1000
        out.append(Site("rust", DESIGN_TOKENS, 0, f"motion.tweens.{name} = {ms:g} ms {entry['value'].get('curve')}",
                        round(ms) in on_scale, ms, False, False, f"tweens.{name}", "def"))
    for name, value in motion.get("fades", {}).items():
        value = value.get("value") if isinstance(value, dict) else value
        if not isinstance(value, (int, float)):
            continue
        ms = value * 1000
        out.append(Site("rust", DESIGN_TOKENS, 0, f"motion.fades.{name} = {ms:g} ms", round(ms) in on_scale, ms,
                        name in AMBIENT_NATIVE, False, f"fades.{name}", "def"))
    for name, value in motion.get("loops", {}).items():
        value = value.get("value") if isinstance(value, dict) else value
        if not isinstance(value, (int, float)):
            continue
        out.append(Site("rust", DESIGN_TOKENS, 0, f"motion.loops.{name} = {value * 1000:g} ms", True, value * 1000,
                        True, False, f"loops.{name}", "def"))
    return out


# --- The inventory -----------------------------------------------------------------------------------------------

@dataclass
class Inventory:
    sites: list[Site] = field(default_factory=list)

    def by_surface(self) -> dict[str, list[Site]]:
        out: dict[str, list[Site]] = {}
        for site in self.sites:
            out.setdefault(site.surface, []).append(site)
        return out


def inventory(root: Path = REPO) -> Inventory:
    scale = load_scale(root)
    sites = scan_native(root) + native_tokens(root, scale) + scan_web(root, scale) + rust_tokens(root, scale)
    return Inventory(sites)


def coverage(inv: Inventory, scale_on: set | None = None) -> dict:
    surfaces = {}
    total_sites = total_tokened = 0
    for surface, sites in sorted(inv.by_surface().items()):
        anims = [s for s in sites if s.kind == "site"]
        defs = [s for s in sites if s.kind == "def"]
        tokened = sum(1 for s in anims if s.tokened)
        total_sites += len(anims)
        total_tokened += tokened
        surfaces[surface] = {
            "animations": len(anims),
            "tokened": tokened,
            "coverage": round(tokened / len(anims), 4) if anims else None,
            "loops": sum(1 for s in anims if s.loop),
            "allowed": sum(1 for s in anims if s.allowed),
            "slow": sum(1 for s in anims if s.slow),
            "token_defs": len(defs),
            "token_defs_slow": sum(1 for s in defs if s.slow),
        }
    slow = [
        {"surface": s.surface, "file": s.file, "line": s.line, "ms": s.ms, "kind": s.kind, "tokened": s.tokened,
         "allowed": s.allowed, "text": s.text}
        for s in sorted(inv.sites, key=lambda s: (-(s.ms or 0), s.file, s.line)) if s.slow
    ]
    return {
        "schema": "cmux-next.motion-coverage/1",
        "slow_ms": SLOW_MS,
        "coverage": round(total_tokened / total_sites, 4) if total_sites else None,
        "animations": total_sites,
        "tokened": total_tokened,
        "surfaces": surfaces,
        "slow": slow,
    }


# --- Raw colours -------------------------------------------------------------------------------------------------

COLOUR_TREES = ("webviews/src", NATIVE_SOURCES)
# Theme data and the colour token definitions: a literal colour there is the token itself (check-system-blue.py SKIP,
# plus the files that define the page and native tokens).
COLOUR_TOKEN_PATHS = (
    "webviews/src/theme/", "webviews/src/syntax-colors.ts", "webviews/src/appearance.ts", "webviews/src/pierre-options.ts",
    "webviews/src/find/", "webviews/src/gallery/", "webviews/src/pages/shared/desktop.css", "webviews/src/styles.css",
    "webviews/src/agent-session/shared/styles.css", "webviews/src/agent-session/shared/agentBrands.generated.ts",
    "webviews/src/agent-session/acpmux/diffTheme.ts", "webviews/src/agent-session/acpmux/projectGlyphs.tsx",
    "webviews/src/agent-session/acpmux-preview/", "webviews/src/agent-session/acpmux/prototype/",
    "webviews/src/pages/settings/mockThemes.ts", "webviews/src/prototypes/",
    f"{NATIVE_SOURCES}/CmuxNextDesignTokens/", f"{NATIVE_SOURCES}/CmuxNextDesign/GroupColor",
    f"{NATIVE_SOURCES}/CmuxNextDesign/ThemeRGB", f"{NATIVE_SOURCES}/CmuxNextSettings/Schema/SettingsSchema+Samples.generated.swift",
)
COLOUR_TOKEN_NAME = re.compile(r"(?:Palette|Theme|Colors?|Tokens?)(?:\+\w+)?\.swift$|[Mm]ock|Fixture|Demo|Playground")
# A reviewed exception: `colour-allow: <reason>` (or `color-allow:`) on the line.
COLOUR_ALLOW = re.compile(r"colou?r-allow:\s*\S")
HEX = re.compile(r"(?<![\w&#-])#(?:[0-9a-fA-F]{8}|[0-9a-fA-F]{6}|[0-9a-fA-F]{3,4})(?![\w-])")
FUNC_COLOUR = re.compile(r"(?<![\w-])(?:rgba?|hsla?|hwb|oklch|oklab|lab|lch)\(\s*(?!var\(|from\b)[\d.+-]")
SWIFT_COLOUR = re.compile(
    r"\b(?:NSColor|UIColor|Color|CGColor|SwiftUI\.Color)\s*\(\s*(?:calibrated|srgb|device|displayP3)?"
    r"(?:[Rr]ed|[Ww]hite|[Hh]ue|[Gg]ray|hex|genericGamma22White)\s*:"
    r"|\bCGColor\(\s*(?:srgbRed|gray|red|genericGrayGamma2_2Gray)\s*:|\b(?:NSColor|Color)\(\s*hex\b"
    r"|(?<![\w.])\.init\(\s*(?:srgb|calibrated|device)?[Rr]ed:\s*[\d.]")


def colour_files(root: Path) -> list[str]:
    files = []
    for tree in COLOUR_TREES:
        for directory, dirs, names in os.walk(root / tree):
            dirs[:] = [d for d in dirs if d not in WEB_SKIP_DIRS]
            for name in names:
                if not name.endswith((".swift", ".css", ".ts", ".tsx")) or WEB_SKIP_FILE.search(name):
                    continue
                rel = (Path(directory) / name).relative_to(root).as_posix()
                if rel.startswith(COLOUR_TOKEN_PATHS) or COLOUR_TOKEN_NAME.search(name):
                    continue
                files.append(rel)
    return sorted(files)


def raw_colours(root: Path = REPO) -> dict[str, list[tuple[int, str]]]:
    out: dict[str, list[tuple[int, str]]] = {}
    for rel in colour_files(root):
        text = (root / rel).read_text(encoding="utf-8", errors="replace")
        swift = rel.endswith(".swift")
        body = blank_comments(text, not rel.endswith(".css")) if not swift else "\n".join(
            "" if l.strip().startswith(("//", "*")) else swift_code(l) for l in text.splitlines())
        hits = []
        text_lines = text.splitlines()
        for index, line in enumerate(body.split("\n")):
            if swift:
                found = SWIFT_COLOUR.findall(line)
            elif rel.endswith(".css"):
                # A stylesheet's declarations are check-design-tokens.ts's; a page-local palette
                # (`--x: #fff` outside the token files) is this ratchet's.
                found = []
                for m in re.finditer(r"(?<![\w-])--[\w-]+\s*:\s*([^;{}]*)", line):
                    value = re.sub(r"var\([^()]*(?:\([^()]*\)[^()]*)*\)", " ", m.group(1))
                    found += HEX.findall(value) + FUNC_COLOUR.findall(value)
            else:
                # A script: colours inside string literals or CSS templates.
                found = HEX.findall(line) + FUNC_COLOUR.findall(line)
                found = [f for f in found if re.search(r"[\"'`][^\"'`]*" + re.escape(f), line)]
            if found and COLOUR_ALLOW.search(text_lines[index] if index < len(text_lines) else ""):
                found = []
            if found:
                hits.append((index + 1, line.strip()[:140]))
        if hits:
            out[rel] = hits
    return out


def raw_durations(inv: Inventory) -> dict[str, list[Site]]:
    """Web durations typed as literals outside the token files, and off-scale native and Rust token values."""
    out: dict[str, list[Site]] = {}
    for site in inv.sites:
        raw = False
        if site.surface in ("webviews", "apps"):
            raw = not site.tokened and not site.allowed and (site.ms is not None) and not (site.loop and site.kind == "def")
            # A literal in a webviews stylesheet declaration is webviews/scripts/check-design-tokens.ts's
            # (its own shrink-only baseline); this one takes what that ratchet cannot see: custom property
            # definitions, tokens multiplied off the scale, script strings, Web Animations and constants.
            if raw and site.surface == "webviews" and site.file.endswith(".css") and site.kind == "site" and site.literal:
                raw = False
        elif site.kind == "def" and site.surface in ("native", "rust"):
            raw = not site.tokened and not site.loop and bool(site.ms)
        # Loops (spinners, breaths, shimmers) and hover-intent ramps are not state changes: off the scale.
        raw = raw and not site.loop
        if raw:
            out.setdefault(site.file, []).append(site)
    return out


def as_json(sites: list[Site]) -> list[dict]:
    return [asdict(s) | {"slow": s.slow} for s in sites]
