"""Minimal RFB (VNC) client: keyboard, pointer and raw framebuffer capture.

Used by fuzz.py to send real HID-level input into a Tart VM through
Virtualization.framework's VNC server (`tart run --vnc-experimental`), so the
guest needs no Accessibility (TCC) grant. Standard library only; VNC password
auth uses the host's `openssl des-ecb` (LibreSSL on macOS).
"""

from __future__ import annotations

import socket
import struct
import subprocess
import time
import zlib

# X11 keysyms for the keys the fuzzer sends.
KEYSYM = {
    # Virtualization.framework's VNC server maps Alt to Command and Meta to Option
    # (measured on macOS 14.8.7 guests; fuzz.check_input re-checks Command each run).
    "cmd": 0xFFEA,  # Alt_R
    "ctrl": 0xFFE3,
    "opt": 0xFFE7,  # Meta_L
    "shift": 0xFFE1,
    "return": 0xFF0D,
    "enter": 0xFF0D,
    "esc": 0xFF1B,
    "tab": 0xFF09,
    "backspace": 0xFF08,
    "delete": 0xFFFF,
    "left": 0xFF51,
    "up": 0xFF52,
    "right": 0xFF53,
    "down": 0xFF54,
    "home": 0xFF50,
    "end": 0xFF57,
    "pageup": 0xFF55,
    "pagedown": 0xFF56,
    "space": 0x20,
}
for _i in range(1, 13):
    KEYSYM[f"f{_i}"] = 0xFFBE + _i - 1

# Symbols as written in the app's shortcut strings (e.g. "⇧⌘D").
GLYPH = {"⌘": "cmd", "⌃": "ctrl", "⌥": "opt", "⇧": "shift", "↩": "return", "⎋": "esc",
         "⇥": "tab", "⌫": "backspace", "⌦": "delete", "←": "left", "→": "right",
         "↑": "up", "↓": "down", "↖": "home", "↘": "end", "⇞": "pageup", "⇟": "pagedown",
         "␣": "space"}


def _des_response(password: str, challenge: bytes) -> bytes:
    key = password.encode()[:8].ljust(8, b"\0")
    # VNC reverses the bit order of every key byte.
    key = bytes(int(f"{b:08b}"[::-1], 2) for b in key)
    out = subprocess.run(["/usr/bin/openssl", "enc", "-des-ecb", "-K", key.hex(), "-nopad"],
                         input=challenge, capture_output=True, check=True).stdout
    return out[:16]


