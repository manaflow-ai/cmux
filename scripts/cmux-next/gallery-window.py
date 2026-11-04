#!/usr/bin/env python3
"""Open gallery stages in light native windows that look like your own cmux.

  scripts/cmux-next/gallery-window.py --entry agent-pane.composer
  scripts/cmux-next/gallery-window.py --entry pages.diff --variant unified --sizes narrow,1000x700
  scripts/cmux-next/gallery-window.py --entry agent-pane.composer --print-spec

Each stage is a real draggable, resizable macOS window (Packages/macOS/CmuxGalleryWindow: AppKit and
WebKit only, no app build), drawn the way your app draws its window: your theme, accent, density
and scale from ~/.config/cmux/cmux-next.json (and Ghostty's config where cmux follows it), your
background picture or desktop glass behind a clear page, and the theme tint over it. One window
per size, side by side. A stage with play steps replays them on a loop (--loop 0 shows it once).

The stages come from a gallery: the local HMR server (scripts/cmux-next/preview.sh gallery,
started or reused when --gallery is not given) or any gallery URL (a branch's live gallery).
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import subprocess
import sys
import tempfile
import urllib.parse
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
HOST_PACKAGE = REPO / "Packages/macOS/CmuxGalleryWindow"
# The full pictures: the ones the app bundles, then the rest it downloads on first pick (art/full).
ART_DIRS = [REPO / "Packages/macOS/CmuxNext/Sources/CmuxNextDesign/Resources/BackdropArt", REPO / "art/full"]
ART_SOURCE = REPO / "Packages/macOS/CmuxNext/Sources/CmuxNextDesign/BackdropArt.swift"
DAILY_SOURCE = REPO / "Packages/macOS/CmuxNext/Sources/CmuxNextDesign/BackdropArt+DailyRotation.swift"

# The gallery's pane widths (webviews/src/gallery/env.ts WIDTHS), each with a window height.
NAMED_SIZES = {"narrow": (420, 720), "normal": (760, 760), "wide": (1200, 800)}
DEFAULT_SIZES = "narrow,normal,wide"


def strip_jsonc(text: str) -> str:
    """JSONC to JSON: drop // and /* */ comments outside strings, then trailing commas."""
    out: list[str] = []
    i, n = 0, len(text)
    in_string = False
    while i < n:
        c = text[i]
        if in_string:
            out.append(c)
            if c == "\\" and i + 1 < n:
                out.append(text[i + 1])
                i += 2
                continue
            if c == '"':
                in_string = False
            i += 1
        elif c == '"':
            in_string = True
            out.append(c)
            i += 1
        elif text.startswith("//", i):
            end = text.find("\n", i)
            i = n if end < 0 else end
        elif text.startswith("/*", i):
            end = text.find("*/", i + 2)
            i = n if end < 0 else end + 2
        else:
            out.append(c)
            i += 1
    return re.sub(r",(\s*[}\]])", r"\1", "".join(out))


def read_settings(path: Path) -> dict:
    try:
        text = path.read_text()
    except FileNotFoundError:
        return {}
    value = json.loads(strip_jsonc(text) or "{}")
    return value if isinstance(value, dict) else {}


def setting(settings: dict, key: str):
    """A key as cmux-next.json may hold it: nested (`appearance: {theme}`) or dotted."""
    if key in settings:
        return settings[key]
    node = settings
    for part in key.split("."):
        if not isinstance(node, dict) or part not in node:
            return None
        node = node[part]
    return node


def read_ghostty(paths: list[Path]) -> dict[str, str]:
    """`key = value` lines of Ghostty's config; a later file or line wins."""
    values: dict[str, str] = {}
    for path in paths:
        try:
            lines = path.read_text().splitlines()
        except (FileNotFoundError, IsADirectoryError):
            continue
        for line in lines:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = (part.strip() for part in line.split("=", 1))
            values[key] = value.strip('"')
    return values


def ghostty_paths(home: Path) -> list[Path]:
    xdg = Path(os.environ.get("XDG_CONFIG_HOME") or home / ".config")
    return [
        xdg / "ghostty/config",
        xdg / "ghostty/config.ghostty",
        home / "Library/Application Support/com.mitchellh.ghostty/config",
        home / "Library/Application Support/com.mitchellh.ghostty/config.ghostty",
    ]


def pick_theme(value: str | None, dark: bool) -> str | None:
    """`light:A,dark:B` (Ghostty's pair) on the side the system shows, or one theme name."""
    if not value:
        return None
    if ":" not in value:
        return value.strip()
    sides = {}
    for part in value.split(","):
        side, _, name = part.partition(":")
        sides[side.strip()] = name.strip()
    return sides.get("dark" if dark else "light") or next(iter(sides.values()), None)


