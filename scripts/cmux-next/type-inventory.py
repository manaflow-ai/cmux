#!/usr/bin/env python3
"""Type inventory of cmux NEXT: the font sizes and weights each surface uses, native and web.

Prints a Markdown table, one row per surface: its distinct font sizes (px on the web, pt in the app)
and weights, each with how many places use it. Web tokens (`var(--text-*)`, Tailwind `text-*`,
`var(--weight-*)`) count at the size the tree's desktop.css gives them; app `Typography` fonts count
at their comfortable size (compact in brackets when it differs). Run it on a checkout of the base
and of the change for a before and after (`--root`).

  python3 scripts/cmux-next/type-inventory.py [--root DIR]
"""
import argparse
import collections
import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))

WEB_SURFACES = [
    ("agent-session/acpmux/composer", "Composer and footer"),
    ("agent-session/acpmux/Composer", "Composer and footer"),
    ("agent-session/acpmux/ModelPicker", "Composer and footer"),
    ("agent-session/acpmux/modelPicker", "Composer and footer"),
    ("agent-session/acpmux/newtab", "New Tab"),
    ("agent-session", "Agent chat"),
    ("pages/home-channels", "Chats list (Home)"),
    ("agent-activity", "Agent Activity"),
    ("pages/app-store", "App Store"),
    ("pages/settings", "Settings pages"),
    ("ui/", "Shared web UI (menus, fields)"),
    ("", "Other web"),
]
NATIVE_SURFACES = [
    ("CmuxNextSidebar", "Sidebar (rows, cards)"),
    ("CmuxNextTabs", "Tab strip"),
    ("CmuxNextApp/Windows", "Titlebar and window chrome"),
    ("CmuxNextApp/Titlebar", "Titlebar and window chrome"),
    ("CmuxNextSettings", "Settings"),
    ("CmuxNextPalette", "Palette and menus"),
    ("CmuxNextBrowser", "Browser chrome"),
    ("CmuxNextDesign", "Design (shared controls)"),
    ("CmuxNextFeed", "Feed"),
    ("CmuxNextServer", "Server pages"),
    ("CmuxNextTasks", "Tasks"),
    ("CmuxNextHome", "Home (native transcript)"),
    ("CmuxNextOnboarding", "Onboarding"),
    ("CmuxNextTerminal", "Terminal overlays"),
    ("", "Other native"),
]
WEIGHT_WORDS = {"normal": 400, "medium": 500, "semibold": 600, "bold": 700, "light": 300}
SWIFT_WEIGHTS = {"ultraLight": 100, "thin": 200, "light": 300, "regular": 400, "medium": 500, "semibold": 600,
                 "bold": 700, "heavy": 800, "black": 900}


def surface(path, table):
    return next(name for prefix, name in table if path.startswith(prefix))


def web_tokens(root):
    """The px size of each --text-* step and the weight of each --weight-*, from desktop.css."""
    text = open(os.path.join(root, "webviews/src/pages/shared/desktop.css")).read()
    raw = dict(re.findall(r"--((?:text|weight)-[a-z]+):\s*([^;]+);", text))
    def resolve(name, depth=0):
        value = raw.get(name, "")
        alias = re.match(r"var\(--((?:text|weight)-[a-z]+)", value)
        if alias and depth < 4:
            return resolve(alias.group(1), depth + 1)
        number = re.match(r"(\d+(?:\.\d+)?)", value)
        return float(number.group(1)) if number else None
    return {name: resolve(name) for name in raw}


def web(root):
    tokens = web_tokens(root)
    sizes, weights = collections.defaultdict(collections.Counter), collections.defaultdict(collections.Counter)
    base = os.path.join(root, "webviews/src")
    for folder, dirs, files in os.walk(base):
        dirs[:] = [d for d in dirs if d not in ("node_modules", "generated", "gallery")]
        for name in files:
            if not name.endswith((".css", ".tsx", ".ts")) or ".gallery." in name or ".test." in name:
                continue
            rel = os.path.relpath(os.path.join(folder, name), base).replace(os.sep, "/")
            if rel == "pages/shared/desktop.css":
                continue
            where = surface(rel, WEB_SURFACES)
            text = re.sub(r"/\*.*?\*/", "", open(os.path.join(folder, name), errors="replace").read(), flags=re.S)
            for value in re.findall(r"font-size\s*:\s*([^;}\n]+)", text):
                token = re.search(r"var\(--(text-[a-z]+)", value)
                literal = re.match(r"\s*(\d+(?:\.\d+)?)px", value)
                if token and tokens.get(token.group(1)):
                    sizes[where][tokens[token.group(1)]] += 1
                elif literal:
                    sizes[where][float(literal.group(1))] += 1
            for step in re.findall(r"(?<![\w-])text-(caption|detail|body|control|title|heading)\b", text):
                if tokens.get("text-" + step):
                    sizes[where][tokens["text-" + step]] += 1
            for value in re.findall(r"text-\[(\d+(?:\.\d+)?)px\]", text):
                sizes[where][float(value)] += 1
            for value in re.findall(r"font-weight\s*:\s*([^;}\n]+)", text):
                token = re.search(r"var\(--(weight-[a-z]+)", value)
                number = re.match(r"\s*(\d{3})\b", value)
                if token and tokens.get(token.group(1)):
                    weights[where][int(tokens[token.group(1)])] += 1
                elif number:
                    weights[where][int(number.group(1))] += 1
                elif value.strip() in WEIGHT_WORDS:
                    weights[where][WEIGHT_WORDS[value.strip()]] += 1
            for word in re.findall(r"(?<![\w-])font-(normal|medium|semibold|bold|light)\b", text):
                weights[where][WEIGHT_WORDS[word]] += 1
    return sizes, weights


