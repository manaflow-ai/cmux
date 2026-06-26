#!/usr/bin/env python3
"""Generate a self-contained KaTeX font stylesheet for the markdown viewer.

The markdown viewer loads `katex.min.js` lazily and injects the KaTeX
stylesheet as an inline `<style>` element (see `MarkdownWebRenderer`'s
`katex` lib case). KaTeX's stock `katex.min.css` references its font files
with *relative* `url(fonts/...)` paths, but the viewer renders user markdown
with `loadHTMLString(_:baseURL:)` whose base URL is the user's markdown file —
so those relative paths never resolve to the app bundle.

To keep the feature self-contained (no extra `WKURLSchemeHandler`), this
script rewrites `katex.min.css` so every font reference becomes an inline
`data:font/woff2;base64,...` URI. The viewer is WebKit-only on macOS 14+,
where WOFF2 is universally supported, so the WOFF/TTF fallbacks are dropped
to keep the asset small (~370 KB raw / ~280 KB deflated).

Usage:
    python3 scripts/embed-katex-fonts.py <katex-dist-dir> [output-css]

`<katex-dist-dir>` is the `dist/` directory of an unpacked `katex` npm
package (it must contain `katex.min.css` and `fonts/`). The output defaults
to `Resources/markdown-viewer/katex-fonts.min.css`.

Re-run this whenever the bundled KaTeX version is bumped. Pin the version by
fetching a specific tarball, e.g.:

    curl -sL https://registry.npmjs.org/katex/-/katex-0.16.47.tgz | tar xz
    python3 scripts/embed-katex-fonts.py package/dist
    cp package/dist/katex.min.js Resources/markdown-viewer/katex.min.js
"""

from __future__ import annotations

import base64
import pathlib
import re
import sys

DEFAULT_OUTPUT = "Resources/markdown-viewer/katex-fonts.min.css"


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print(__doc__)
        return 2

    dist = pathlib.Path(argv[1])
    css_path = dist / "katex.min.css"
    fonts_dir = dist / "fonts"
    if not css_path.is_file():
        print(f"error: {css_path} not found", file=sys.stderr)
        return 1
    if not fonts_dir.is_dir():
        print(f"error: {fonts_dir} not found", file=sys.stderr)
        return 1

    output = pathlib.Path(argv[2]) if len(argv) > 2 else pathlib.Path(DEFAULT_OUTPUT)

    css = css_path.read_text(encoding="utf-8")

    # Drop the WOFF and TTF fallback sources (WebKit on macOS 14+ supports
    # WOFF2). Each `src:` lists woff2, then woff, then ttf — remove the two
    # trailing entries so only the woff2 reference remains.
    css = re.sub(r',url\(fonts/[^)]+\.woff\) format\("woff"\)', "", css)
    css = re.sub(r',url\(fonts/[^)]+\.ttf\) format\("truetype"\)', "", css)

    embedded = 0

    def to_data_uri(match: re.Match[str]) -> str:
        nonlocal embedded
        name = match.group(1)
        font_path = fonts_dir / name
        data = base64.b64encode(font_path.read_bytes()).decode("ascii")
        embedded += 1
        return f"url(data:font/woff2;base64,{data}) format(\"woff2\")"

    css = re.sub(r'url\(fonts/([^)]+\.woff2)\) format\("woff2"\)', to_data_uri, css)

    leftover = re.findall(r"url\(fonts/[^)]+\)", css)
    if leftover:
        print(
            f"error: {len(leftover)} unresolved font reference(s) remain: "
            f"{leftover[:3]}",
            file=sys.stderr,
        )
        return 1

    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(css, encoding="utf-8")
    print(
        f"embedded {embedded} woff2 font(s) -> {output} "
        f"({len(css.encode('utf-8'))} bytes)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
