#!/usr/bin/env python3
"""The design-system census of cmux NEXT: the numbers a design-system cleanup is measured by.

Leo, 2026-11-22: "idk what the state of our design systems are"; "the shifting projects and sizing of stuff
... we need to prevent this once and for all". Every cleanup PR quotes this command's table before and after,
from the same harness. It is not a gate: it only counts (the ratchets that refuse new debt are
webviews/scripts/check-design-tokens.ts and
scripts/cmux-next/check-design-scale-parity.py).

What it counts:
  webviews/src (skipping *.generated.*, node_modules, dist), in two buckets: `main`, and `other` (galleries,
  prototypes and tests: a gallery/ or prototypes/ or prototype/ or test/ folder, or a *.gallery.*, *.test.*,
  *.spec.* or *.stories.* file), with `all` for both:
    CSS declarations outside comments: border-radius (and its corner longhands) split into token-only, mixed
    (a var() and a literal), raw literal, capsule (>= 999px or 50%) and zero/keyword, the raw values' distinct
    count and how many are off the scale's radii (schemas/design-scale/design-scale.json `radii` and the px of
    `namedRadii`); the distinct custom properties defined (per prefix, and by radius|corner, shadow|elevation,
    blur|glass in the name); box-shadow (none, token-only, literal, distinct literals); backdrop-filter;
    z-index; padding/margin/gap with a px off the 4 px grid; raw colour literals outside custom-property
    definitions and var() fallbacks. TS/TSX: colour literals in strings, and the primitives (`<button` vs
    `<Button`, `title=` vs `<Tooltip`, `<input`/`<textarea` vs `<Input`, *.gallery.ts(x) files).
  Packages/macOS/CmuxNext/Sources, design packages (CmuxNextDesign, CmuxNextDesignTokens) apart from the rest:
    numeric non-zero `cornerRadius` literals, numeric `zPosition` literals, NSVisualEffectView and
    NSGlassEffectView uses, the Glass/Material types declared, and references to `DesignTokens.`.
  The ratchet baselines' sizes.

    python3 -I scripts/cmux-next/design-system-census.py           # the table
    python3 -I scripts/cmux-next/design-system-census.py --json    # the same numbers as JSON
    python3 -I scripts/cmux-next/design-system-census.py --root DIR

Tests: scripts/cmux-next/tests/test_design_system_guards.py.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
from collections import Counter

REPO = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
WEB = "webviews/src"
SWIFT = "Packages/macOS/CmuxNext/Sources"
SCALE = "schemas/design-scale/design-scale.json"
DESIGN_PACKAGES = ("CmuxNextDesign", "CmuxNextDesignTokens")
SKIP_DIRS = {"node_modules", "dist", ".git"}
OTHER_DIRS = {"gallery", "prototypes", "prototype", "test", "tests", "__tests__"}
OTHER_FILE = re.compile(r"\.(?:gallery|test|spec|stories)\.")
BASELINES = (
    "webviews/scripts/design-tokens-baseline.jsonl",
    "webviews/scripts/icon-scale-baseline.tsv",
    "scripts/cmux-next/layers-baseline.tsv",
    "scripts/cmux-next/type-scale-baseline.tsv",
    "scripts/cmux-next/swift-type-scale-baseline.tsv",
    "scripts/cmux-next/motion-tokens-baseline.tsv",
    "scripts/cmux-next/concentric-containers-baseline.txt",
)

# --- CSS -------------------------------------------------------------------------------------------------------

RADIUS_PROPERTY = re.compile(r"^border(?:-(?:top|bottom|start|end)-(?:left|right|start|end))?-radius$")
SPACING_PROPERTY = re.compile(r"^(?:padding|margin)(?:-(?:block|inline|top|right|bottom|left)(?:-(?:start|end))?)?$"
                              r"|^(?:gap|row-gap|column-gap)$")
NOT_COLOR_PROPERTY = re.compile(r"^(?:(?:-webkit-)?mask(?:-[a-z-]+)?|content|quotes|grid-template-areas"
                                r"|font-feature-settings|font-variation-settings|counter-\w+)$")
KEYWORDS = {"inherit", "initial", "unset", "revert", "revert-layer", "none", "auto"}
HEX = re.compile(r"#(?:[0-9a-fA-F]{3,4}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})\b")
COLOR_FUNCTION = re.compile(r"\b(?:rgba?|hsla?|hwb|lab|lch|oklab|oklch|color)\(", re.I)
# A length or a bare number (a radius of `4` is not valid CSS, but `50%` and `1.5em` are values).
NUMBER = re.compile(r"(?<![\w.#-])(-?(?:\d+\.?\d*|\.\d+))(px|%|r?em|ch|vh|vw)?(?![\w.])", re.I)
UI_PX = re.compile(r"calc\(\s*(-?(?:\d+\.?\d*|\.\d+))\s*\*\s*var\(\s*--ui-px\s*(?:,\s*1px\s*)?\)\s*\)", re.I)
CAPSULE_PX = 999
SECTION = "§"


def strip_css_comments(text: str) -> str:
    """`text` with each /* */ comment blanked (its newlines kept, so line numbers hold)."""
    return re.sub(r"/\*.*?\*/", lambda m: re.sub(r"[^\n]", " ", m.group(0)), text, flags=re.S)


def parse_css(text: str) -> list[tuple[str, str, str]]:
    """(selector, property, value) of every declaration, comments stripped, whitespace in a value collapsed."""
    text = strip_css_comments(text)
    out: list[tuple[str, str, str]] = []
    stack: list[str] = []
    buf: list[str] = []
    i = 0
    while i < len(text):
        ch = text[i]
        if ch in "\"'":
            end = text.find(ch, i + 1)
            end = len(text) - 1 if end < 0 else end
            buf.append(text[i:end + 1])
            i = end + 1
            continue
        if ch == "{":
            stack.append(" ".join("".join(buf).split()))
            buf = []
        elif ch in ";}":
            raw = "".join(buf).strip()
            buf = []
            colon = raw.find(":")
            if stack and colon > 0 and not stack[-1].startswith("@"):
                prop = raw[:colon].strip().lower()
                value = " ".join(raw[colon + 1:].split())
                value = re.sub(r"\s*!important$", "", value, flags=re.I)
                if re.fullmatch(r"-?-?[a-zA-Z][\w-]*", prop):
                    out.append((stack[-1], prop, value))
            if ch == "}" and stack:
                stack.pop()
        else:
            buf.append(ch)
        i += 1
    return out


def without_vars(value: str) -> str:
    """`value` with every var(...) call (fallback included) replaced by the section sign."""
    out = []
    i = 0
    while i < len(value):
        if value.startswith("var(", i):
            depth = 0
            while i < len(value):
                if value[i] == "(":
                    depth += 1
                elif value[i] == ")":
                    depth -= 1
                    if depth == 0:
                        break
                i += 1
            out.append(SECTION)
            i += 1
            continue
        out.append(value[i])
        i += 1
    return "".join(out)


def has_raw_color(value: str) -> bool:
    """A hex, or a colour function none of whose arguments is a token (check-design-tokens.ts `hasRawColor`)."""
    bare = re.sub(r"url\([^)]*\)", " ", without_vars(value), flags=re.I)
    if HEX.search(bare):
        return True
    for match in COLOR_FUNCTION.finditer(bare):
        depth, end = 1, match.end()
        while end < len(bare) and depth:
            depth += {"(": 1, ")": -1}.get(bare[end], 0)
            end += 1
        if SECTION not in bare[match.end():end]:
            return True
    return False


def literals(value: str) -> list[tuple[float, str]]:
    """The numbers outside var() in `value`, with their units ('' for a bare number)."""
    bare = without_vars(UI_PX.sub(r"\1px", value))
    return [(float(m.group(1)), (m.group(2) or "").lower()) for m in NUMBER.finditer(bare)]


def radius_class(value: str, scale: set[float]) -> tuple[str, bool]:
    """('token'|'mixed'|'raw'|'capsule'|'zero', off-scale) for one border-radius value."""
    plain = value.strip().lower()
    # Only a number with a unit is a radius; a bare one is a calc() factor (`calc(var(--h) / 2)`).
    nonzero = [(n, unit) for n, unit in literals(value) if n != 0 and unit]
    if plain in KEYWORDS or (not nonzero and "var(" not in plain):
        return "zero", False
    if "var(" in plain:
        return ("mixed" if nonzero else "token"), False
    if all((unit == "px" and abs(n) >= CAPSULE_PX) or (unit == "%" and n == 50) for n, unit in nonzero):
        return "capsule", False
    off = any(not (unit == "px" and abs(n) in scale) and not (unit == "px" and abs(n) >= CAPSULE_PX)
              for n, unit in nonzero)
    return "raw", off


LENGTH_UNITS = {"px", "em", "rem", "ch", "vh", "vw"}
NONE_KEYWORDS = frozenset({"none", "inherit", "initial", "unset", "revert"})


def literal_kind(value: str, lengths_only: bool = False) -> str:
    """'none' (a keyword), 'token' (only var(), zeros, `inset` and separators) or 'literal': a raw colour,
    `black`/`white`, or a non-zero number outside var(). With `lengths_only` (a shadow) only a number with a
    length unit counts, so a calc() factor or a color-mix() share of tokens is not a literal."""
    plain = value.strip().lower()
    if plain in NONE_KEYWORDS:
        return "none"
    if has_raw_color(value) or re.search(r"\b(?:black|white)\b", without_vars(plain)):
        return "literal"
    if any(n != 0 and (unit in LENGTH_UNITS or not lengths_only) for n, unit in literals(value)):
        return "literal"
    # A shadow of tokens, zeros and keywords alone counts as token-only.
    return "token" if "var(" in plain or lengths_only else "literal"


def css_counts(text: str, scale: set[float], counts: Counter, sets: dict[str, set]) -> None:
    for _selector, prop, value in parse_css(text):
        if prop.startswith("--"):
            sets["custom_properties"].add(prop)
            continue
        if RADIUS_PROPERTY.match(prop):
            kind, off = radius_class(value, scale)
            counts["radius.total"] += 1
            counts[f"radius.{kind}"] += 1
            if kind == "raw":
                sets["radius.raw_values"].add(value)
                counts["radius.off_scale"] += int(off)
        if prop in ("box-shadow", "-webkit-box-shadow"):
            kind = literal_kind(value, lengths_only=True)
            counts["shadow.total"] += 1
            counts[f"shadow.{kind}"] += 1
            if kind == "literal":
                sets["shadow.literals"].add(value)
        if prop in ("backdrop-filter", "-webkit-backdrop-filter"):
            kind = literal_kind(value)
            counts["backdrop.total"] += 1
            counts[f"backdrop.{kind}"] += 1
        if prop == "z-index":
            plain = value.strip().lower()
            counts["z.total"] += 1
            if re.fullmatch(r"-?\d+", plain):
                counts["z.literal"] += 1
            elif "var(" in plain:
                counts["z.var"] += 1
            else:
                counts["z.other"] += 1
        if SPACING_PROPERTY.match(prop):
            pxs = [n for n, unit in literals(value) if unit == "px"]
            if any(abs(n) % 4 for n in pxs):
                counts["spacing.off_grid"] += 1
        if not NOT_COLOR_PROPERTY.match(prop) and has_raw_color(value):
            counts["color.css"] += 1


# --- TS/TSX ----------------------------------------------------------------------------------------------------

# A 3-digit hex counts only with a letter in it, so `PR #441` is not a colour.
JS_HEX = re.compile(r"(?<![\w&])#(?:(?=[0-9]{0,2}[a-fA-F])[0-9a-fA-F]{3}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})(?![\w-])")


def js_strings_and_code(text: str) -> tuple[list[str], str]:
    """The string literals of a JS/TS source (template pieces included) and its code with comments blanked."""
    strings: list[str] = []
    code: list[str] = []
    i, n = 0, len(text)
    while i < n:
        ch = text[i]
        two = text[i:i + 2]
        if two == "//":
            end = text.find("\n", i)
            end = n if end < 0 else end
            code.append(" " * (end - i))
            i = end
        elif two == "/*":
            end = text.find("*/", i + 2)
            end = n if end < 0 else end + 2
            code.append(re.sub(r"[^\n]", " ", text[i:end]))
            i = end
        elif ch in "\"'`":
            j = i + 1
            while j < n and text[j] != ch:
                if text[j] == "\\":
                    j += 1
                elif text[j] == "\n" and ch != "`":
                    break
                j += 1
            strings.append(text[i + 1:j])
            code.append(text[i:j + 1])
            i = j + 1
        else:
            code.append(ch)
            i += 1
    return strings, "".join(code)


def js_color_literals(strings: list[str]) -> int:
    found = 0
    for text in strings:
        bare = without_vars(text)
        found += len(JS_HEX.findall(bare))
        for match in COLOR_FUNCTION.finditer(bare):
            depth, end = 1, match.end()
            while end < len(bare) and depth:
                depth += {"(": 1, ")": -1}.get(bare[end], 0)
                end += 1
            args = bare[match.end():end]
            if SECTION not in args and "${" not in args and re.search(r"\d", args):
                found += 1
    return found


PRIMITIVES = {
    "button.raw": re.compile(r"<button\b"),
    "button.component": re.compile(r"<Button\b"),
    "title.attribute": re.compile(r"(?<=\s)title=[{\"']"),
    "tooltip.component": re.compile(r"<Tooltip\b"),
    "input.raw": re.compile(r"<(?:input|textarea)\b"),
    "input.component": re.compile(r"<Input\b"),
}


# --- Swift -----------------------------------------------------------------------------------------------------

def strip_swift(text: str) -> str:
    """`text` with comments removed and string contents blanked (multi-line strings too), newlines kept."""
    out: list[str] = []
    i, n = 0, len(text)
    while i < n:
        two = text[i:i + 2]
        if two == "//":
            end = text.find("\n", i)
            i = n if end < 0 else end
        elif two == "/*":
            end = text.find("*/", i + 2)
            end = n if end < 0 else end + 2
            out.append("\n" * text.count("\n", i, end))
            i = end
        elif text.startswith('"""', i):
            end = text.find('"""', i + 3)
            end = n if end < 0 else end + 3
            out.append('""' + "\n" * text.count("\n", i, end))
            i = end
        elif text[i] == '"':
            j = i + 1
            while j < n and text[j] not in '"\n':
                j += 2 if text[j] == "\\" else 1
            out.append('""')
            i = j + 1
        else:
            out.append(text[i])
            i += 1
    return "".join(out)