def typography(root):
    """Each Typography font's (comfortable, compact) size and weight, from Metrics.swift."""
    text = open(os.path.join(root, "Packages/macOS/CmuxNext/Sources/CmuxNextDesign/Metrics.swift")).read()
    styles = {}
    for name, body in re.findall(r"public static var (\w+): NSFont \{([^\n]+)\}", text):
        pair = re.search(r"size\((\d+(?:\.\d+)?),\s*(\d+(?:\.\d+)?)\)", body)
        step = re.search(r"TypeScale\.(\w+)", body)
        weight = re.search(r"weight: (?:TypeScale\.)?\.?(\w+)", body)
        if pair:
            size = (float(pair.group(2)), float(pair.group(1)))
        elif step:
            size = (step.group(1), step.group(1))
        else:
            continue
        styles[name] = (size, weight.group(1) if weight else "regular")
    return styles


def native(root):
    styles = typography(root)
    scale = {}
    generated = os.path.join(root, "Packages/macOS/CmuxNext/Sources/CmuxNextDesign/TypeScale.generated.swift")
    if os.path.exists(generated):
        scale = {k: float(v) for k, v in re.findall(r"public static let (\w+): CGFloat = (\d+(?:\.\d+)?)", open(generated).read())}
        weights_of = dict(re.findall(r"public static let (\w+): NSFont\.Weight = \.(\w+)", open(generated).read()))
    else:
        weights_of = {}
    sizes, weights = collections.defaultdict(collections.Counter), collections.defaultdict(collections.Counter)
    base = os.path.join(root, "Packages/macOS/CmuxNext/Sources")
    for folder, _, files in os.walk(base):
        for name in files:
            if not name.endswith(".swift") or name == "TypeScale.generated.swift":
                continue
            rel = os.path.relpath(os.path.join(folder, name), base).replace(os.sep, "/")
            where = surface(rel, NATIVE_SURFACES)
            text = re.sub(r"//[^\n]*", "", open(os.path.join(folder, name), errors="replace").read())
            font_size = (r"(?:(?:systemFont|monospacedSystemFont|monospacedDigitSystemFont|boldSystemFont)\(ofSize:"
                         r"|NSFont\(name:[^)\n]*size:|\.system\(size:)\s*(\d+(?:\.\d+)?)\b")
            for value in re.findall(font_size, text):
                sizes[where][float(value)] += 1
            for step in re.findall(r"TypeScale\.(caption|detail|body|title|heading)\b", text):
                if step in scale:
                    sizes[where][scale[step]] += 1
            for name_ in re.findall(r"Typography\.(\w+)", text):
                if name_ in styles:
                    (comfortable, compact), weight = styles[name_]
                    if isinstance(comfortable, str):
                        comfortable = compact = scale.get(comfortable)
                    if comfortable is None:
                        continue
                    sizes[where][comfortable if comfortable == compact else f"{comfortable:g}[{compact:g}]"] += 1
                    w = weights_of.get(weight, weight)
                    weights[where][SWIFT_WEIGHTS.get(w, 400)] += 1
            for word in re.findall(r"weight:\s*(?:NSFont\.Weight|Font\.Weight)?\.(\w+)", text):
                if word in SWIFT_WEIGHTS:
                    weights[where][SWIFT_WEIGHTS[word]] += 1
            for word in re.findall(r"weight:\s*TypeScale\.(\w+)", text):
                if word in weights_of:
                    weights[where][SWIFT_WEIGHTS[weights_of[word]]] += 1
    return sizes, weights


def fmt(counter):
    def key(item):
        value = item[0]
        return float(str(value).split("[")[0])
    return ", ".join(f"{value:g}" if isinstance(value, float) else str(value) for value, _ in sorted(counter.items(), key=key)) or "none"


def table(title, sizes, weights, order):
    rows = [f"| {title} | sizes | weights |", "| --- | --- | --- |"]
    all_sizes, all_weights = collections.Counter(), collections.Counter()
    for _, name in order:
        if name in (r.split(" | ")[0][2:] for r in rows[2:]):
            continue
        if not sizes.get(name) and not weights.get(name):
            continue
        rows.append(f"| {name} | {fmt(sizes[name])} | {fmt(weights[name])} |")
        all_sizes.update(sizes[name])
        all_weights.update(weights[name])
    rows.append(f"| **all** ({len(all_sizes)} sizes, {len(all_weights)} weights) | {fmt(all_sizes)} | {fmt(all_weights)} |")
    return "\n".join(rows)


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", default=REPO)
    args = parser.parse_args()
    print(table("Web", *web(args.root), WEB_SURFACES))
    print()
    print(table("Native", *native(args.root), NATIVE_SURFACES))


if __name__ == "__main__":
    main()
