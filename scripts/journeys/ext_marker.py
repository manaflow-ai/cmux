#!/usr/bin/python3 -I
"""Frame markers: a journey's own line, read from the frame's pixels, never by text recognition (REWRITE R-HARNESS S5).

driver.py loads this file (load_extensions) on the mini under /usr/bin/python3 (3.9, standard library only). It must
not import driver.py: install() gets the driver module. The same file is the marker program the terminal runs.

Why (STATUS 9303, 9402, 9444, 2026-11-03): the text reader (Vision) read "733287-42" as "733287-4źął",
"jq-447486-400" as "j9-447486-400", and returned 0 lines for a correct frame that held a long digit line. Three P0
journeys failed while the daemon and app checks of the same line passed. A frame check that a language model decides
can fail, or pass, on what the frame does not show. A marker is one row of truecolor cells that the terminal itself
draws; a pixel reader decodes it.

Step (`do`):
  marker_install {}       writes this file to /tmp/jr-m-<nonce>-<random> (mode 755; removed when the journey ends) and binds
                          ${marker} to that path. Then type `${marker} TOKEN` (e.g. `${marker} ok-${nonce}-$((6*7))`):
                          the shell expands the token, and the program prints TOKEN as a text line (so daemon_line and
                          app_text_line check the same text as `echo TOKEN` did) and, below it, the marker of TOKEN.
Conditions (evidence kind frame):
  frame_marker "TOKEN"    a fresh snapshot of the window shows TOKEN's marker, decoded with its check
  frame_marker_lacks {"token": T, "with": W}
                          negative: the snapshot shows W's marker (the frame is this run's and readable), no marker of
                          T, and no unreadable marker (a marker that is cut or covered cannot prove an absence)

The marker of a token, left to right, one terminal cell each (MARKER_CELLS = 30):
  START  magenta yellow blue magenta (a sequence no app view draws)
  DATA   21 base-5 digits of V = D << 24 | CRC-24(D), D = the first 3 bytes of sha256(token)
  END    the digits 0 1 0 2
  TERM   one cell that bounds the last END cell (red, blue, yellow or magenta: never a theme ground)
Each digit picks the next cell's color among the colors that differ from the cell before it, in the order of ORDER,
so every cell boundary is a color change and every cell is one run of exactly one cell width. Only six colors are
used: black, white, red, blue, yellow, magenta. They keep their class through the changes a capture can make (sRGB
values shown as Display P3, P3 clipped to sRGB, a 30 % dimming overlay); green and cyan do not (sRGB green read as P3
has red 117) and are never drawn. A pixel's class: each channel on (>= 160) or off (<= 96), else no class.
The reader decodes a marker only when every row of its cell decodes the same, every run is exactly the START's cell
width, the END digits are right, V < 2^48 and the CRC-24 holds; a start that is followed by anything else is an
unreadable marker. A corrupted marker reads as another token only when the corruption is a valid code word: 2^-24.

  ext_marker.py TOKEN     (the program) prints TOKEN, a blank line, its marker and a blank line; exit 2 for a token
                          that is not 1-64 printable ASCII characters without spaces, 3 when the pane (the terminal's
                          own size) has fewer than MARKER_CELLS columns, 4 when its output is no terminal
Tests: scripts/journeys/test_ext_marker.py (no app, no fleet; 800 markers decoded, 3000 corrupted ones refused).
"""
import hashlib
import itertools
import os
import re
import struct
import sys
import zlib
from pathlib import Path

D = None  # the driver module (install)

# ---- the code ----------------------------------------------------------------------------------------------------------
SAFE_COLORS = {"K": (0, 0, 0), "W": (255, 255, 255), "R": (255, 0, 0), "B": (0, 0, 255), "Y": (255, 255, 0),
               "M": (255, 0, 255)}
ORDER = "KWRBYM"            # the digit order of the colors that differ from the cell before
START = [SAFE_COLORS[c] for c in "MYBM"]
DATA_DIGITS = 21            # 5 ** 21 > 2 ** 48
END_DIGITS = [0, 1, 0, 2]
MARKER_CELLS = len(START) + DATA_DIGITS + len(END_DIGITS) + 1
TOKEN = re.compile(r"[!-~]{1,64}")
CLASS_ON, CLASS_OFF = 160, 96
MIN_CELL_PX = 4             # a cell narrower than this is no terminal cell
MIN_ROWS = 6                # a marker is a whole terminal line: at least this many pixel rows tall