SWIFT_NUMBER = r"-?\d+(?:\.\d+)?"
END_OF_EXPR = r"\s*(?=$|[,)\]}]|\n)"
# `cornerRadius: 8` (a label: no space before the colon, so a ternary's ` : 0` is not one), `cornerRadius = 8`,
# `cornerRadius: CGFloat = 8`, and any `...CornerRadius` name the same way; the number is the whole expression.
CORNER_LITERAL = re.compile(r"\b\w*[cC]ornerRadius(?::\s*CGFloat\s*=|\s*=|:)\s*(" + SWIFT_NUMBER + r")" + END_OF_EXPR, re.M)
ZPOSITION_LITERAL = re.compile(r"\bzPosition\s*=\s*(" + SWIFT_NUMBER + r")" + END_OF_EXPR, re.M)
EFFECT_VIEW = re.compile(r"\bNS(?:Visual|Glass)EffectView\b")
GLASS_TYPE = re.compile(r"\b(?:struct|enum|class|protocol|actor)\s+(\w*(?:Glass|Material)\w*)")
TOKENS_REF = re.compile(r"\bDesignTokens\.")


def swift_counts(text: str) -> dict[str, object]:
    code = strip_swift(text)
    return {
        "corner": sum(1 for m in CORNER_LITERAL.finditer(code) if float(m.group(1)) != 0),
        "zposition": len(ZPOSITION_LITERAL.findall(code)),
        "effect_views": len(EFFECT_VIEW.findall(code)),
        "glass_types": sorted(set(GLASS_TYPE.findall(code))),
        "tokens_refs": len(TOKENS_REF.findall(code)),
    }


