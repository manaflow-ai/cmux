#!/usr/bin/env python3
"""Generate the terminal fidelity corpus (plans/cmux-next/ghostty-next.md s12)
and the oracle's terminal suite (plans/cmux-next/chrome-parity/p15-oracle.md,
task p15-oracle-101).

Each fidelity case is a recorded-style PTY byte stream. The fidelity test feeds
one case to the session host's libghostty-vt and to the phone's libghostty-vt
(GhosttyNextKit) and requires byte-equal GHOSTSNP snapshots when both use the
same snapshot version. `manifest.json` lists every case, its grid size and the
snapshot features it exercises.

The oracle suite (`tests/oracle/corpus/terminal/`, >= 200 cases) feeds seeded
streams (SGR, wide characters, the alternate screen, scroll regions, OSC 8, 7
and 133, DECCOLM column switches in the stream, scrollback) and the recorded
streams that fit in one argument to a daemon terminal. It reads the terminal's VT state
(`terminal.state.read`) and screen, and a second terminal puts their sha256 in
its title, which the daemon facet carries. So every later checkpoint holds the
VT-state hash. A run per terminal-holder arm (the per-terminal host and
CMUX_TUI_TERMINAL_HOST_MODEL=holder) and a diff of the two compares the arms
on it; a golden baseline of the suite pins it. `manifest.json` lists the
families under `oracle`, and under `oracle.gaps` the spec items that no case
covers yet, each with the WORK.tsv task that adds it.

Output is deterministic: run the script again and the checkout must not change.

Usage: generate.py [--flood-bytes N] [--flood-out PATH] [--oracle-out DIR] [--oracle-only]
  --flood-out writes the flood stream (not committed; 100 MB by default) for
  the flood test.
  --oracle-out writes the oracle cases to DIR instead of
  tests/oracle/corpus/terminal; the *.json files already there are removed first.
  --oracle-only writes only the oracle cases. The oracle cases are not committed:
  scripts/cmux-next/oracle/corpus_store.py runs this to write them before use.
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
import random
import zlib
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
ORACLE_DIR = REPO / "tests" / "oracle" / "corpus" / "terminal"
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
    "kitty-graphics": (kitty_graphics, 80, 24, ["kitty-placements", "kitty-image-data-not-in-ghostsnp-v1"]),
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


# ---------------------------------------------------------------------------
# The oracle's terminal suite.
#
# One case: an empty workspace, a terminal of the case's size that runs
# FEED_SCRIPT on the stream (printf of one argv string, so the bytes reach the
# VT parser unchanged and no line discipline or shell echo is in the way), a
# settle on the title FEED_SCRIPT sets after the stream, the two reads, and a
# second terminal that runs HASH_SCRIPT on the two replies and exits. Chromium
# keeps a hashed render tree in the same role: the web tests' -expected.txt
# dumps and pixel hashes (third_party/blink/tools/blinkpy/web_tests) compare a
# digest of the state, never a screenshot of it.

ORACLE_SUITE = "terminal"
FED_TITLE = "oracle-vt-fed"
FEED_SCRIPT = "printf '%s' \"$1\"; printf '\\033]2;%s\\007' \"$2\"; exec cat"
HASH_SCRIPT = (
    "d() { if command -v sha256sum >/dev/null 2>&1; then printf '%s' \"$1\" | sha256sum; "
    "else printf '%s' \"$1\" | shasum -a 256; fi; }; "
    "printf '\\033]2;vt:%.64s screen:%.64s\\007' \"$(d \"$1\")\" \"$(d \"$2\")\""
)
# Linux refuses one exec argument over MAX_ARG_STRLEN (32 pages, 128 KiB); the
# state reply of the largest stream must still fit when HASH_SCRIPT gets it.
MAX_STREAM_BYTES = 24 * 1024
SIZES = ((80, 24), (100, 30), (120, 40), (132, 50), (40, 12), (60, 20), (20, 6))
WORDS = ("alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta", "iota", "kappa",
         "λόγος", "naïve", "café", "ünïcödé", "x", "--flag", "a/b/c", "{}", "[ok]", "100%")
WIDE = ("漢字", "かな", "カナ", "한국어", "全角", "中文字符", "\U0001F600", "\U0001F680",
        "\U0001F44D\U0001F3FD", "\U0001F468\u200d\U0001F469\u200d\U0001F467", "\U0001F1EF\U0001F1F5",
        "\u2764\ufe0f", "\u26a0\ufe0e", "e\u0301", "a\u0308\u0323", "\u0915\u094d\u0937", "\u2603",
        "\uff21\uff22\uff23")
LINK_HOSTS = ("http://127.0.0.1:8123", "http://localhost", "http://[::1]:9", "file://")


def _seeded(name: str) -> random.Random:
    return random.Random(zlib.crc32(name.encode()))


def _words(rng: random.Random, low: int, high: int) -> str:
    return " ".join(rng.choice(WORDS) for _ in range(rng.randint(low, high)))


def _sgr(rng: random.Random) -> str:
    """One SGR parameter list: plain attributes, their resets, 8/16/256/direct colors, underline styles and color."""
    def color() -> str:
        kind = rng.randrange(7)
        if kind == 0:
            return str(rng.choice([*range(30, 38), *range(90, 98)]))
        if kind == 1:
            return str(rng.choice([*range(40, 48), *range(100, 108)]))
        if kind == 2:
            return f"{rng.choice((38, 48, 58))};5;{rng.randrange(256)}"
        r, g, b = rng.randrange(256), rng.randrange(256), rng.randrange(256)
        if kind == 3:
            return f"{rng.choice((38, 48))};2;{r};{g};{b}"
        if kind == 4:
            return f"{rng.choice((38, 48, 58))}:2::{r}:{g}:{b}"
        if kind == 5:
            return f"4:{rng.randrange(6)}"
        return rng.choice(("39", "49", "59"))
    plain = ("1", "2", "3", "4", "5", "7", "8", "9", "21", "53", "22", "23", "24", "25", "27", "28", "29", "55", "0")
    parts = [color() if rng.random() < 0.55 else rng.choice(plain) for _ in range(rng.randint(1, 4))]
    return ";".join(parts)


def oracle_sgr(rng: random.Random, cols: int, rows: int) -> str:
    out = []
    for _ in range(rng.randint(rows // 2, rows + 4)):
        for _ in range(rng.randint(1, 6)):
            out.append(f"{CSI}{_sgr(rng)}m{_words(rng, 1, 4)} ")
        tail = rng.randrange(5)
        if tail == 0:
            out.append(f"{CSI}{_sgr(rng)}m{CSI}K")  # erase to the end with the current background (BCE)
        elif tail == 1:
            out.append(f"{CSI}{rng.randint(1, 8)}D{CSI}{rng.randint(1, 6)}X")  # back, then erase characters
        elif tail == 2:
            out.append(f"{CSI}0m")
        out.append("\r\n")
    out.append(f"{CSI}0m")
    return "".join(out)


def oracle_wide(rng: random.Random, cols: int, rows: int) -> str:
    out = [f"{CSI}?2027h"] if rng.random() < 0.3 else []
    if rng.random() < 0.25:
        out.append(f"{CSI}?7l")  # no autowrap: wide cells pile up at the right edge
    for _ in range(rng.randint(4, rows)):
        op = rng.randrange(6)
        if op == 0:
            out.append(" ".join(rng.choice(WIDE) for _ in range(rng.randint(2, 10))))
        elif op == 1:
            out.append(f"{CSI}{cols - rng.randint(0, 2)}G{rng.choice(WIDE)}{rng.choice(WIDE)}")  # a wide cell at the last column
        elif op == 2:
            out.append(f"{rng.choice(WIDE)}{rng.choice(WIDE)}{CSI}{rng.randint(1, 4)}D{rng.choice('xyz')}")  # into a wide cell's half
        elif op == 3:
            out.append(f"{''.join(rng.choice(WIDE) for _ in range(5))}{CSI}{rng.randint(1, 9)}G"
                       f"{CSI}{rng.randint(1, 3)}{rng.choice('@PX')}")  # insert, delete or erase across wide cells
        elif op == 4:
            out.append("\t".join(rng.choice(WIDE) for _ in range(rng.randint(2, 5))))
        else:
            out.append(f"{CSI}{rng.randint(31, 37)}m{_words(rng, 1, 3)} {rng.choice(WIDE)}{CSI}0m")
        out.append("\r\n")
    return "".join(out)


def oracle_alt(rng: random.Random, cols: int, rows: int) -> str:
    out = [f"primary {n} {_words(rng, 1, 5)}\r\n" for n in range(rng.randint(2, rows))]
    for _ in range(rng.randint(1, 3)):
        mode = rng.choice((1049, 1047, 47))
        if rng.random() < 0.3:
            out.append(f"{CSI}?1048h")  # save the cursor on its own
        out.append(f"{ESC}7" if rng.random() < 0.3 else "")
        out.append(f"{CSI}?{mode}h")
        if rng.random() < 0.6:
            out.append(f"{CSI}H{CSI}2J")
        for _ in range(rng.randint(1, rows)):
            out.append(f"{CSI}{rng.randint(1, rows)};{rng.randint(1, cols)}H{CSI}{_sgr(rng)}m{_words(rng, 1, 3)}{CSI}0m")
        if rng.random() < 0.7:
            out.append(f"{CSI}?{mode}l")
            out.append(f"{ESC}8" if rng.random() < 0.3 else "")
            out.append(f"{CSI}?1048l" if rng.random() < 0.3 else "")
            out.append(f"back {_words(rng, 1, 4)}\r\n")
    return "".join(out)


def oracle_region(rng: random.Random, cols: int, rows: int) -> str:
    out = [f"{CSI}H{CSI}2J"]
    out += [f"{CSI}{n};1Hrow-{n:02d} {_words(rng, 0, 3)}" for n in range(1, rows + 1)]
    top = rng.randint(1, max(1, rows - 2))
    bottom = rng.randint(top + 1, rows)
    out.append(f"{CSI}{top};{bottom}r")
    if rng.random() < 0.3:
        left = rng.randint(1, max(1, cols // 2))
        out.append(f"{CSI}?69h{CSI}{left};{rng.randint(left + 1, cols)}s")  # DECLRMM and DECSLRM
    if rng.random() < 0.3:
        out.append(f"{CSI}?6h")  # origin mode: CUP is relative to the region
    for _ in range(rng.randint(3, 12)):
        op = rng.randrange(6)
        n = rng.randint(1, 4)
        if op == 0:
            out.append(f"{CSI}{bottom};1H" + "".join(f"down {_words(rng, 1, 2)}{ESC}D" for _ in range(n)))  # IND at the bottom margin
        elif op == 1:
            out.append(f"{CSI}{top};1H" + "".join(f"{ESC}Mup {_words(rng, 1, 2)}" for _ in range(n)))  # RI at the top margin
        elif op == 2:
            out.append(f"{CSI}{n}{rng.choice('ST')}")
        elif op == 3:
            out.append(f"{CSI}{rng.randint(top, bottom)};1H{CSI}{n}{rng.choice('LM')}")
        elif op == 4:
            out.append(f"{CSI}{rng.randint(1, rows)};{rng.randint(1, cols)}H{_words(rng, 1, 3)}")
        else:
            out.append("".join(f"{ESC}E{_words(rng, 1, 2)}" for _ in range(n)))  # NEL
    if rng.random() < 0.5:
        out.append(f"{CSI}?6l{CSI}?69l{CSI}r")
    return "".join(out)


def _osc_end(rng: random.Random) -> str:
    return rng.choice((BEL, ST))


def oracle_osc(rng: random.Random, cols: int, rows: int) -> str:
    out = []
    kind = rng.randrange(5)
    for n in range(rng.randint(3, max(4, rows - 2))):
        end = _osc_end(rng)
        if kind in (0, 4):  # hyperlinks: ids, a link across the wrap, a link replaced while open
            host = rng.choice(LINK_HOSTS)
            uri = f"{host}/tmp/item-{n}?q={rng.randrange(1000)}" if host != "file://" else f"file:///tmp/item-{n}"
            link_id = f"id=l{n % 3}" if rng.random() < 0.5 else ""
            text = _words(rng, 1, 3)
            if rng.random() < 0.3:
                out.append(f"{CSI}{max(1, cols - 3)}G")
            out.append(f"{OSC}8;{link_id};{uri}{end}{CSI}{_sgr(rng)}m{text}{CSI}0m")
            if rng.random() < 0.8:
                out.append(f"{OSC}8;;{end}")
            out.append(f" {_words(rng, 0, 2)}\r\n")
        if kind in (1, 4):  # working directory
            out.append(f"{OSC}7;file://localhost/tmp/dir%20{n}/{rng.choice(WORDS[:10])}{end}")
        if kind in (2, 4):  # semantic prompts with exit codes
            out.append(f"{OSC}133;A{end}$ {OSC}133;B{end}cmd-{n} {_words(rng, 0, 2)}\r\n{OSC}133;C{end}")
            out.append(f"out {_words(rng, 1, 4)}\r\n{OSC}133;D;{rng.choice((0, 0, 1, 2, 127))}{end}")
        if kind == 3:  # titles, palette and default colors
            sub = rng.randrange(4)
            if sub == 0:
                out.append(f"{OSC}{rng.choice((0, 1, 2))};title {n} {_words(rng, 1, 2)}{end}")
            elif sub == 1:
                out.append(f"{OSC}4;{rng.randrange(256)};rgb:{rng.randrange(256):02x}/{rng.randrange(256):02x}/"
                           f"{rng.randrange(256):02x}{end}{CSI}38;5;{rng.randrange(256)}mpal{CSI}0m\r\n")
            elif sub == 2:
                out.append(f"{OSC}{rng.choice((10, 11, 12))};#{rng.randrange(1 << 24):06x}{end}fg/bg\r\n")
            else:
                out.append(f"{OSC}{rng.choice((104, 110, 111, 112))}{end}reset\r\n")
    return "".join(out)


def _long_line(rng: random.Random, n: int, width: int) -> str:
    text = f"[{n:03d}] " + _words(rng, width // 12, width // 4)
    return f"{CSI}{rng.randint(31, 37)}m{text}{CSI}0m\r\n"


def oracle_deccolm(rng: random.Random, cols: int, rows: int) -> str:
    """DECCOLM (mode 3, allowed by mode 40) switches the grid between 80 and 132 columns inside the stream, with
    wrapped lines before and after. Only the VT parser sees it: the PTY size does not change (see ORACLE_GAPS)."""
    out = [_long_line(rng, n, cols) for n in range(rng.randint(2, rows))]
    allowed = rng.random() < 0.85
    out.append(f"{CSI}?40{'h' if allowed else 'l'}")
    if rng.random() < 0.3:
        out.append(f"{CSI}2;{max(3, rows - 1)}r")  # DECCOLM resets the margins
    if rng.random() < 0.25:
        out.append(f"{CSI}?1049h")
    for step in range(rng.randint(1, 4)):
        out.append(f"{CSI}?3{'h' if step % 2 == 0 else 'l'}")
        width = 132 if step % 2 == 0 else 80
        out += [_long_line(rng, 100 * (step + 1) + n, width) for n in range(rng.randint(1, min(rows, 16)))]
    return "".join(out)


def oracle_scrollback(rng: random.Random, cols: int, rows: int) -> str:
    out = []
    for n in range(rng.randint(rows * 2, 300)):
        out.append(f"{CSI}{rng.choice(('0', '31', '1;32', '38;5;208', '38;2;120;200;255'))}m[{n:04d}] "
                   f"{_words(rng, 1, 8)}{CSI}0m\r\n")
        if rng.random() < 0.01:
            out.append(rng.choice((f"{CSI}3J", f"{CSI}2J", f"{CSI}H{CSI}2J{CSI}3J")))
    return "".join(out)


ORACLE_FAMILIES = {
    # family: (generator, count, features)
    "sgr": (oracle_sgr, 40, ["sgr", "palette", "truecolor", "underline-styles", "underline-color", "bce", "ech"]),
    "wide": (oracle_wide, 35, ["wide", "graphemes", "variation-selectors", "mode-2027", "ich-dch", "no-autowrap"]),
    "alt": (oracle_alt, 30, ["alt-screen-1049", "alt-screen-1047", "alt-screen-47", "save-cursor"]),
    "region": (oracle_region, 35, ["scroll-region", "left-right-margins", "origin-mode", "ind-ri", "su-sd", "il-dl"]),
    "osc": (oracle_osc, 35, ["osc8", "osc7", "osc133", "title", "osc4", "osc10-12"]),
    "deccolm": (oracle_deccolm, 30, ["deccolm-in-band", "mode-40", "wrap", "scroll-region"]),
    "scrollback": (oracle_scrollback, 15, ["scrollback", "erase-scrollback"]),
}
# Spec items of p15-oracle-101 that no case covers yet: the task that adds each, and why the oracle cannot run it now.
ORACLE_GAPS = [
    {"spec": "resize during output", "task": "p15-oracle-101b",
     "why": "a PTY resize from the daemon while the child writes (winsize and SIGWINCH, where the holder arms "
            "differ) needs terminal.viewer.resize, and only terminal.attach returns its attachment_lease. "
            "terminal.attach is a stream_open operation; driver_daemon.py's resource.call sends only reads, "
            "mutations and connection_control (streams are p15-oracle-204). The deccolm family switches columns "
            "inside the stream, which only the VT parser sees, the same on both arms."},
]
# Recorded fidelity streams that are not oracle cases, and why.
RECORDED_LEFT_OUT = {
    "hyperlinks": "its links name example.invalid; oracle cases are offline and may name only loopback hosts",
    "scrollback": f"377,860 bytes, over one exec argument's 128 KiB; the scrollback family covers it in {MAX_STREAM_BYTES} bytes",
}


def _sha256(text: str) -> str:
    return "sha256:" + hashlib.sha256(text.encode()).hexdigest()


def oracle_case(case_id: str, title: str, stream: str, cols: int, rows: int, features: list) -> dict:
    """The case-v1 document of one stream (schemas/oracle/case-v1.schema.json)."""
    current = {"machine": "current", "session": "current"}
    workspace = {**current, "workspace": "$step:fx-workspace#/value/workspace_id"}
    terminal = {**current, "terminal": "$step:feed#/value/terminal_id"}

    def run(step: str, params: dict) -> dict:
        return {"method": "workspace.run", "params": params, "idempotencyKey": f"{case_id}.{step}"}

    return {
        "$schema": "../../../../schemas/oracle/case-v1.schema.json",
        "corpusVersion": 1,
        "id": case_id,
        "suite": ORACLE_SUITE,
        "title": title,
        "surface": "cmux-next-daemon",
        "source": {"repo": "manaflow-ai/cmux", "ref": "$RUN", "artifact": "$RUN"},
        "environment": {},
        "fixture": {"seed": f"terminal.{case_id}", "network": "offline", "clock": "virtual"},
        "preconditions": ["hermetic state root", "no other cmux-tui on the state root"],
        "requires": ["resource_api"],
        "switches": ["terminal-holder"],
        "platforms": ["linux", "mac"],
        "steps": [
            {"id": "fx-workspace", "op": "resource.call", "target": current,
             "args": {"method": "workspace.create", "params": {"initial_content": "empty", "name": "oracle"},
                      "idempotencyKey": f"{case_id}.fx-workspace"},
             "expect": {"outcome": "ok", "receipt": "mutation_result"}},
            {"id": "feed", "op": "resource.call", "target": workspace,
             "args": run("feed", {"argv": ["/bin/sh", "-c", FEED_SCRIPT, "sh", stream, FED_TITLE],
                                  "cols": cols, "rows": rows}),
             "expect": {"outcome": "ok", "receipt": "mutation_result"},
             "note": f"a {cols}x{rows} terminal prints the {len(stream.encode())}-byte stream, then the title {FED_TITLE}"},
            {"id": "fed", "op": "settle",
             "waitFor": {"pointer": "/daemon/session/terminals/0/title", "equals": _sha256(FED_TITLE), "maxMs": 10000},
             "settleMaxMs": 10000,
             "note": "the title comes after the stream, so the parser has taken every byte of it"},
            {"id": "state", "op": "resource.call", "target": terminal, "args": {"method": "terminal.state.read"},
             "readOnly": True, "expect": {"outcome": "ok"}},
            {"id": "screen", "op": "resource.call", "target": terminal, "args": {"method": "terminal.screen.read"},
             "readOnly": True, "expect": {"outcome": "ok"}},
            {"id": "hash", "op": "resource.call", "target": workspace,
             "args": run("hash", {"argv": ["/bin/sh", "-c", HASH_SCRIPT, "sh", "$step:state#/state_base64",
                                           "$step:screen#/text"], "cwd": "/", "on_exit": "keep"}),
             "expect": {"outcome": "ok", "receipt": "mutation_result"},
             "note": "a second terminal titles itself vt:<sha256 of the VT state> screen:<sha256 of the screen text>; "
                     "it starts in / because a new terminal otherwise inherits the folder the stream's OSC 7 "
                     "reported, which does not exist"},
            {"id": "hashed", "op": "settle",
             "waitFor": {"pointer": "/daemon/session/terminals/1/lifecycle", "equals": "exited", "maxMs": 10000},
             "settleMaxMs": 10000,
             "note": "the settled checkpoint holds the hash terminal's title: the arms and the baseline compare it"},
        ],
        "invariants": [
            "generated by schemas/terminal-corpus/generate.py (p15-oracle-101); features: " + ", ".join(features),
            "the VT state and screen of the stream terminal hash to the same title on both terminal-holder arms",
        ],
        "teardown": ["stop the case daemon", "verify the socket and state root are gone"],
    }


def oracle_cases(recorded: dict) -> dict:
    """Every oracle case by id, generated families first, then the recorded streams that fit."""
    cases = {}
    for family, (fn, count, features) in ORACLE_FAMILIES.items():
        for n in range(count):
            case_id = f"{family}-{n:03d}"
            cols, rows = SIZES[zlib.crc32(case_id.encode()) % len(SIZES)]
            stream = fn(_seeded(case_id), cols, rows)
            cases[case_id] = oracle_case(case_id, f"VT {family} stream {n} at {cols}x{rows}", stream, cols, rows,
                                         features)
    for name, (stream, cols, rows, features) in recorded.items():
        if name in RECORDED_LEFT_OUT:
            continue
        case_id = f"recorded-{name}"
        cases[case_id] = oracle_case(case_id, f"VT recorded stream {name}.vt at {cols}x{rows}", stream, cols, rows,
                                     features)
    for case_id, case in cases.items():
        size = len(case["steps"][1]["args"]["params"]["argv"][4].encode())
        if size > MAX_STREAM_BYTES:
            raise SystemExit(f"{case_id}: a {size}-byte stream is over {MAX_STREAM_BYTES} bytes")
    return cases


def oracle_manifest(cases: dict) -> dict:
    """The manifest's `oracle` entry. It has no `name` key: the fidelity tests split the case list on it."""
    families = [{"family": family, "count": count, "features": features}
                for family, (_, count, features) in ORACLE_FAMILIES.items()]
    families.append({"family": "recorded", "count": sum(1 for c in cases if c.startswith("recorded-")),
                     "features": ["the recorded streams above"], "left_out": RECORDED_LEFT_OUT})
    return {"suite": ORACLE_SUITE, "dir": "tests/oracle/corpus/terminal", "total": len(cases),
            "switches": ["terminal-holder"], "families": families, "gaps": ORACLE_GAPS}