def crc24(data):
    """CRC-24 (OpenPGP, RFC 4880)."""
    crc = 0xB704CE
    for byte in data:
        crc ^= byte << 16
        for _ in range(8):
            crc <<= 1
            if crc & 0x1000000:
                crc ^= 0x1864CFB
    return crc & 0xFFFFFF


def token_digest(token):
    """The 24-bit digest a token's marker carries, as six hex digits."""
    return hashlib.sha256(token.encode("ascii")).hexdigest()[:6]


def token_value(token):
    digest = int(token_digest(token), 16)
    return digest << 24 | crc24(digest.to_bytes(3, "big"))


def encode_digits(value):
    digits = []
    for _ in range(DATA_DIGITS):
        value, digit = divmod(value, 5)
        digits.append(digit)
    if value:
        raise ValueError("the value does not fit the marker")
    return digits[::-1]


def decode_digits(digits):
    value = 0
    for digit in digits:
        value = value * 5 + digit
    return value


def _next_letter(prev, digit):
    return [c for c in ORDER if c != prev][digit]


def marker_letters(token):
    letters = list("MYBM")
    for digit in encode_digits(token_value(token)) + END_DIGITS:
        letters.append(_next_letter(letters[-1], digit))
    letters.append(next(c for c in "RBYM" if c != letters[-1]))
    return letters


def marker_cells(token):
    """The RGB color of each cell of TOKEN's marker, left to right."""
    return [SAFE_COLORS[c] for c in marker_letters(token)]