def system_is_dark() -> bool:
    try:
        out = subprocess.run(
            ["defaults", "read", "-g", "AppleInterfaceStyle"], capture_output=True, text=True, timeout=5
        )
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return True
    return out.stdout.strip().lower() == "dark"


def art_file(work: str) -> Path | None:
    return next((d / f"{work}.avif" for d in ART_DIRS if (d / f"{work}.avif").is_file()), None)


def daily_art(today: dt.date) -> str | None:
    """Shuffle Daily's work for `today`, read from the app's own list (BackdropArt+Daily.swift)."""
    try:
        cases = dict(re.findall(r"case (\w+) = \"([a-z0-9-]+)\"", ART_SOURCE.read_text()))
        body = re.search(r"dailyRotation: \[BackdropArt\] = \[(.*?)\]", DAILY_SOURCE.read_text(), re.S)
    except FileNotFoundError:
        return None
    if not body:
        return None
    body = body[1]
    works = [cases[name] for name in re.findall(r"\.(\w+)", body) if name in cases]
    if not works:
        return None
    stride = next((p for p in (97, 89, 83, 79, 73, 71, 67, 61, 59, 53) if _gcd(p, len(works)) == 1), 1)
    # ordinality(of: .day, in: .era) of the Gregorian date: date.toordinal() counts the same way.
    return works[(today.toordinal() % len(works)) * stride % len(works)]


def _gcd(a: int, b: int) -> int:
    while b:
        a, b = b, a % b
    return a


def resolve_appearance(settings: dict, ghostty: dict[str, str], dark: bool, today: dt.date) -> dict:
    """The gallery query and the host's backdrop that match the person's own window."""
    app_theme = setting(settings, "appearance.appTheme")
    theme_value = app_theme if isinstance(app_theme, str) and app_theme != "followTerminal" else None
    theme_value = theme_value or setting(settings, "appearance.theme") or ghostty.get("theme")
    query: dict[str, str] = {}
    theme = pick_theme(theme_value if isinstance(theme_value, str) else None, dark)
    if theme:
        query["theme"] = theme
    # A light:A,dark:B pair follows the system; one theme shows its own side (the frame's `auto`).
    if isinstance(theme_value, str) and ":" in theme_value:
        query["colorScheme"] = "dark" if dark else "light"
    accent = setting(settings, "appearance.accent")
    if isinstance(accent, str) and accent != "neutral":
        query["accent"] = accent
    density = setting(settings, "appearance.density")
    # The gallery has two densities; the app's five map to the nearer one.
    query["density"] = "comfortable" if density in ("comfortable", "spacious") else "compact"
    for key, name in (("app.uiScale", "scale"), ("appearance.interfaceScale", "interfaceScale")):
        value = setting(settings, key)
        if isinstance(value, (int, float)) and value != 1:
            query[name] = str(value)

    opacity = setting(settings, "appearance.backgroundOpacity")
    if not isinstance(opacity, (int, float)):
        try:
            opacity = float(ghostty.get("background-opacity", "1"))
        except ValueError:
            opacity = 1.0
    opacity = min(max(float(opacity), 0.0), 1.0)
    blur = setting(settings, "appearance.backgroundBlur") or ghostty.get("background-blur") or "none"
    glassy = str(blur) not in ("none", "false", "0")

    background = setting(settings, "appearance.background")
    if not isinstance(background, str) or background == "none":
        # The legacy key BackdropSelection(id:) still accepts.
        background = setting(settings, "appearance.backdropArt")
    picture = background if isinstance(background, str) else "none"
    if picture == "daily":
        picture = daily_art(today) or "none"
    backdrop: dict = {"kind": "opaque"}
    if picture == "desktop":
        backdrop = {"kind": "desktop"}
    elif picture.startswith(("file:/", "system:/")):
        backdrop = {"kind": "art", "image": picture.split(":", 1)[1]}
    elif picture != "none" and art_file(picture):
        backdrop = {"kind": "art", "image": str(art_file(picture))}
    elif opacity < 1 or glassy:
        backdrop = {"kind": "glass"}
    if backdrop["kind"] != "opaque":
        query["backdrop"] = "host"
        # Over a picture at full Opacity the theme's own wallpaper tint (WindowBackdrop); else Opacity.
        if backdrop["kind"] == "glass" or opacity < 1:
            query["tint"] = f"{opacity:g}"
    return {"query": query, "backdrop": backdrop, "appearance": "dark" if dark else "light"}