class RFB:
    def __init__(self, host: str, port: int, password: str | None, timeout: float = 15):
        self.sock = socket.create_connection((host, port), timeout=timeout)
        ver = self._recv(12)
        if not ver.startswith(b"RFB "):
            raise RuntimeError(f"not a VNC server: {ver!r}")
        self.sock.sendall(b"RFB 003.008\n")
        n = self._recv(1)[0]
        if n == 0:
            raise RuntimeError("server refused: " + self._reason())
        types = self._recv(n)
        if 1 in types:
            self.sock.sendall(b"\x01")
        elif 2 in types:
            if password is None:
                raise RuntimeError("server wants a VNC password")
            self.sock.sendall(b"\x02")
            self.sock.sendall(_des_response(password, self._recv(16)))
        else:
            raise RuntimeError(f"no supported security type in {list(types)}")
        if struct.unpack(">I", self._recv(4))[0] != 0:
            raise RuntimeError("VNC auth failed: " + self._reason())
        self.sock.sendall(b"\x01")  # shared
        self.width, self.height = struct.unpack(">HH", self._recv(4))
        self._recv(16)  # pixel format
        self.name = self._recv(struct.unpack(">I", self._recv(4))[0]).decode(errors="replace")
        # 32bpp little-endian BGRX, raw encoding only.
        self.sock.sendall(struct.pack(">BxxxBBBBHHHBBBxxx", 0, 32, 24, 0, 1, 255, 255, 255, 16, 8, 0))
        # Raw pixels plus the DesktopSize (-223) and ExtendedDesktopSize (-308) pseudo
        # encodings: Virtualization.framework's VNC server stops the VM when a client
        # leaves them out (tart: "unclear if we can support clients that don't support
        # this pseudo encoding").
        encs = (0, -223, -308)
        self.sock.sendall(struct.pack(">BxH", 2, len(encs)) + b"".join(struct.pack(">i", e) for e in encs))
        self.px, self.py, self.buttons = self.width // 2, self.height // 2, 0

    def _recv(self, n: int) -> bytes:
        buf = b""
        while len(buf) < n:
            chunk = self.sock.recv(n - len(buf))
            if not chunk:
                raise ConnectionError("VNC connection closed")
            buf += chunk
        return buf

    def _reason(self) -> str:
        return self._recv(struct.unpack(">I", self._recv(4))[0]).decode(errors="replace")

    # Keyboard -----------------------------------------------------------
    def key(self, keysym: int, down: bool) -> None:
        self.sock.sendall(struct.pack(">BBxxI", 4, 1 if down else 0, keysym))

    def chord(self, spec: str, hold: float = 0.03) -> None:
        """Press a chord such as "cmd+shift+d", "⇧⌘D" or "esc"."""
        names = parse_chord(spec)
        syms = [KEYSYM.get(n, ord(n) if len(n) == 1 else None) for n in names]
        syms = [s for s in syms if s is not None]
        for s in syms:
            self.key(s, True)
            time.sleep(0.005)
        time.sleep(hold)
        for s in reversed(syms):
            self.key(s, False)
            time.sleep(0.005)

    def type_text(self, text: str, gap: float = 0.01) -> None:
        for ch in text:
            sym = KEYSYM["return"] if ch == "\n" else ord(ch)
            self.key(sym, True)
            self.key(sym, False)
            time.sleep(gap)

    # Pointer ------------------------------------------------------------
    def move(self, x: int, y: int) -> None:
        self.px, self.py = max(0, min(self.width - 1, x)), max(0, min(self.height - 1, y))
        self.sock.sendall(struct.pack(">BBHH", 5, self.buttons, self.px, self.py))

    def button(self, mask: int, down: bool) -> None:
        self.buttons = (self.buttons | mask) if down else (self.buttons & ~mask)
        self.sock.sendall(struct.pack(">BBHH", 5, self.buttons, self.px, self.py))

    def click(self, x: int, y: int, right: bool = False, count: int = 1) -> None:
        self.move(x, y)
        mask = 4 if right else 1
        for _ in range(count):
            self.button(mask, True)
            time.sleep(0.03)
            self.button(mask, False)
            time.sleep(0.05)

    def drag(self, x0: int, y0: int, x1: int, y1: int, steps: int = 12) -> None:
        self.move(x0, y0)
        self.button(1, True)
        for i in range(1, steps + 1):
            time.sleep(0.015)
            self.move(x0 + (x1 - x0) * i // steps, y0 + (y1 - y0) * i // steps)
        time.sleep(0.05)
        self.button(1, False)

    def scroll(self, x: int, y: int, down: bool, clicks: int = 3) -> None:
        self.move(x, y)
        mask = 16 if down else 8
        for _ in range(clicks):
            self.button(mask, True)
            self.button(mask, False)

    # Framebuffer --------------------------------------------------------
    def screenshot_png(self, timeout: float = 10) -> bytes:
        """Request a full raw frame and return it encoded as PNG."""
        self.sock.sendall(struct.pack(">BBHHHH", 3, 0, 0, 0, self.width, self.height))
        fb = bytearray(self.width * self.height * 4)
        deadline = time.time() + timeout
        got = False
        while not got and time.time() < deadline:
            mtype = self._recv(1)[0]
            if mtype == 0:
                self._recv(1)
                (nrect,) = struct.unpack(">H", self._recv(2))
                for _ in range(nrect):
                    x, y, w, h, enc = struct.unpack(">HHHHi", self._recv(12))
                    if enc in (-223, -308):
                        if enc == -308:
                            nscreens = self._recv(4)[0]
                            self._recv(16 * nscreens)
                        self.width, self.height = w, h
                        fb = bytearray(w * h * 4)
                        continue
                    if enc != 0:
                        raise RuntimeError(f"unexpected encoding {enc}")
                    data = self._recv(w * h * 4)
                    for row in range(h):
                        o = ((y + row) * self.width + x) * 4
                        fb[o:o + w * 4] = data[row * w * 4:(row + 1) * w * 4]
                got = True
            elif mtype == 1:
                self._recv(3)
                (n,) = struct.unpack(">H", self._recv(2))
                self._recv(n * 6)
            elif mtype == 2:
                pass
            elif mtype == 3:
                self._recv(3)
                self._recv(struct.unpack(">I", self._recv(4))[0])
            else:
                raise RuntimeError(f"unknown server message {mtype}")
        return _png(self.width, self.height, fb)

    def close(self) -> None:
        try:
            self.sock.close()
        except OSError:
            pass


def parse_chord(spec: str) -> list[str]:
    """Turn "⇧⌘D" or "cmd+shift+d" into ["shift", "cmd", "d"]."""
    if "+" in spec and len(spec) > 1:
        return [p.strip().lower() for p in spec.split("+") if p.strip()]
    names: list[str] = []
    for ch in spec:
        if ch in GLYPH:
            names.append(GLYPH[ch])
        else:
            names.append(ch.lower())
    return names


def _png(w: int, h: int, bgrx: bytes) -> bytes:
    raw = bytearray()
    for y in range(h):
        raw.append(0)
        row = bgrx[y * w * 4:(y + 1) * w * 4]
        for x in range(0, len(row), 4):
            raw += bytes((row[x + 2], row[x + 1], row[x]))
    def chunk(t: bytes, d: bytes) -> bytes:
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(bytes(raw), 6)) + chunk(b"IEND", b""))
