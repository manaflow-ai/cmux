#!/usr/bin/env python3
"""Re-imports the agent brand SVGs in design/agent-icons/svg/ from their owners' files.

Each brand's `import` recipe in design/agent-icons/manifest.json names where the official
artwork lives and which paths make the mark:

    "import": {
      "fetch": {"url": ...} | {"url": ..., "zip": member} | {"npm": "pkg@ver", "member": path, "extract": regex},
      "shapes": true,           # number <rect>/<circle> too (default: <path> elements only)
      "paths": [{"from": [i, ...], "fillRule": "evenodd", "opacity": "0", "strokeWidth": "3.5"}],
      "viewBox": "x y w h",     # the crop to the glyph (default: the file's own)
      "transform": "...",       # applied to every path (svgo folds it in)
      "precision": 2            # decimals svgo keeps
    }

Each `paths` entry concatenates the listed source paths into one path; without `paths` every
source path is kept. svgo (pinned, run with bunx) minimizes the result. Nothing is redrawn.

Needs network, bun and python3. Usage:
    scripts/agent-icons/import.py              # rewrite every svg/<brand>.svg
    scripts/agent-icons/import.py --brand kiro # one brand
    scripts/agent-icons/import.py --check      # fail when a re-import differs from the committed file
Then run scripts/agent-icons/generate.py.
"""
import argparse
import gzip
import io
import os
import json
import re
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.error
import urllib.request
import zipfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SOURCE = REPO / "design" / "agent-icons"
SVGO = "svgo@4.1.0"
UA = {"User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/130 Safari/537.36"}
SVGO_CONFIG = """
const p = Number(process.env.SVGO_PRECISION ?? 2);
export default {
  multipass: true,
  floatPrecision: p,
  plugins: [
    { name: 'preset-default', params: { overrides: { convertPathData: { floatPrecision: p }, mergePaths: false,
      removeHiddenElems: false, convertColors: { currentColor: false } } } },
    'removeDimensions',
    { name: 'removeAttrs', params: { attrs: ['class', 'data-.*', 'id', 'style', 'clip-rule'] } },
  ],
};
"""


def download(url, attempts=5):
    for attempt in range(attempts):
        try:
            with urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=120) as response:
                data = response.read()
                # Some hosts send gzip whatever the request accepts.
                return gzip.decompress(data) if data[:2] == b"\x1f\x8b" else data
        except urllib.error.HTTPError as error:
            if error.code != 429 or attempt == attempts - 1:
                raise
            # A one-shot import, not runtime code: wait out the host's rate limit and retry.
            time.sleep(int(error.headers.get("Retry-After") or 0) or 10 * (attempt + 1))


def fetch(spec, cache):
    if "npm" in spec:
        name = spec["npm"]
        if name not in cache:
            meta = json.loads(subprocess.check_output(["npm", "view", name, "dist.tarball", "--json"], text=True))
            cache[name] = download(meta if isinstance(meta, str) else meta[-1])
        with tarfile.open(fileobj=io.BytesIO(cache[name])) as tar:
            text = tar.extractfile(spec["member"]).read().decode()
        if "extract" in spec:
            text = json.loads('"' + re.search(spec["extract"], text, re.S).group(1) + '"')
        return text
    if spec["url"] not in cache:
        cache[spec["url"]] = download(spec["url"])
    data = cache[spec["url"]]
    if "zip" in spec:
        data = zipfile.ZipFile(io.BytesIO(data)).read(spec["zip"])
    return data.decode()


def attr(tag, name):
    m = re.search(r'\s%s=(["\'])(.*?)\1' % re.escape(name), tag, re.S)
    return m.group(2) if m else None


def num(tag, name, default=0.0):
    value = attr(tag, name)
    return float(value) if value is not None else default