def parse_sizes(value: str) -> list[tuple[str, int, int]]:
    sizes = []
    for part in filter(None, (p.strip() for p in value.split(","))):
        if part in NAMED_SIZES:
            sizes.append((part, *NAMED_SIZES[part]))
            continue
        match = re.fullmatch(r"(\d{3,4})x(\d{3,4})", part)
        if not match:
            raise SystemExit(f"gallery-window: size {part!r} is not narrow, normal, wide or WIDTHxHEIGHT")
        sizes.append((part, int(match[1]), int(match[2])))
    return sizes


def frame_base(gallery_url: str) -> str:
    """`http://host/gallery/#/entry` (the shell) to `http://host/gallery/frame.html`."""
    base = gallery_url.split("#", 1)[0].split("?", 1)[0]
    if base.endswith(".html"):
        base = base.rsplit("/", 1)[0]
    return base.rstrip("/") + "/frame.html"


def build_spec(args: argparse.Namespace, resolved: dict, gallery_url: str) -> dict:
    query = {"entry": args.entry, **({"variant": args.variant} if args.variant else {}), **resolved["query"]}
    query["frame"] = "component"
    stages = []
    for label, width, height in parse_sizes(args.sizes):
        url = f"{frame_base(gallery_url)}?{urllib.parse.urlencode({**query, 'width': str(width)})}"
        title = f"{args.entry}{' · ' + args.variant if args.variant else ''} · {label}"
        stages.append({"title": title, "url": url, "width": width, "height": height})
    return {
        "stages": stages,
        "backdrop": resolved["backdrop"],
        "appearance": resolved["appearance"],
        "loopSeconds": args.loop,
    }


def local_gallery_url(entry: str) -> str:
    """Start or reuse the local HMR gallery (preview.sh never opens a tab without --open)."""
    out = subprocess.run(
        [str(REPO / "scripts/cmux-next/preview.sh"), "gallery", "--entry", entry, "--json"],
        capture_output=True,
        text=True,
    )
    try:
        record = json.loads(out.stdout.strip().splitlines()[-1])
    except (IndexError, json.JSONDecodeError):
        record = {}
    url = record.get("gallery_url")
    if out.returncode != 0 or not url:
        sys.stderr.write(out.stderr or out.stdout)
        raise SystemExit("gallery-window: the local gallery did not start; pass --gallery URL")
    return url


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--entry", required=True, help="gallery entry id, e.g. agent-pane.composer")
    parser.add_argument("--variant", help="the entry's variant (default: its first)")
    parser.add_argument("--sizes", default=DEFAULT_SIZES, help="narrow, normal, wide or WIDTHxHEIGHT, comma separated")
    parser.add_argument("--gallery", help="a gallery URL (default: the local HMR gallery)")
    parser.add_argument("--config", type=Path, help="cmux-next.json (default: ~/.config/cmux/cmux-next.json)")
    parser.add_argument("--theme", help="a Ghostty theme name instead of your own")
    parser.add_argument("--loop", type=float, default=1.5, help="seconds between replays; 0 shows each stage once")
    parser.add_argument("--print-spec", action="store_true", help="print the host's spec and exit")
    args = parser.parse_args(argv)

    home = Path.home()
    config = args.config or Path(os.environ.get("CMUX_NEXT_CONFIG_FILE") or home / ".config/cmux/cmux-next.json")
    resolved = resolve_appearance(
        read_settings(config.expanduser()), read_ghostty(ghostty_paths(home)), system_is_dark(), dt.date.today()
    )
    if args.theme:
        resolved["query"]["theme"] = args.theme
    gallery_url = args.gallery or ("http://127.0.0.1:4178/gallery/" if args.print_spec else local_gallery_url(args.entry))
    spec = build_spec(args, resolved, gallery_url)
    if args.print_spec:
        print(json.dumps(spec, indent=2))
        return 0
    if sys.platform != "darwin":
        raise SystemExit("gallery-window: the window host is macOS only (--print-spec works anywhere)")

    subprocess.run(
        ["swift", "build", "-c", "release", "--package-path", str(HOST_PACKAGE), "--product", "cmux-gallery-window"],
        check=True,
    )
    with tempfile.NamedTemporaryFile("w", suffix=".json", prefix="cmux-gallery-window-", delete=False) as handle:
        json.dump(spec, handle)
    try:
        host = HOST_PACKAGE / ".build/release/cmux-gallery-window"
        return subprocess.run([str(host), "--spec", handle.name]).returncode
    finally:
        os.unlink(handle.name)


if __name__ == "__main__":
    sys.exit(main())