# ---- reading a frame -------------------------------------------------------------------------------------------------
def read_png(path):
    """(width, height, rows) of an 8-bit RGB or RGBA PNG, no interlace (the app's window snapshots); rows[y] is width
    x 4 bytes RGBA. Standard library only. Anything else, a cut or damaged file included, raises ValueError (the
    driver's checks catch it: the check fails with the reason, the journey and the driver run go on)."""
    name = Path(path).name
    data = Path(path).read_bytes()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError(f"{name}: not a PNG")
    pos, idat, head = 8, [], None
    while True:
        if pos + 12 > len(data):
            raise ValueError(f"{name}: the file ends inside a chunk at byte {pos} (a cut file: no IEND)")
        size = struct.unpack(">I", data[pos:pos + 4])[0]
        kind = data[pos + 4:pos + 8]
        if pos + 12 + size > len(data):
            raise ValueError(f"{name}: chunk {kind!r} at byte {pos} says {size} bytes; the file ends before them")
        body = data[pos + 8:pos + 8 + size]
        if kind == b"IHDR":
            if size != 13:
                raise ValueError(f"{name}: IHDR of {size} bytes (13 expected)")
            head = struct.unpack(">IIBBBBB", body)
        elif kind == b"IDAT":
            idat.append(body)
        elif kind == b"IEND":
            break
        pos += 12 + size
    if head is None:
        raise ValueError(f"{name}: no IHDR")
    if not idat:
        raise ValueError(f"{name}: no IDAT")
    width, height, depth, color, _, _, interlace = head
    if depth != 8 or color not in (2, 6) or interlace:
        raise ValueError(f"{name}: unsupported PNG (bit depth {depth}, color type {color}, interlace {interlace})")
    bpp = 4 if color == 6 else 3
    stride = width * bpp
    try:
        raw = zlib.decompress(b"".join(idat))
    except zlib.error as error:
        raise ValueError(f"{name}: the pixel data does not decompress: {error}") from error
    if len(raw) != height * (stride + 1):
        raise ValueError(f"{Path(path).name}: {len(raw)} bytes of pixel data for {width}x{height}")
    rows, prev, at = [], bytearray(stride), 0
    lanes_low, lanes_high = int.from_bytes(b"\x7f" * stride, "big"), int.from_bytes(b"\x80" * stride, "big")
    for _ in range(height):
        kind, line = raw[at], bytearray(raw[at + 1:at + 1 + stride])
        at += 1 + stride
        if kind == 1:
            # Sub: a running sum per channel, mod 256 (accumulate runs in C; the mask keeps each byte).
            for c in range(bpp):
                line[c::bpp] = bytes(v & 255 for v in itertools.accumulate(line[c::bpp]))
        elif kind == 2:
            # Up: a byte-wise add of the row above with no carry between bytes (SWAR on one integer).
            a, b = int.from_bytes(line, "big"), int.from_bytes(prev, "big")
            line = bytearray((((a & lanes_low) + (b & lanes_low)) ^ ((a ^ b) & lanes_high)).to_bytes(stride, "big"))
        elif kind == 3:
            for x in range(stride):
                line[x] = (line[x] + (((line[x - bpp] if x >= bpp else 0) + prev[x]) >> 1)) & 255
        elif kind == 4:
            for x in range(stride):
                a = line[x - bpp] if x >= bpp else 0
                b, c = prev[x], (prev[x - bpp] if x >= bpp else 0)
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                line[x] = (line[x] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        elif kind != 0:
            raise ValueError(f"{Path(path).name}: row filter {kind}")
        prev = line
        rows.append(bytes(line) if bpp == 4 else b"".join(bytes(line[i:i + 3]) + b"\xff" for i in range(0, stride, 3)))
    return width, height, rows


def _channel(bit):
    return bytes(bit if v >= CLASS_ON else 0 if v <= CLASS_OFF else 64 for v in range(256))


_R, _G, _B = _channel(4), _channel(2), _channel(1)
# A pixel's class letter: K B G C R M Y W by its (r, g, b) bits; "." for a channel that is neither on nor off. G and C
# are classes no marker draws.
_LETTER = bytes(ord(".") if v & 64 else ord("KBGCRMYW"[v & 7]) for v in range(256))
# The first M run must be whole (no M pixel before it): a search that starts inside a longer run would see part of it.
_START = re.compile(rb"(?<!M)(M+)(Y+)(B+)(M+)")
_RUN = re.compile(rb"(.)\1*")


def row_letters(row):
    """One class letter per pixel of an RGBA row."""
    count = len(row) // 4
    bits = (int.from_bytes(row[0::4].translate(_R), "big") | int.from_bytes(row[1::4].translate(_G), "big")
            | int.from_bytes(row[2::4].translate(_B), "big"))
    return bits.to_bytes(count, "big").translate(_LETTER)


def _decode_from(letters, start):
    """(x, cell width, digest or None, why) of a marker whose START matched at START (a regex match), or None when
    those four runs are not one marker start (unequal widths, too narrow)."""
    widths = [len(g) for g in start.groups()]
    cell = widths[0]
    if cell < MIN_CELL_PX or any(w != cell for w in widths):
        return None
    pos, prev, digits = start.end(), "M", []
    for index in range(DATA_DIGITS + len(END_DIGITS)):
        run = _RUN.match(letters, pos)
        if run is None:
            return start.start(), cell, None, f"the line ends after cell {len(START) + index}"
        letter, width = chr(run.group(1)[0]), run.end() - run.start()
        if letter not in SAFE_COLORS or width != cell:
            return start.start(), cell, None, (f"cell {len(START) + index}: {width} px of class {letter!r} "
                                               f"(a cell is {cell} px of one marker color)")
        digits.append([c for c in ORDER if c != prev].index(letter))
        prev, pos = letter, run.end()
    if digits[DATA_DIGITS:] != END_DIGITS:
        return start.start(), cell, None, "no END after the data"
    value = decode_digits(digits[:DATA_DIGITS])
    if value >> 48:
        return start.start(), cell, None, "the data is no marker value"
    digest, check = value >> 24, value & 0xFFFFFF
    if crc24(digest.to_bytes(3, "big")) != check:
        return start.start(), cell, None, "the check digits do not hold"
    return start.start(), cell, "%06x" % digest, ""


def scan_markers(width, height, rows):
    """Every marker in a frame: [{"x", "y", "height", "cell", "digest" (or None), "ok", "why"}], top to bottom. A
    marker is the run of consecutive pixel rows where one START (the same x and cell width) is found; it reads OK only
    when every one of those rows decodes to the same digest, and it is at least MIN_ROWS rows tall (shorter runs are
    no terminal line and are not reported)."""
    open_groups, done = {}, []
    for y in range(height):
        letters = row_letters(rows[y])
        seen = set()
        pos = 0
        while True:
            start = _START.search(letters, pos)
            if start is None:
                break
            got = _decode_from(letters, start)
            if got is None:  # not a start: the next one can begin at its last M run at the earliest
                pos = start.start(4)
                continue
            x, cell, digest, why = got
            # The data of a marker that decoded can hold the four START colors: they are its own cells, not a
            # second marker, so the search goes on after its END.
            pos = x + (MARKER_CELLS - 1) * cell if digest else start.end()
            key = (x, cell)
            seen.add(key)
            group = open_groups.get(key)
            if group is None:
                open_groups[key] = {"x": x, "y": y, "height": 1, "cell": cell, "digests": {digest}, "why": {why} - {""}}
            else:
                group["height"] += 1
                group["digests"].add(digest)
                if why:
                    group["why"].add(why)
        for key in [k for k in open_groups if k not in seen]:
            done.append(open_groups.pop(key))
    done += open_groups.values()
    out = []
    for g in sorted(done, key=lambda g: (g["y"], g["x"])):
        if g["height"] < MIN_ROWS:
            continue
        digests = g["digests"]
        ok = len(digests) == 1 and None not in digests
        why = "" if ok else "; ".join(sorted(g["why"])) or "its rows decode to different markers"
        out.append({"x": g["x"], "y": g["y"], "height": g["height"], "cell": g["cell"],
                    "digest": next(iter(digests)) if ok else None, "ok": ok, "why": why})
    return out


# ---- driver steps and conditions -------------------------------------------------------------------------------------
def install(driver):
    global D
    D = driver


def step_marker_install(j, step):
    # Made with O_CREAT|O_EXCL: a name another account made first (a link, a FIFO, its own program) fails the step
    # instead of being written through or run. The random part keeps a planted name from failing every run.
    path = f"/tmp/jr-m-{j.nonce}-{os.urandom(4).hex()}"
    data = Path(__file__).read_bytes()
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o700)
    with os.fdopen(fd, "wb") as out:
        out.write(data)
    os.chmod(path, 0o755)
    j.files.append(path)
    j.vars["marker"] = path
    return {"path": path, "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()[:16]}


def _snapshot_markers(j):
    j.checks += 1
    image = j.app.snapshot(j.out / f"check-{j.checks:02d}.png")
    width, height, rows = read_png(image)
    return image.name, scan_markers(width, height, rows)


def _brief(markers):
    return [{k: m[k] for k in ("x", "y", "height", "cell", "digest", "ok", "why")} for m in markers[:20]]


def cond_frame_marker(j, want, cache):
    token = want.get("token") if isinstance(want, dict) else want
    if not isinstance(token, str) or not TOKEN.fullmatch(token):
        return False, {"error": f"frame_marker needs a token of 1-64 printable characters, not {token!r}"}
    image, markers = _snapshot_markers(j)
    digest = token_digest(token)
    return any(m["ok"] and m["digest"] == digest for m in markers), {"image": image, "want": digest,
                                                                       "markers": _brief(markers)}


def cond_frame_marker_lacks(j, want, cache):
    token, proof = (want.get("token"), want.get("with")) if isinstance(want, dict) else (None, None)
    if not (isinstance(token, str) and TOKEN.fullmatch(token) and isinstance(proof, str) and TOKEN.fullmatch(proof)):
        return False, {"error": "frame_marker_lacks needs {\"token\": T, \"with\": W}: T must be absent from a frame "
                                "that shows W"}
    image, markers = _snapshot_markers(j)
    bad, shows = token_digest(token), token_digest(proof)
    unreadable = [m for m in markers if not m["ok"]]
    present = any(m["ok"] and m["digest"] == bad for m in markers)
    proven = any(m["ok"] and m["digest"] == shows for m in markers)
    # seen: T's marker on a frame that also shows W, so the frame is this step's: the driver stops trying the check (a
    # frame without W is from before the step's output, and is tried again).
    detail = {"image": image, "lacks": bad, "with": shows, "markers": _brief(markers), "seen": present and proven}
    if not proven:
        detail["why"] = "the frame does not show the marker that proves it is this run's frame"
    elif unreadable:
        detail["why"] = "an unreadable marker is on the frame: it cannot prove the absence"
    return proven and not present and not unreadable, detail


STEPS = {"marker_install": step_marker_install}
CONDITIONS = {"frame_marker": ("frame", cond_frame_marker), "frame_marker_lacks": ("frame", cond_frame_marker_lacks)}
NEGATIVE = {"frame_marker_lacks"}


# ---- the marker program ----------------------------------------------------------------------------------------------
def main(argv):
    if len(argv) != 2 or not TOKEN.fullmatch(argv[1]):
        sys.stderr.write("usage: jr-mark TOKEN (1-64 printable ASCII characters, no spaces)\n")
        return 2
    token = argv[1]
    # The terminal's own width (an exported COLUMNS need not be the pane's): a marker is drawn by a terminal only.
    try:
        columns = os.get_terminal_size(sys.stdout.fileno()).columns
    except OSError:
        print("jr-mark: the output is not a terminal; a marker is drawn by the terminal that shows it")
        return 4
    if columns < MARKER_CELLS:
        print(f"jr-mark: the pane has {columns} columns; a marker needs {MARKER_CELLS}")
        return 3
    cells = "".join("\x1b[48;2;%d;%d;%dm " % color for color in marker_cells(token))
    # A blank line before and after the cells: no glyph of a text line above or below can reach a marker pixel row.
    sys.stdout.write(token + "\n\n" + cells + "\x1b[0m\n\n")
    sys.stdout.flush()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
