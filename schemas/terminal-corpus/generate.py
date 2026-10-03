#!/usr/bin/env python3
"""Generate the terminal fidelity corpus (plans/cmux-next/ghostty-next.md s12).

Each case is a recorded-style PTY byte stream. The fidelity test feeds one
case to the session host's libghostty-vt and to the phone's libghostty-vt
(GhosttyNextKit) and requires byte-equal GHOSTSNP snapshots when both use the
same snapshot version. `manifest.json` lists every case, its grid size and the
snapshot features it exercises. Output is deterministic: rerun this script and
`git diff --exit-code` must be clean.

Usage: generate.py [--flood-bytes N] [--flood-out PATH]
  --flood-out writes the flood stream (not committed; 100 MB by default) for
  the flood test.
"""
from __future__ import annotations

import argparse
import base64
import json
import random
import zlib
from pathlib import Path

HERE = Path(__file__).resolve().parent
ESC = "\x1b"
CSI = ESC + "["
OSC = ESC + "]"
ST = ESC + "\\"
BEL = "\x07"


def shell_prompt() -> str:
    out = []
    for n in range(40):
        out.append(f"{OSC}133;A{ST}")
        out.append(f"{OSC}7;file://localhost/Users/dev/project{n % 3}{ST}")
        out.append(f"{OSC}2;dev@host: ~/project{n % 3}{BEL}")
        out.append(f"{CSI}1;32mdev@host{CSI}0m:{CSI}1;34m~/project{n % 3}{CSI}0m$ ")
        out.append(f"{OSC}133;B{ST}")
        out.append(f"ls -la src/{n}\r\n")
        out.append(f"{OSC}133;C{ST}")
        for i in range(6):
            out.append(f"-rw-r--r--  1 dev staff {1000 + 37 * i + n:6d} Oct  2 12:{i:02d} {CSI}3{(i % 6) + 1}mfile_{n}_{i}.zig{CSI}0m\r\n")
        out.append(f"{OSC}133;D;0{ST}")
    return "".join(out)


def alt_screen_editor() -> str:
    out = [f"{CSI}?1049h{CSI}H{CSI}2J{CSI}?25l"]
    out.append(f"{CSI}1;22r")  # scroll region
    for row in range(1, 23):
        out.append(f"{CSI}{row};1H{CSI}38;5;{240 + row % 10}m{row:4d} {CSI}0m")
        out.append(f"{CSI}48;2;30;30;46mfn line_{row}() -> {CSI}1mu32{CSI}22m {{ return {row}; }}{CSI}K{CSI}0m")
    out.append(f"{CSI}24;1H{CSI}7m-- INSERT --  src/main.zig  [+]{CSI}0m{CSI}K")
    out.append(f"{CSI}5;10H{CSI}?25h{CSI}2 q")  # cursor style bar
    out.append(f"{CSI}3S")  # scroll up inside the region
    out.append(f"{CSI}?2004h{CSI}?1000h{CSI}?1006h")  # modes a mirror must report
    return "".join(out)


def wide_combining() -> str:
    lines = [
        "漢字かなカナ 한국어 全角テキスト",
        "é ä ñ ộ combining",
        "\U0001F468‍\U0001F469‍\U0001F467 family zwj, \U0001F44D\U0001F3FD skin tone",
        "☃ ❤️ variation selectors ⚠︎",
        "box ┌─┬─┐ │a│b│ └─┴─┘ braille ⠿⠇",
    ]
    out = []
    for i, line in enumerate(lines * 4):
        out.append(f"{CSI}{31 + i % 7}m{line}{CSI}0m\r\n")
    return "".join(out)


def hyperlinks() -> str:
    out = []
    for i in range(20):
        out.append(f"{OSC}8;id=link{i};https://example.invalid/item/{i}{ST}item {i}{OSC}8;;{ST} ")
        out.append(f"{CSI}4:3;58:2::255:0:0mcurly{CSI}0m {CSI}9mstrike{CSI}0m\r\n")
    return "".join(out)


def styles() -> str:
    out = []
    for i in range(256):
        out.append(f"{CSI}38;5;{i}m{i:3d}{CSI}48;5;{255 - i}m#{CSI}0m")
        if i % 16 == 15:
            out.append("\r\n")
    for r in range(0, 256, 32):
        for g in range(0, 256, 32):
            out.append(f"{CSI}48;2;{r};{g};{(r + g) % 256}m {CSI}0m")
        out.append("\r\n")
    for sgr in ("1", "2", "3", "4", "4:2", "4:4", "4:5", "5", "7", "8", "53"):
        out.append(f"{CSI}{sgr}msgr {sgr}{CSI}0m ")
    out.append("\r\n")
    return "".join(out)


def scrollback() -> str:
    rng = random.Random(1307)
    words = ["alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta"]
    out = []
    for n in range(5000):
        color = rng.choice(["0", "31", "32", "33", "1;34", "38;5;208", "38;2;120;200;255"])
        text = " ".join(rng.choice(words) for _ in range(rng.randint(1, 18)))
        out.append(f"{CSI}{color}m[{n:05d}] {text}{CSI}0m\r\n")
    return "".join(out)


def kitty_graphics() -> str:
    # A 2x2 RGBA image sent as raw pixels (f=32), placed twice. GHOSTSNP v1
    # does not carry images; the manifest marks this case so the byte-equal
    # check compares text state and the image replay is checked separately.
    pixels = bytes([255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 255])
    payload = base64.b64encode(zlib.compress(pixels)).decode()
    out = [f"{ESC}_Ga=T,f=32,s=2,v=2,o=z,i=7,q=2;{payload}{ST}", "image above\r\n"]
    out.append(f"{ESC}_Ga=p,i=7,q=2{ST}placed again\r\n")
    return "".join(out)


CASES = {
    "shell-prompt": (shell_prompt, 120, 40, ["semantic-prompts", "osc7", "title", "scrollback"]),
    "alt-screen-editor": (alt_screen_editor, 100, 24, ["alt-screen", "scroll-region", "cursor-style", "modes"]),
    "wide-combining": (wide_combining, 80, 24, ["wide", "graphemes", "variation-selectors"]),
    "hyperlinks": (hyperlinks, 100, 30, ["osc8", "underline-color", "underline-styles"]),
    "styles": (styles, 132, 50, ["palette", "truecolor", "sgr"]),
    "scrollback": (scrollback, 120, 40, ["scrollback-5000"]),
    "kitty-graphics": (kitty_graphics, 80, 24, ["kitty-images-excluded-from-ghostsnp-v1"]),
}


def flood(path: Path, size: int) -> None:
    rng = random.Random(42)
    written = 0
    with path.open("wb") as handle:
        n = 0
        while written < size:
            line = f"{CSI}3{n % 8}m{n:09d} " + "x" * rng.randint(10, 150) + f"{CSI}0m\r\n"
            data = line.encode()
            handle.write(data)
            written += len(data)
            n += 1


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--flood-bytes", type=int, default=100 * 1024 * 1024)
    parser.add_argument("--flood-out", type=Path)
    args = parser.parse_args()
    manifest = {"version": 1, "snapshot_format": "GHOSTSNP", "cases": []}
    for name, (fn, cols, rows, features) in CASES.items():
        data = fn().encode("utf-8")
        (HERE / f"{name}.vt").write_bytes(data)
        manifest["cases"].append({"name": name, "file": f"{name}.vt", "cols": cols, "rows": rows,
                                  "bytes": len(data), "features": features})
    (HERE / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    if args.flood_out:
        flood(args.flood_out, args.flood_bytes)


if __name__ == "__main__":
    main()
