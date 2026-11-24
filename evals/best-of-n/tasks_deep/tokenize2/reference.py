"""Splits the byte stream a program writes to the terminal into text and escape sequences.

The PTY reader hands `feed` whatever chunk `read()` returned, so a sequence can be cut anywhere. Tokens are
(kind, bytes) pairs, kind one of "text", "csi", "osc", "esc". The rules follow the VT500 parser that xterm and
Ghostty implement, so some are not what you would guess:

- Text is every byte outside a sequence, including CAN, SUB and other C0 controls. `feed` returns text as soon as
  it has it (the screen must not wait for the next chunk), so a run of text may come back in several tokens.
- ESC starts a sequence. Inside any sequence, CAN (0x18) or SUB (0x1A) aborts it: the sequence so far and the
  CAN/SUB are dropped. Another ESC also aborts it: the sequence so far is dropped and the new ESC starts over.
- CSI is ESC "[" then parameter and intermediate bytes (0x20-0x3F) and one final byte (0x40-0x7E); its token is
  all of those bytes. A C0 control (below 0x20, other than ESC, CAN and SUB) inside a CSI is not part of it: it
  comes out as a text token right where it occurs, before the CSI's token, and the CSI goes on (if the CSI later
  aborts, the control has still come out). DEL (0x7F) inside a CSI is ignored. Any byte 0x80 or above aborts the
  CSI, and that byte is then text.
- OSC is ESC "]" up to and including a BEL (0x07) or an ST (ESC "\\"); its token is all of it. Inside an OSC an
  ESC not followed by "\\" aborts the OSC and starts a new sequence.
- Any other ESC sequence is ESC, any intermediates (0x20-0x2F), and a final byte (0x30-0x7E): an "esc" token.
  Any other byte where the final should be aborts it, and that byte is processed again as if after the abort.
- `flush()` ends the stream: an unfinished sequence is dropped (any C0 control already inside it still comes out).
"""
import re

ESC, CAN, SUB, BEL = 0x1B, 0x18, 0x1A, 0x07
_OSC_STOP = re.compile(rb"[\x07\x18\x1a\x1b]")


class Incomplete(Exception):
    """The sequence starting here needs more bytes; `controls` are the C0 controls already found inside it."""

    def __init__(self, controls):
        self.controls = controls


def _sequence(buf, i, osc_from=None):
    """Parse the sequence whose ESC is at `i`. Returns (end, tokens): the index after it and the tokens it makes
    (none when it aborted). Raises Incomplete when the buffer ends first."""
    n = len(buf)
    if i + 1 >= n:
        raise Incomplete([])
    c = buf[i + 1]
    if c in (CAN, SUB):
        return i + 2, []
    if c == ESC:
        return i + 1, []
    if c == 0x5B:  # "["
        body = bytearray(buf[i:i + 2])
        controls = []
        k = i + 2
        while True:
            if k >= n:
                raise Incomplete(controls)
            b = buf[k]
            if 0x40 <= b <= 0x7E:
                body.append(b)
                return k + 1, controls + [("csi", bytes(body))]
            if 0x20 <= b <= 0x3F:
                body.append(b)
            elif b == 0x7F:
                pass
            elif b in (CAN, SUB):
                return k + 1, controls
            elif b == ESC or b >= 0x80:
                return k, controls
            else:
                controls.append(("text", bytes([b])))
            k += 1
    if c == 0x5D:  # "]"
        m = _OSC_STOP.search(buf, max(i + 2, osc_from or 0))
        if m is None:
            raise Incomplete([])
        k = m.start()
        b = buf[k]
        if b == BEL:
            return k + 1, [("osc", bytes(buf[i:k + 1]))]
        if b in (CAN, SUB):
            return k + 1, []
        if k + 1 >= n:
            raise Incomplete([])
        if buf[k + 1] == 0x5C:
            return k + 2, [("osc", bytes(buf[i:k + 2]))]
        return k, []
    k = i + 1
    while k < n and 0x20 <= buf[k] <= 0x2F:
        k += 1
    if k >= n:
        raise Incomplete([])
    b = buf[k]
    if 0x30 <= b <= 0x7E:
        return k + 1, [("esc", bytes(buf[i:k + 1]))]
    if b in (CAN, SUB):
        return k + 1, []
    return k, []


def _scan(buf, out, final):
    """Append the tokens of `buf` to `out`; return the index where an unfinished sequence starts (len(buf) if
    none). With `final`, an unfinished sequence is dropped instead."""
    i, n = 0, len(buf)
    while i < n:
        j = buf.find(ESC, i)
        if j < 0:
            out.append(("text", bytes(buf[i:])))
            return n
        if j > i:
            out.append(("text", bytes(buf[i:j])))
        try:
            i, tokens = _sequence(buf, j)
        except Incomplete as inc:
            if final:
                out.extend(inc.controls)
                return n
            return j
        out.extend(tokens)
    return n


class Tokenizer:
    def __init__(self):
        self._pending = bytearray()  # an unfinished sequence, from its ESC
        self._osc_from = 0  # where to resume searching for its end, if it is an OSC

    def feed(self, data: bytes) -> list[tuple[str, bytes]]:
        """The tokens completed by `data`, in stream order."""
        out = []
        if self._pending:
            self._pending += data
            buf = self._pending
            try:
                end, tokens = _sequence(buf, 0, self._osc_from)
            except Incomplete:
                self._osc_from = max(2, len(buf) - 1)
                return out
            out.extend(tokens)
            data = bytes(buf[end:])
            self._pending = bytearray()
        i = _scan(data, out, final=False)
        if i < len(data):
            self._pending = bytearray(data[i:])
            self._osc_from = 0
        return out

    def flush(self) -> list[tuple[str, bytes]]:
        """End of stream: the tokens still owed (an unfinished sequence is dropped)."""
        out = []
        _scan(bytes(self._pending), out, final=True)
        self._pending = bytearray()
        return out


def tokenize(data: bytes) -> list[tuple[str, bytes]]:
    """All tokens of a complete stream."""
    t = Tokenizer()
    return t.feed(data) + t.flush()


def visible_text(data: bytes) -> bytes:
    """The stream's text with every escape sequence removed."""
    return b"".join(chunk for kind, chunk in tokenize(data) if kind == "text")