# --- walking ---------------------------------------------------------------------------------------------------

def walk(root: str, top: str, suffixes: tuple[str, ...]):
    base = os.path.join(root, top)
    for folder, dirs, files in os.walk(base):
        dirs[:] = sorted(d for d in dirs if d not in SKIP_DIRS)
        for name in sorted(files):
            if name.endswith(suffixes) and ".generated." not in name:
                path = os.path.join(folder, name)
                yield os.path.relpath(path, base).replace(os.sep, "/"), path


def web_bucket(rel: str) -> str:
    parts = rel.split("/")
    if OTHER_DIRS & set(parts[:-1]) or OTHER_FILE.search(parts[-1]):
        return "other"
    return "main"


def scale_radii(root: str) -> set[float]:
    with open(os.path.join(root, SCALE), encoding="utf-8") as handle:
        data = json.load(handle)
    radii = {float(r["px"]) for r in data.get("radii", []) if "px" in r}
    radii |= {float(r["px"]) for r in data.get("namedRadii", []) if "px" in r}
    return radii | {0.0}


def prefix(name: str) -> str:
    return "--" + name[2:].split("-", 1)[0]


def census(root: str) -> dict:
    scale = scale_radii(root)
    web: dict[str, Counter] = {"main": Counter(), "other": Counter()}
    sets: dict[str, dict[str, set]] = {b: {"custom_properties": set(), "radius.raw_values": set(),
                                           "shadow.literals": set()} for b in web}
    for rel, path in walk(root, WEB, (".css", ".ts", ".tsx")):
        bucket = web_bucket(rel)
        with open(path, encoding="utf-8", errors="replace") as handle:
            text = handle.read()
        if rel.endswith(".css"):
            css_counts(text, scale, web[bucket], sets[bucket])
            continue
        if rel.endswith(".d.ts"):
            continue
        strings, code = js_strings_and_code(text)
        web[bucket]["color.ts"] += js_color_literals(strings)
        if rel.endswith(".tsx"):
            for key, pattern in PRIMITIVES.items():
                web[bucket][key] += len(pattern.findall(code))
        if re.search(r"\.gallery\.tsx?$", rel):
            web[bucket]["gallery.files"] += 1

    def web_section(counter: Counter, bucket_sets: dict[str, set]) -> dict:
        props = bucket_sets["custom_properties"]
        prefixes = Counter(prefix(p) for p in props)
        return {
            "radius": {k: counter[f"radius.{k}"] for k in ("total", "token", "mixed", "raw", "capsule", "zero", "off_scale")}
            | {"raw_distinct": len(bucket_sets["radius.raw_values"])},
            "custom_properties": {
                "distinct": len(props),
                "ds": sum(1 for p in props if p.startswith("--ds-")),
                "radius_or_corner": sum(1 for p in props if re.search(r"radius|corner", p)),
                "shadow_or_elevation": sum(1 for p in props if re.search(r"shadow|elevation", p)),
                "blur_or_glass": sum(1 for p in props if re.search(r"blur|glass", p)),
                "top_prefixes": [[name, count] for name, count in
                                 sorted(prefixes.items(), key=lambda item: (-item[1], item[0]))[:12]],
            },
            "box_shadow": {k: counter[f"shadow.{k}"] for k in ("total", "none", "token", "literal")}
            | {"literal_distinct": len(bucket_sets["shadow.literals"])},
            "backdrop_filter": {k: counter[f"backdrop.{k}"] for k in ("total", "none", "token", "literal")},
            "z_index": {k: counter[f"z.{k}"] for k in ("total", "var", "literal", "other")},
            "spacing_off_grid": counter["spacing.off_grid"],
            "color_literals": {"css": counter["color.css"], "ts": counter["color.ts"]},
            "primitives": {k.replace(".", "_"): counter[k] for k in PRIMITIVES} | {"gallery_files": counter["gallery.files"]},
        }

    union_sets = {key: sets["main"][key] | sets["other"][key] for key in sets["main"]}
    web_out = {"main": web_section(web["main"], sets["main"]), "other": web_section(web["other"], sets["other"]),
               "all": web_section(web["main"] + web["other"], union_sets)}

    swift: dict[str, dict] = {b: {"files": 0, "corner_radius_literals": 0, "zposition_literals": 0,
                                  "effect_view_uses": 0, "tokens_refs": 0, "glass_types": set()}
                              for b in ("design", "other")}
    for rel, path in walk(root, SWIFT, (".swift",)):
        bucket = "design" if rel.split("/", 1)[0] in DESIGN_PACKAGES else "other"
        with open(path, encoding="utf-8", errors="replace") as handle:
            found = swift_counts(handle.read())
        out = swift[bucket]
        out["files"] += 1
        out["corner_radius_literals"] += found["corner"]
        out["zposition_literals"] += found["zposition"]
        out["effect_view_uses"] += found["effect_views"]
        out["tokens_refs"] += found["tokens_refs"]
        out["glass_types"] |= set(found["glass_types"])
    for out in swift.values():
        out["glass_type_names"] = sorted(out.pop("glass_types"))
        out["glass_types"] = len(out["glass_type_names"])

    return {"web": web_out, "swift": swift, "baselines": baselines(root),
            "scale_radii_px": sorted(int(r) if r.is_integer() else r for r in scale)}


