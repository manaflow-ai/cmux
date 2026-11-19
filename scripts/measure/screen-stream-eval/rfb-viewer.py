#!/usr/bin/env python3
"""A headless RFB viewer for the apple-rfb target: measures Apple's Screen Sharing server
(screensharingd) from a shell, with no window on any Mac.

  rfb-viewer.py probe   --host H [--encodings E,...]
  rfb-viewer.py latency --host H --input key|pointer --samples N --marker-log LOG --out RAW
  rfb-viewer.py window  --host H --seconds S --frame PNG --go GO --out RAW [--nonce HEX32]

It logs in as the host's macOS account (RFB security type 30, the login Screen Sharing.app uses),
keeps one incremental update request outstanding (the RFB pull model every viewer uses), and
decodes only the rectangles over the marker rows. Everything else is inflated and counted, not
drawn, so a slow pure-Python decoder never throttles the stream it measures. The last frame of a
window run is a full, decoded framebuffer for OCR.

What it measures and what it does not: this is screensharingd serving a standard RFB client
(ZRLE, zlib, raw). Screen Sharing.app negotiates Apple's own encodings, which no public client
decodes, so these rows are Apple's server with standard encodings, not the app's picture.
Glass-to-glass ends at this client's decode of the marker, like rd's `bench`, not at a display.

The login comes from a file (--login-file, default ~/.config/screen-stream-eval/login in the
account's real home, mode 0600) or, with no default file, from the login Screen Sharing.app saved in
this account's keychain for the host. It never goes through argv or the environment and is never
logged. One line of the file is the password of an account with this account's name on the host
(the fleet Macs share one); two lines are a user name, then its password.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import pwd
import random
import re
import socket
import stat
import struct
import subprocess
import sys
import time
import zlib

ENCODINGS = {"raw": 0, "copyrect": 1, "zlib": 6, "zrle": 16}
PSEUDO_DESKTOP_SIZE = -223
GUARD = (True, False, True, False)
MESSAGE_S = 15  # the most one server message may take to arrive once it has started


class RFBError(RuntimeError):
    pass


# --- Apple account login (security type 30) -------------------------------------------------
# Diffie-Hellman, then the MD5 of the shared secret keys AES-128-ECB over two 64-byte fields.
# AES is written out here (encrypt only, one 128-byte message per login) so Apple's python3
# needs no package. From manaflow-ai/cua-vnc (MIT).

def _aes_tables():
    sbox = [0] * 256
    p = q = 1
    while True:
        p = p ^ ((p << 1) & 0xFF) ^ (0x1B if p & 0x80 else 0)
        q ^= q << 1
        q ^= q << 2
        q ^= q << 4
        q &= 0xFF
        if q & 0x80:
            q ^= 0x09
        x = q ^ ((q << 1) | (q >> 7)) ^ ((q << 2) | (q >> 6)) ^ ((q << 3) | (q >> 5)) ^ ((q << 4) | (q >> 4))
        sbox[p] = (x ^ 0x63) & 0xFF
        if p == 1:
            break
    sbox[0] = 0x63
    xtime = [((i << 1) ^ (0x1B if i & 0x80 else 0)) & 0xFF for i in range(256)]
    return sbox, xtime


_SBOX, _XTIME = _aes_tables()


def aes128_ecb_encrypt(key: bytes, data: bytes) -> bytes:
    if len(key) != 16 or len(data) % 16:
        raise ValueError("AES-128-ECB needs a 16-byte key and whole blocks")
    words = [list(key[i:i + 4]) for i in range(0, 16, 4)]
    rcon = 1
    for i in range(4, 44):
        t = list(words[i - 1])
        if i % 4 == 0:
            t = [_SBOX[b] for b in t[1:] + t[:1]]
            t[0] ^= rcon
            rcon = _XTIME[rcon]
        words.append([a ^ b for a, b in zip(words[i - 4], t)])
    round_keys = [sum(words[r * 4:r * 4 + 4], []) for r in range(11)]
    out = bytearray()
    for off in range(0, len(data), 16):
        s = [b ^ k for b, k in zip(data[off:off + 16], round_keys[0])]
        for rnd in range(1, 11):
            s = [_SBOX[b] for b in s]
            s = [s[(i + 4 * (i % 4)) % 16] for i in range(16)]
            if rnd != 10:
                mixed = []
                for c in range(4):
                    a0, a1, a2, a3 = s[4 * c:4 * c + 4]
                    t = a0 ^ a1 ^ a2 ^ a3
                    mixed += [a0 ^ t ^ _XTIME[a0 ^ a1], a1 ^ t ^ _XTIME[a1 ^ a2],
                              a2 ^ t ^ _XTIME[a2 ^ a3], a3 ^ t ^ _XTIME[a3 ^ a0]]
                s = mixed
            s = [b ^ k for b, k in zip(s, round_keys[rnd])]
        out.extend(s)
    return bytes(out)


def _field(value: str, size: int) -> bytes:
    raw = value.encode("utf8")
    if len(raw) >= size:
        raise RFBError(f"Apple login fields must be shorter than {size} bytes")
    return raw + b"\0" + os.urandom(size - len(raw) - 1)


def apple_dh_response(username: str, password: str, generator: int, prime: bytes, server_public: bytes) -> bytes:
    key_len = len(prime)
    p = int.from_bytes(prime, "big")
    private = int.from_bytes(os.urandom(key_len), "big") % (p - 2) + 1
    public = pow(generator, private, p).to_bytes(key_len, "big")
    shared = pow(int.from_bytes(server_public, "big"), private, p).to_bytes(key_len, "big")
    creds = _field(username, 64) + _field(password, 64)
    return aes128_ecb_encrypt(hashlib.md5(shared).digest(), creds) + public


def keychain_login(host: str, run=subprocess.run) -> tuple[str, str] | None:
    """The login Screen Sharing.app saved for this host (an `rfb ` internet password), or None.

    The password comes back on a pipe only. The first read may show macOS's keychain prompt once
    ("Always Allow" keeps it quiet), so it gets time for a person to answer."""
    query = ["security", "find-internet-password", "-r", "rfb ", "-s", host]
    try:
        attrs = run(query, capture_output=True, text=True, timeout=10)
        if attrs.returncode != 0:
            return None
        account = re.search(r'"acct"<blob>="([^"]*)"', attrs.stdout)
        secret = run(query + ["-w"], capture_output=True, text=True, timeout=120)
    except (OSError, subprocess.SubprocessError):
        return None
    password = secret.stdout.rstrip("\n") if secret.returncode == 0 else ""
    if not account or not account.group(1) or not password:
        return None
    return account.group(1), password


def read_login(path: str | None, host: str | None = None, run=subprocess.run) -> tuple[str, str]:
    account = pwd.getpwuid(os.getuid())
    explicit = bool(path)
    if not path:
        # A step's $HOME is scratch; the file lives in the account's real home.
        path = os.path.join(account.pw_dir, ".config/screen-stream-eval/login")
    try:
        info = os.stat(path)
    except OSError:
        # No file: the login Screen Sharing.app saved in this account's keychain.
        saved = None if explicit or not host else keychain_login(host, run)
        if saved:
            return saved
        raise RFBError(f"no login file at {path} and no Screen Sharing login saved in the keychain for "
                       f"{host or 'the host'}; next: connect once with Screen Sharing.app and tick "
                       f"\"Remember this password\", or put the host account's password in that file (mode 0600)") from None
    if stat.S_IMODE(info.st_mode) & 0o077:
        raise RFBError(f"{path} is readable by others; next: chmod 600 it")
    lines = [line for line in open(path, encoding="utf8").read().splitlines() if line]
    if len(lines) == 1:
        return account.pw_name, lines[0]
    if len(lines) == 2:
        return lines[0], lines[1]
    raise RFBError(f"{path} holds a password, or a user name and then a password, one a line")


# --- The client ------------------------------------------------------------------------------

class Client:
    def __init__(self, host: str, port: int, login: tuple[str, str], encodings: list[str], timeout: float = 10):
        self.sock = socket.create_connection((host, port), timeout)
        self.sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        self.buf = bytearray()
        self.bytes_in = 0
        self.login = login
        self.encodings = encodings
        self.zrle = zlib.decompressobj()
        self.zlib = zlib.decompressobj()
        self.width = self.height = 0
        self.fb = bytearray()
        self.watch: tuple[int, int, int, int] | None = None  # x, y, w, h decoded on every update
        self.decode_all = False
        self.seen: dict[str, int] = {}
        self.security_type = None

    # Reads go through one buffer so a deadline can bound them.
    def _fill(self, deadline: float | None) -> None:
        if deadline is not None:
            left = deadline - time.monotonic()
            if left <= 0:
                raise socket.timeout("deadline")
            self.sock.settimeout(left)
        chunk = self.sock.recv(1 << 20)
        if not chunk:
            raise RFBError("the server closed the connection")
        self.bytes_in += len(chunk)
        self.buf += chunk

    def recv(self, n: int, deadline: float | None = None) -> bytes:
        while len(self.buf) < n:
            self._fill(deadline)
        out = bytes(self.buf[:n])
        del self.buf[:n]
        return out

    def has_data(self) -> bool:
        return bool(self.buf)

    def send(self, data: bytes) -> None:
        self.sock.sendall(data)

    def close(self) -> None:
        try:
            self.sock.close()
        except OSError:
            pass

    def handshake(self) -> None:
        banner = self.recv(12)
        if not re.match(rb"RFB \d{3}\.\d{3}\n", banner):
            raise RFBError(f"not an RFB server: {banner!r}")
        self.send(b"RFB 003.008\n")
        n = self.recv(1)[0]
        if n == 0:
            raise RFBError("server refused the connection: " + self._reason())
        types = list(self.recv(n))
        if 30 not in types:
            raise RFBError(f"server offers security types {types}, not 30 (Apple account login)")
        self.security_type = 30
        self.send(b"\x1e")
        generator, key_len = struct.unpack("!HH", self.recv(4))
        prime = self.recv(key_len)
        server_public = self.recv(key_len)
        self.send(apple_dh_response(self.login[0], self.login[1], generator, prime, server_public))
        if struct.unpack("!I", self.recv(4))[0] != 0:
            raise RFBError("login rejected: " + (self._reason() or "wrong user name or password"))
        self.send(b"\x01")  # shared: never disconnect another viewer
        header = self.recv(24)
        self.width, self.height = struct.unpack("!HH", header[:4])
        self.recv(struct.unpack("!I", header[20:24])[0])
        self.fb = bytearray(self.width * self.height * 3)
        # 32 bpp, depth 24, little-endian, 0x00RRGGBB: ZRLE CPIXELs arrive as B, G, R.
        self.send(b"\x00\x00\x00\x00" + struct.pack("!BBBBHHHBBBxxx", 32, 24, 0, 1, 255, 255, 255, 16, 8, 0))
        codes = [ENCODINGS[e] for e in self.encodings] + [PSEUDO_DESKTOP_SIZE]
        self.send(struct.pack("!BBH", 2, 0, len(codes)) + b"".join(struct.pack("!i", c) for c in codes))

    def _reason(self) -> str:
        try:
            return self.recv(struct.unpack("!I", self.recv(4))[0]).decode("utf8", "replace")
        except (OSError, RFBError):
            return ""

    def request(self, incremental: bool = True) -> None:
        self.send(struct.pack("!BBHHHH", 3, 1 if incremental else 0, 0, 0, self.width, self.height))

    def key(self, keysym: int) -> None:
        self.send(struct.pack("!BBxxI", 4, 1, keysym) + struct.pack("!BBxxI", 4, 0, keysym))

    def click(self, x: int, y: int) -> None:
        self.send(struct.pack("!BBHH", 5, 1, x, y) + struct.pack("!BBHH", 5, 0, x, y))

    def read_message(self, deadline: float | None) -> dict | None:
        """One server message. A framebuffer update returns {"rects", "decode_ms"}; others None.
        The deadline bounds only the wait for a message to start: once its first byte is read the
        rest is read whole (bounded by MESSAGE_S), since a message cut short would desync the stream."""
        kind = self.recv(1, deadline)[0]
        deadline = time.monotonic() + MESSAGE_S
        if kind == 0:
            self.recv(1, deadline)
            count = struct.unpack("!H", self.recv(2, deadline))[0]
            decode_s = 0.0
            rects = 0
            for _ in range(count):
                x, y, w, h, enc = struct.unpack("!HHHHi", self.recv(12, deadline))
                if enc == PSEUDO_DESKTOP_SIZE:
                    self.width, self.height = w, h
                    self.fb = bytearray(w * h * 3)
                    continue
                rects += 1
                decode_s += self._rect(x, y, w, h, enc, deadline)
            return {"rects": rects, "decode_ms": decode_s * 1000}
        if kind == 1:
            self.recv(3, deadline)
            self.recv(struct.unpack("!H", self.recv(2, deadline))[0] * 6, deadline)
        elif kind == 2:
            pass
        elif kind == 3:
            self.recv(3, deadline)
            self.recv(struct.unpack("!I", self.recv(4, deadline))[0], deadline)
        else:
            raise RFBError(f"unexpected server message {kind} (the server sent an encoding this client did not ask for?)")
        return None

    def _wanted(self, x: int, y: int, w: int, h: int) -> bool:
        if self.decode_all:
            return True
        if self.watch is None:
            return False
        wx, wy, ww, wh = self.watch
        return x < wx + ww and wx < x + w and y < wy + wh and wy < y + h

    def _rect(self, x: int, y: int, w: int, h: int, enc: int, deadline: float | None) -> float:
        name = {v: k for k, v in ENCODINGS.items()}.get(enc)
        if name is None:
            raise RFBError(f"server sent encoding {enc}, which this client did not offer")
        self.seen[name] = self.seen.get(name, 0) + 1
        if enc == 1:
            sx, sy = struct.unpack("!HH", self.recv(4, deadline))
            start = time.perf_counter()
            self._copy(sx, sy, x, y, w, h)
            return time.perf_counter() - start
        if enc == 0:
            data = self.recv(w * h * 4, deadline)
            start = time.perf_counter()
            if self._wanted(x, y, w, h):
                self._blit(x, y, w, h, _bgrx_to_rgb(data))
            return time.perf_counter() - start
        length = struct.unpack("!I", self.recv(4, deadline))[0]
        data = self.recv(length, deadline)
        start = time.perf_counter()
        # Each stream is one zlib context for the whole session: always inflate, decode only when drawn.
        if enc == 6:
            raw = self.zlib.decompress(data)
            if self._wanted(x, y, w, h):
                self._blit(x, y, w, h, _bgrx_to_rgb(raw[:w * h * 4]))
        else:
            raw = self.zrle.decompress(data)
            if self._wanted(x, y, w, h):
                _decode_zrle(raw, x, y, w, h, self._blit)
        return time.perf_counter() - start

    def _blit(self, x: int, y: int, w: int, h: int, rgb: bytes) -> None:
        w = min(w, self.width - x)
        if w <= 0:
            return
        stride, row = self.width * 3, w * 3
        src = len(rgb) // h if h else 0
        for r in range(min(h, self.height - y)):
            dst = (y + r) * stride + x * 3
            self.fb[dst:dst + row] = rgb[r * src:r * src + row]

    def _copy(self, sx: int, sy: int, x: int, y: int, w: int, h: int) -> None:
        stride = self.width * 3
        rows = [bytes(self.fb[(sy + r) * stride + sx * 3:(sy + r) * stride + (sx + w) * 3]) for r in range(h)]
        self._blit(x, y, w, h, b"".join(rows))

    def pixel(self, x: int, y: int) -> int:
        """Luma 0..255 of one pixel."""
        i = (y * self.width + x) * 3
        r, g, b = self.fb[i], self.fb[i + 1], self.fb[i + 2]
        return (r * 299 + g * 587 + b * 114) // 1000


def _bgrx_to_rgb(raw: bytes) -> bytes:
    out = bytearray(len(raw) // 4 * 3)
    out[0::3], out[1::3], out[2::3] = raw[2::4], raw[1::4], raw[0::4]
    return bytes(out)


def _bgr(raw: bytes) -> bytes:
    out = bytearray(len(raw))
    out[0::3], out[1::3], out[2::3] = raw[2::3], raw[1::3], raw[0::3]
    return bytes(out)


def _decode_zrle(data: bytes, x: int, y: int, w: int, h: int, blit) -> None:
    pos = 0
    for ty in range(y, y + h, 64):
        th = min(64, y + h - ty)
        for tx in range(x, x + w, 64):
            tw = min(64, x + w - tx)
            n = tw * th
            sub = data[pos]
            pos += 1
            if sub == 0:
                tile = _bgr(data[pos:pos + n * 3])
                pos += n * 3
            elif sub == 1:
                tile = _bgr(data[pos:pos + 3]) * n
                pos += 3
            elif 2 <= sub <= 16:
                palette = [_bgr(data[pos + 3 * i:pos + 3 * i + 3]) for i in range(sub)]
                pos += 3 * sub
                bits = 1 if sub == 2 else 2 if sub <= 4 else 4
                per = 8 // bits
                row_len = (tw + per - 1) // per
                mask = (1 << bits) - 1
                rows = []
                for _ in range(th):
                    idx = []
                    for b in data[pos:pos + row_len]:
                        for shift in range(8 - bits, -1, -bits):
                            idx.append((b >> shift) & mask)
                    pos += row_len
                    rows.append(b"".join(palette[i] for i in idx[:tw]))
                tile = b"".join(rows)
            elif sub == 128 or sub >= 130:
                palette = []
                if sub >= 130:
                    palette = [_bgr(data[pos + 3 * i:pos + 3 * i + 3]) for i in range(sub - 128)]
                    pos += 3 * (sub - 128)
                parts, filled = [], 0
                while filled < n:
                    if sub == 128:
                        px = _bgr(data[pos:pos + 3])
                        pos += 3
                        run, has_run = 1, True
                    else:
                        index = data[pos]
                        pos += 1
                        px, run, has_run = palette[index & 0x7F], 1, bool(index & 0x80)
                    if has_run:
                        while True:
                            b = data[pos]
                            pos += 1
                            run += b
                            if b != 255:
                                break
                    parts.append(px * run)
                    filled += run
                tile = b"".join(parts)
            else:
                raise RFBError(f"invalid ZRLE subencoding {sub}")
            blit(tx, ty, tw, th, tile)


def write_png(path: str, width: int, height: int, rgb: bytes) -> None:
    def chunk(tag: bytes, body: bytes) -> bytes:
        return struct.pack("!I", len(body)) + tag + body + struct.pack("!I", zlib.crc32(tag + body) & 0xFFFFFFFF)
    stride = width * 3
    raw = b"".join(b"\0" + rgb[r * stride:(r + 1) * stride] for r in range(height))
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack("!IIBBBBB", width, height, 8, 2, 0, 0, 0))
                + chunk(b"IDAT", zlib.compress(raw, 6)) + chunk(b"IEND", b""))


# --- Markers ---------------------------------------------------------------------------------
# Both markers are rows of 20 square cells at the display's left edge: 16 bits of a word, least
# significant first, then the guard 1,0,1,0 (cmux-rd-host's mac-marker for latency; scene.swift's
# counter row plus eight nonce rows for the window runs).

def read_row(c: Client, ox: int, oy: int, cell: float, strict: bool = False) -> int | None:
    """One marker row's 16-bit word, or None when the guard is not there. `strict` (for finding
    the marker) also asks each cell to read the same at four inner points, so a half-size or
    shifted reading of a real marker, or text that happens to match the guard, does not pass."""
    bits = []
    inner = ((0.25, 0.25), (0.75, 0.25), (0.25, 0.75), (0.75, 0.75)) if strict else ()
    for i in range(20):
        x, y = int(ox + (i + 0.5) * cell), int(oy + 0.5 * cell)
        if int(ox + 20 * cell) > c.width or int(oy + cell) > c.height:
            return None
        bit = c.pixel(x, y) >= 128
        for fx, fy in inner:
            if (c.pixel(int(ox + (i + fx) * cell), int(oy + fy * cell)) >= 128) != bit:
                return None
        bits.append(bit)
    if tuple(bits[16:]) != GUARD:
        return None
    return sum(1 << i for i in range(16) if bits[i])


def locate(c: Client, rows: int, max_y: int) -> tuple[int, float] | None:
    """The marker's top (y) and cell size in framebuffer pixels: the first place `rows` guarded rows
    stack. Needs the top of the framebuffer decoded."""
    # Largest cell first: a real marker read at half its cell size can still look guarded.
    for cell in range(129, 7, -1):
        for y in range(0, min(max_y, c.height - rows * cell)):
            if all(read_row(c, 0, y + r * cell, cell, strict=True) is not None for r in range(rows)):
                # The cell edges too: the guard's white cell ends where the black one starts.
                if c.pixel(int(16 * cell + cell - 2), y + cell // 2) >= 128 and c.pixel(int(17 * cell + 1), y + cell // 2) < 128:
                    # The first matching y is up to a quarter cell above the row: move to the top
                    # edge of the black guard cell, where the pixel above it is not black.
                    gx = int(17.5 * cell)
                    for top in range(y, y + cell):
                        if c.pixel(gx, top) < 128 and (top == 0 or c.pixel(gx, top - 1) >= 128):
                            return top, float(cell)
                    return y, float(cell)
    return None


def nonce_words(nonce: str) -> list[int]:
    raw = bytes.fromhex(nonce)
    return [raw[i] | (raw[i + 1] << 8) for i in range(0, 16, 2)]


# --- Verbs -----------------------------------------------------------------------------------

def connect(args) -> Client:
    c = Client(args.host, args.port, read_login(args.login_file, args.host), args.encodings.split(","))
    c.handshake()
    return c


def full_frame(c: Client, deadline: float) -> None:
    """Decode one complete framebuffer (non-incremental request)."""
    c.decode_all = True
    c.request(incremental=False)
    while c.read_message(deadline) is None:
        pass
    c.decode_all = False


def cmd_probe(args) -> int:
    start = time.monotonic()
    c = connect(args)
    login_ms = (time.monotonic() - start) * 1000
    full_frame(c, time.monotonic() + args.timeout)
    out = {"security_type": c.security_type, "width": c.width, "height": c.height,
           "login_ms": round(login_ms, 1), "first_full_frame_ms": round((time.monotonic() - start) * 1000, 1),
           "encodings_seen": c.seen, "bytes_in": c.bytes_in}
    if args.frame:
        write_png(args.frame, c.width, c.height, bytes(c.fb))
    c.close()
    print(json.dumps(out))
    return 0


def marker_geometry(c: Client, log_path: str | None) -> tuple[int, float, tuple[int, int]]:
    """mac-marker's place in framebuffer pixels: its log is in stream pixels (the display fitted to
    3840x2160), so scale by this framebuffer's width; else find it."""
    text = open(log_path).read() if log_path and os.path.exists(log_path) else ""
    m = re.search(r"marker-origin (\d+),(\d+) click-at (\d+),(\d+)", text)
    w = re.search(r"stream width (\d+(?:\.\d+)?) px", text)
    if m and w:
        s = c.width / float(w.group(1))
        return int(int(m.group(2)) * s), 32 * s, (int(int(m.group(3)) * s), int(int(m.group(4)) * s))
    found = locate(c, 1, c.height // 4)
    if not found:
        raise RFBError("no marker in the framebuffer")
    y, cell = found
    return y, cell, (int(22 * cell), int(y + cell / 2))


def cmd_latency(args) -> int:
    c = connect(args)
    full_frame(c, time.monotonic() + args.timeout)
    y, cell, at = marker_geometry(c, args.marker_log)
    c.watch = (0, y, int(20 * cell) + 1, int(cell) + 1)
    counter = read_row(c, 0, y, cell)
    if counter is None:
        raise RFBError(f"marker not readable at y={y} cell={cell:.1f}")
    rng = random.Random(args.seed)
    samples, lost = [], 0
    c.request()
    pending = True
    for _ in range(args.samples):
        time.sleep(rng.uniform(0.08, 0.2))  # spread inputs off any frame cadence
        # Drain what arrived meanwhile, so the input starts from the current counter.
        while True:
            try:
                if c.read_message(time.monotonic() + 0.001) is not None:
                    pending = False
            except socket.timeout:
                break
            if not pending:
                c.request()
                pending = True
        counter = read_row(c, 0, y, cell)
        sent = time.monotonic()
        c.click(*at) if args.input == "pointer" else c.key(0x61)
        deadline = sent + args.timeout_ms / 1000
        hit = None
        while hit is None:
            try:
                update = c.read_message(deadline)
            except socket.timeout:
                break
            if update is None:
                continue
            c.request()
            now = read_row(c, 0, y, cell)
            if now is not None and now != counter:
                hit = (time.monotonic() - sent) * 1000
        if hit is None:
            lost += 1
        else:
            samples.append(hit)
    c.close()
    samples.sort()
    pct = lambda q: round(samples[min(len(samples) - 1, int(q * len(samples)))], 2) if samples else None
    json.dump({"g2g_ms": {"n": len(samples), "p50": pct(0.5), "p95": pct(0.95)}, "lost": lost,
               "split": {"input_to_capture_ms": None, "encode_ms": None, "transport_ms": None, "decode_ms": None,
                         "method": "rfb-viewer: RFB input to the first decoded update whose marker counter changed"},
               "geometry": {"marker_y": y, "cell": cell, "at": list(at), "framebuffer": [c.width, c.height]},
               "encodings_seen": c.seen}, open(args.out, "w"))
    return 0 if samples else 1


def cmd_window(args) -> int:
    start = time.monotonic()
    c = connect(args)
    full_frame(c, start + args.timeout)
    first_frame_ms = (time.monotonic() - start) * 1000
    rows = 9 if args.nonce else 1
    readiness = None
    found = locate(c, rows, c.height // 3)
    if args.nonce:
        # Only the fresh nonce from this repeat's scene, with its counter moving, may start GO.
        if not found:
            raise RFBError("no source marker in the framebuffer; next: check the host's scene is up")
        y, cell = found
        c.watch = (0, y, int(20 * cell) + 1, int(rows * cell) + 1)
        words = [read_row(c, 0, y + (r + 1) * cell, cell) for r in range(8)]
        if words != nonce_words(args.nonce):
            raise RFBError("the host shows another repeat's nonce; next: check the host and the address")
        before = read_row(c, 0, y, cell)
        c.request()
        until = time.monotonic() + 3
        after = before
        while after == before and time.monotonic() < until:
            try:
                if c.read_message(until) is not None:
                    c.request()
                    after = read_row(c, 0, y, cell)
            except socket.timeout:
                break
        if after == before:
            raise RFBError("the source counter did not advance; next: check the scene is drawing")
        readiness = {"nonce_observed": True, "marker_y": y, "cell": cell, "counter_before": before, "counter_after": after}
    elif found:
        c.watch = (0, found[0], int(20 * found[1]) + 1, int(found[1]) + 1)
        c.request()
    else:
        c.request()
    open(args.go, "a").close()
    series = []
    bucket_start, bucket_bytes0 = time.time(), c.bytes_in
    frames, decode = 0, []
    end = time.monotonic() + args.seconds
    while time.monotonic() < end:
        try:
            update = c.read_message(min(end, time.monotonic() + 0.05))
        except socket.timeout:
            update = None
        if update is not None:
            c.request()
            if update["rects"]:
                frames += 1
                decode.append(update["decode_ms"])
        now = time.time()
        if now - bucket_start >= 1:
            series.append({"unix_ms": int(now * 1000), "duration_ms": int((now - bucket_start) * 1000),
                           "bytes": c.bytes_in - bucket_bytes0, "frames": frames, "sampled_changes": None,
                           "decode_ms": round(sorted(decode)[len(decode) // 2], 3) if decode else None, "encode_ms": None})
            bucket_start, bucket_bytes0, frames, decode = now, c.bytes_in, 0, []
    # The OCR frame: one complete, fully decoded framebuffer at the end of the hold.
    try:
        while c.read_message(time.monotonic() + 0.2) is None:
            pass
    except socket.timeout:
        pass
    full_frame(c, time.monotonic() + args.timeout)
    write_png(args.frame, c.width, c.height, bytes(c.fb))
    c.close()
    json.dump({"series": series, "extra": {
        "first_frame_ms": round(first_frame_ms, 1), "cpu_pct": None, "viewer": "rfb-viewer (headless)",
        "bytes_method": "RFB bytes this client read from its socket (payload, no TCP/IP headers)",
        "frames_method": "framebuffer updates with at least one rectangle (RFB pull: one request outstanding)",
        "encodings_seen": c.seen, "framebuffer": [c.width, c.height], "readiness": readiness}}, open(args.out, "w"))
    return 0


def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = p.add_subparsers(dest="verb", required=True)
    for name in ("probe", "latency", "window"):
        s = sub.add_parser(name)
        s.add_argument("--host", required=True)
        s.add_argument("--port", type=int, default=5900)
        s.add_argument("--login-file")
        s.add_argument("--encodings", default="zrle,zlib,copyrect,raw")
        s.add_argument("--timeout", type=float, default=30, help="seconds for login and each full frame")
        if name == "probe":
            s.add_argument("--frame")
        if name == "latency":
            s.add_argument("--input", choices=("key", "pointer"), required=True)
            s.add_argument("--samples", type=int, required=True)
            s.add_argument("--marker-log")
            s.add_argument("--out", required=True)
            s.add_argument("--timeout-ms", type=int, default=1000)
            s.add_argument("--seed", type=int, default=1)
        if name == "window":
            s.add_argument("--seconds", type=float, required=True)
            s.add_argument("--frame", required=True)
            s.add_argument("--go", required=True)
            s.add_argument("--out", required=True)
            s.add_argument("--nonce")
    args = p.parse_args(argv)
    if getattr(args, "nonce", None) and not re.fullmatch(r"[0-9a-f]{32}", args.nonce):
        p.error("--nonce is 32 lowercase hex characters")
    try:
        return {"probe": cmd_probe, "latency": cmd_latency, "window": cmd_window}[args.verb](args)
    except (RFBError, OSError) as e:
        print(f"rfb-viewer: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