def shape_path(tag):
    kind = re.match(r"<(\w+)", tag).group(1)
    if kind == "path":
        return attr(tag, "d")
    if kind == "rect":
        x, y, w, h = num(tag, "x"), num(tag, "y"), num(tag, "width"), num(tag, "height")
        r = num(tag, "rx", num(tag, "ry"))
        if not r:
            return f"M{x:g} {y:g}h{w:g}v{h:g}h{-w:g}z"
        return (f"M{x + r:g} {y:g}h{w - 2 * r:g}q{r:g} 0 {r:g} {r:g}v{h - 2 * r:g}q0 {r:g} -{r:g} {r:g}"
                f"h-{w - 2 * r:g}q-{r:g} 0 -{r:g} -{r:g}v-{h - 2 * r:g}q0 -{r:g} {r:g} -{r:g}z")
    if kind == "circle":
        cx, cy, r = num(tag, "cx"), num(tag, "cy"), num(tag, "r")
        return f"M{cx - r:g} {cy:g}a{r:g} {r:g} 0 1 0 {2 * r:g} 0a{r:g} {r:g} 0 1 0 -{2 * r:g} 0z"
    raise ValueError(kind)


def build(brand, recipe, cache):
    text = fetch(recipe["fetch"], cache)
    pattern = r"<(?:path|rect|circle)\b[^>]*?/?>" if recipe.get("shapes") else r"<path\b[^>]*?/?>"
    tags = re.findall(pattern, text, re.S)
    view_box = recipe.get("viewBox") or attr(re.search(r"<svg\b[^>]*>", text).group(0), "viewBox")
    groups = recipe.get("paths") or [{"from": [i], "fillRule": attr(t, "fill-rule")} for i, t in enumerate(tags)]
    body = []
    for group in groups:
        d = "".join(shape_path(tags[i]) for i in group["from"])
        attrs = ""
        if group.get("fillRule") == "evenodd":
            attrs += ' fill-rule="evenodd"'
        if group.get("opacity") is not None:
            attrs += f' opacity="{group["opacity"]}"'
        if group.get("strokeWidth"):
            attrs += f' fill="none" stroke="currentColor" stroke-width="{group["strokeWidth"]}"'
        body.append(f'<path{attrs} d="{d}"/>')
    inner = "".join(body)
    if recipe.get("transform"):
        inner = f'<g transform="{recipe["transform"]}">{inner}</g>'
    return f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{view_box}" fill="currentColor">{inner}</svg>'


def minimize(raw, precision, workdir):
    source = workdir / "in.svg"
    target = workdir / "out.svg"
    source.write_text(raw)
    subprocess.run(["bunx", SVGO, "--config", str(workdir / "svgo.config.mjs"), str(source), "-o", str(target)],
                   check=True, stdout=subprocess.DEVNULL, env={**os.environ, "SVGO_PRECISION": str(precision)})
    return target.read_text()


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--brand", action="append", help="only these brand ids")
    parser.add_argument("--check", action="store_true", help="compare with the committed files; write nothing")
    args = parser.parse_args()
    manifest = json.loads((SOURCE / "manifest.json").read_text())
    cache, differs = {}, []
    with tempfile.TemporaryDirectory() as tmp:
        workdir = Path(tmp)
        (workdir / "svgo.config.mjs").write_text(SVGO_CONFIG)
        for brand in manifest["brands"]:
            if args.brand and brand["id"] not in args.brand:
                continue
            recipe = brand["import"]
            svg = minimize(build(brand["id"], recipe, cache), recipe.get("precision", 2), workdir)
            path = SOURCE / "svg" / f"{brand['id']}.svg"
            if args.check:
                if not path.exists() or path.read_text() != svg:
                    differs.append(brand["id"])
                print(f"{brand['id']:12} {len(svg.encode()):6d} B {'differs' if brand['id'] in differs else 'same'}")
            else:
                path.write_text(svg)
                print(f"{brand['id']:12} {len(svg.encode()):6d} B")
    if differs:
        print("re-import differs for: " + ", ".join(differs), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