def baselines(root: str) -> dict:
    out = {}
    for rel in BASELINES:
        path = os.path.join(root, rel)
        if not os.path.exists(path):
            continue
        with open(path, encoding="utf-8") as handle:
            rows = [line for line in handle.read().splitlines() if line.strip() and not line.startswith("#")]
        entry: dict[str, object] = {"rows": len(rows)}
        if rel.endswith(".jsonl"):
            kinds: dict[str, list[int]] = {}
            for line in rows:
                row = json.loads(line)
                kind = kinds.setdefault(row["kind"], [0, 0])
                kind[0] += 1
                kind[1] += sum(row["values"].values())
            entry["allowed"] = sum(total for _, total in kinds.values())
            entry["kinds"] = {k: {"rows": v[0], "allowed": v[1]} for k, v in sorted(kinds.items())}
        elif rel.endswith(".tsv") and rows and rows[0].split("\t")[-1].isdigit():
            entry["allowed"] = sum(int(line.split("\t")[-1]) for line in rows if line.split("\t")[-1].isdigit())
        out[rel] = entry
    return out


def table(data: dict) -> str:
    web = data["web"]
    lines = [f"design-system census (scale radii px: {', '.join(map(str, data['scale_radii_px']))})", "",
             f"{'webviews/src':58} {'main':>7} {'other':>7} {'all':>7}"]

    def row(label: str, get) -> None:
        lines.append(f"{label:58} {get(web['main']):>7} {get(web['other']):>7} {get(web['all']):>7}")

    for key, label in (("total", "border-radius declarations"), ("token", "  token-only (var())"),
                       ("mixed", "  mixed (var() and a literal)"), ("raw", "  raw literal"),
                       ("raw_distinct", "    distinct raw values"), ("off_scale", "    off the scale's radii"),
                       ("capsule", "  capsule (>= 999px or 50%)"), ("zero", "  zero or keyword")):
        row(label, lambda w, k=key: w["radius"][k])
    for key, label in (("distinct", "custom properties defined (distinct)"), ("ds", "  --ds-*"),
                       ("radius_or_corner", "  name has radius|corner"),
                       ("shadow_or_elevation", "  name has shadow|elevation"),
                       ("blur_or_glass", "  name has blur|glass")):
        row(label, lambda w, k=key: w["custom_properties"][k])
    for key, label in (("total", "box-shadow declarations"), ("none", "  none/keyword"), ("token", "  token-only"),
                       ("literal", "  literal"), ("literal_distinct", "    distinct literals")):
        row(label, lambda w, k=key: w["box_shadow"][k])
    for key, label in (("token", "backdrop-filter token-only"), ("literal", "backdrop-filter literal")):
        row(label, lambda w, k=key: w["backdrop_filter"][k])
    for key, label in (("var", "z-index var()"), ("literal", "z-index literal"), ("other", "z-index other")):
        row(label, lambda w, k=key: w["z_index"][k])
    row("padding/margin/gap with a px off the 4 px grid", lambda w: w["spacing_off_grid"])
    row("raw colour literals, CSS", lambda w: w["color_literals"]["css"])
    row("raw colour literals in TS/TSX strings", lambda w: w["color_literals"]["ts"])
    for key, label in (("button_raw", "<button"), ("button_component", "<Button"), ("title_attribute", "title="),
                       ("tooltip_component", "<Tooltip"), ("input_raw", "<input / <textarea"),
                       ("input_component", "<Input"), ("gallery_files", "*.gallery.ts(x) files")):
        row(label, lambda w, k=key: w["primitives"][k])
    lines += ["", "custom property prefixes (all, top 12): " +
              ", ".join(f"{name} {count}" for name, count in web["all"]["custom_properties"]["top_prefixes"])]

    swift = data["swift"]
    lines += ["", f"{'Packages/macOS/CmuxNext/Sources':58} {'design':>7} {'other':>7}"]
    for key, label in (("files", "Swift files"), ("corner_radius_literals", "numeric non-zero cornerRadius literals"),
                       ("zposition_literals", "numeric zPosition literals"),
                       ("effect_view_uses", "NSVisualEffectView / NSGlassEffectView uses"),
                       ("glass_types", "Glass/Material types declared"), ("tokens_refs", "DesignTokens. references")):
        lines.append(f"{label:58} {swift['design'][key]:>7} {swift['other'][key]:>7}")
    lines.append("Glass/Material types in the design packages: " + ", ".join(swift["design"]["glass_type_names"]))

    lines += ["", "ratchet baselines"]
    for rel, entry in data["baselines"].items():
        allowed = f", {entry['allowed']} allowed" if "allowed" in entry else ""
        lines.append(f"  {rel}: {entry['rows']} rows{allowed}")
        for kind, numbers in entry.get("kinds", {}).items():
            lines.append(f"    {kind}: {numbers['rows']} rows, {numbers['allowed']} allowed")
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", default=REPO)
    parser.add_argument("--json", action="store_true", help="print the numbers as JSON")
    args = parser.parse_args(argv)
    data = census(args.root)
    print(json.dumps(data, indent=2, sort_keys=True) if args.json else table(data))
    return 0


if __name__ == "__main__":
    sys.exit(main())
