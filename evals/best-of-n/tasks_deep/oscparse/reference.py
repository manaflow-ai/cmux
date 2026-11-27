"""Pick the OSC sequences cmux acts on out of a pane's output stream.

The PTY hands output over in chunks of arbitrary size: a read can end anywhere, in the middle of an escape sequence
or of a UTF-8 character. An OSC sequence is ESC ] (bytes 0x1b 0x5d), a body, and a terminator: BEL (0x07) or ST
(ESC \\, bytes 0x1b 0x5c). The body is `Ps;Pt`, a number then its argument. cmux handles:

- OSC 7 `7;file://HOST/PATH`: the shell's working directory; PATH is percent-encoded.  -> Cwd(host, path)
- OSC 8 `8;PARAMS;URI`: start a hyperlink (an empty URI ends it); PARAMS are `k=v` pairs joined by ":". -> Hyperlink
- OSC 52 `52;SEL;DATA`: set the clipboard SEL to base64 DATA; DATA `?` is a query. -> Clipboard(sel, bytes or None)
- OSC 133 `133;MARK[;ARG]`: shell integration marks A, B, C, D; D's ARG is the exit code. -> Prompt(mark, code)

Any other OSC is dropped. Everything that is not an OSC sequence, other escape sequences included, is output text,
returned as Text events of decoded UTF-8.
"""
from __future__ import annotations

import base64
import codecs
import binascii
from dataclasses import dataclass, field
from urllib.parse import unquote, urlsplit

ESC, BEL, RBRACKET, BACKSLASH = 0x1B, 0x07, 0x5D, 0x5C
MAX_BODY = 1 << 20  # a longer OSC body is dropped


@dataclass(frozen=True)
class Text:
    text: str


@dataclass(frozen=True)
class Cwd:
    host: str
    path: str


@dataclass(frozen=True)
class Hyperlink:
    uri: str
    params: dict = field(default_factory=dict, hash=False)


@dataclass(frozen=True)
class Clipboard:
    selection: str
    data: bytes | None


@dataclass(frozen=True)
class Prompt:
    mark: str
    exit_code: int | None = None


def decode_osc(body: bytes):
    """The event for one complete OSC body, or None."""
    text = body.decode("utf-8", "replace")
    code, _, rest = text.partition(";")
    if code == "7":
        url = urlsplit(rest)
        if url.scheme != "file":
            return None
        return Cwd(url.hostname or "", unquote(url.path))
    if code == "8":
        params_text, sep, uri = rest.partition(";")
        if not sep:
            return None
        params = dict(p.split("=", 1) for p in params_text.split(":") if "=" in p)
        return Hyperlink(uri, params)
    if code == "52":
        selection, sep, data = rest.partition(";")
        if not sep:
            return None
        if data == "?":
            return Clipboard(selection, None)
        try:
            return Clipboard(selection, base64.b64decode(data, validate=True))
        except (binascii.Error, ValueError):
            return None
    if code == "133":
        mark, _, arg = rest.partition(";")
        if mark not in ("A", "B", "C", "D"):
            return None
        exit_code = int(arg) if mark == "D" and arg.lstrip("-").isdigit() else None
        return Prompt(mark, exit_code)
    return None


class OscParser:
    def __init__(self):
        self._in_osc = False
        self._esc = False  # the previous byte was an ESC whose meaning depends on the next byte
        self._body = bytearray()
        self._decoder = codecs.getincrementaldecoder("utf-8")("replace")

    def feed(self, data: bytes) -> list:
        events: list = []
        text = bytearray()

        def flush_text():
            if text:
                decoded = self._decoder.decode(bytes(text))
                text.clear()
                if decoded:
                    events.append(Text(decoded))

        i, n = 0, len(data)
        while i < n:
            if self._esc:
                self._esc = False
                b = data[i]
                if self._in_osc:
                    if b == BACKSLASH:
                        self._finish(events)
                        i += 1
                        continue
                    # An ESC that does not start ST aborts the OSC and starts what follows it.
                    self._in_osc = False
                    self._body.clear()
                if b == RBRACKET:
                    flush_text()
                    self._in_osc = True
                    self._body.clear()
                    i += 1
                    continue
                text.append(ESC)
                continue
            if self._in_osc:
                bel = data.find(BEL, i)
                esc = data.find(ESC, i)
                stops = [p for p in (bel, esc) if p != -1]
                if not stops:
                    self._body += data[i:]
                    break
                stop = min(stops)
                self._body += data[i:stop]
                if stop == bel:
                    self._finish(events)
                else:
                    self._esc = True
                i = stop + 1
                continue
            esc = data.find(ESC, i)
            if esc == -1:
                text += data[i:]
                break
            text += data[i:esc]
            self._esc = True
            i = esc + 1
        flush_text()
        return events

    def _finish(self, events: list) -> None:
        self._in_osc = False
        body = bytes(self._body)
        self._body.clear()
        if len(body) > MAX_BODY:
            return
        event = decode_osc(body)
        if event is not None:
            events.append(event)
