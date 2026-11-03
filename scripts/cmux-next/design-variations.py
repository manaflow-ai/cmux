#!/usr/bin/env python3
"""Writes a gallery page for a folder of design variations (plans/cmux-next/design-mode-DESIGN.md).

  scripts/cmux-next/design-variations.py DIR [--open] [--agent NAME]

Every `*.html` file in DIR (name order, the gallery itself excluded) becomes one tile: a caption
"<n>. <title>" (the file's <title>, else its name) and a live frame of the file. Each tile is
tagged `data-testid="cmux-variation-<n>"` and its caption `cmux-variation-<n>-title`, so turning
on design mode (Ctrl-Opt-Cmd-E) in the gallery and clicking a tile sends the pick to the chat as
"Picked design variation <n>: <title>". Frames ignore the pointer so a click lands on the tile.
Writes DIR/index.html and prints its path. `--open` also shows it in the column right of the
Home chat (`cmux browser right navigate <file URL> --agent NAME`, default agent "Chief"; the CLI is
$CMUX_BIN, else `cmux`). A pick in the Home chat's window is sent to that chat at once.
"""
import html
import pathlib
import os
import re
import subprocess
import sys

GALLERY = "index.html"
STYLE = """
:root { color-scheme: light dark; font: 13px -apple-system, system-ui, sans-serif; }
body { margin: 0; padding: 16px; background: Canvas; color: CanvasText; }
main { display: grid; gap: 16px; grid-template-columns: repeat(auto-fill, minmax(360px, 1fr)); }
figure { margin: 0; border: 1px solid color-mix(in srgb, CanvasText 18%, transparent); border-radius: 12px;
         overflow: hidden; background: color-mix(in srgb, CanvasText 4%, Canvas); cursor: pointer; }
figcaption { padding: 8px 12px; font-weight: 600; }
iframe { display: block; width: 100%; height: 420px; border: 0; pointer-events: none; background: white; }
"""


def title_of(path: pathlib.Path) -> str:
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        text = ""
    match = re.search(r"<title[^>]*>(.*?)</title>", text, re.IGNORECASE | re.DOTALL)
    title = html.unescape(re.sub(r"\s+", " ", match.group(1)).strip()) if match else ""
    return title or path.stem


def gallery(folder: pathlib.Path) -> str:
    files = sorted(p for p in folder.glob("*.html") if p.name != GALLERY and p.is_file())
    tiles = []
    for number, path in enumerate(files, start=1):
        caption = html.escape(f"{number}. {title_of(path)}", quote=False)
        tiles.append(
            f'<figure data-testid="cmux-variation-{number}">'
            f'<figcaption data-testid="cmux-variation-{number}-title">{caption}</figcaption>'
            f'<iframe src="{html.escape(path.name)}" loading="lazy" sandbox="allow-scripts"></iframe>'
            "</figure>"
        )
    return (
        '<!doctype html><html><head><meta charset="utf-8">'
        f"<title>{html.escape(folder.name)}</title><style>{STYLE}</style></head>"
        f"<body><main>{''.join(tiles)}</main></body></html>\n"
    )


def main() -> int:
    args = sys.argv[1:]
    should_open = "--open" in args
    args = [a for a in args if a != "--open"]
    agent = "Chief"
    if "--agent" in args:
        at = args.index("--agent")
        if at + 1 >= len(args):
            print("design-variations: --agent needs a name", file=sys.stderr)
            return 2
        agent = args[at + 1]
        del args[at : at + 2]
    if len(args) != 1:
        print(__doc__.strip().splitlines()[2].strip(), file=sys.stderr)
        return 2
    folder = pathlib.Path(args[0]).expanduser().absolute()
    if not folder.is_dir():
        print(f"design-variations: {folder} is not a folder", file=sys.stderr)
        return 2
    page = folder / GALLERY
    page.write_text(gallery(folder), encoding="utf-8")
    print(page)
    if should_open:
        cli = os.environ.get("CMUX_BIN") or "cmux"
        return subprocess.run([cli, "browser", "right", "navigate", page.as_uri(), "--agent", agent]).returncode
    return 0


if __name__ == "__main__":
    sys.exit(main())