def case_text(case: dict) -> str:
    return json.dumps(case, indent=2, ensure_ascii=False) + "\n"


def write_oracle(out: Path, cases: dict) -> None:
    out.mkdir(parents=True, exist_ok=True)
    for old in out.glob("*.json"):
        old.unlink()
    for case_id, case in cases.items():
        (out / f"{case_id}.json").write_text(case_text(case), encoding="utf-8")


def build() -> tuple:
    """(the .vt bytes by file name, manifest.json's text, the oracle cases by id); writes nothing."""
    manifest = {"version": 1, "snapshot_format": "GHOSTSNP", "cases": []}
    streams = {}
    recorded = {}
    for name, (fn, cols, rows, features) in CASES.items():
        text = fn()
        data = text.encode("utf-8")
        streams[f"{name}.vt"] = data
        manifest["cases"].append({"name": name, "file": f"{name}.vt", "cols": cols, "rows": rows,
                                  "bytes": len(data), "features": features})
        recorded[name] = (text, cols, rows, features)
    cases = oracle_cases(recorded)
    manifest["oracle"] = oracle_manifest(cases)
    return streams, json.dumps(manifest, indent=2) + "\n", cases


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--flood-bytes", type=int, default=100 * 1024 * 1024)
    parser.add_argument("--flood-out", type=Path)
    parser.add_argument("--oracle-out", type=Path, default=ORACLE_DIR)
    parser.add_argument("--oracle-only", action="store_true",
                        help="write only the oracle cases (scripts/cmux-next/oracle/corpus_store.py: the suite is not committed)")
    args = parser.parse_args()
    streams, manifest, cases = build()
    if not args.oracle_only:
        for file, data in streams.items():
            (HERE / file).write_bytes(data)
        (HERE / "manifest.json").write_text(manifest)
    write_oracle(args.oracle_out, cases)
    if args.flood_out:
        flood(args.flood_out, args.flood_bytes)


if __name__ == "__main__":
    main()
