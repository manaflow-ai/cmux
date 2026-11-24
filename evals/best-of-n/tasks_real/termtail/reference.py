import unicodedata

MAX_LINE_BYTES = 1024
MAX_TAIL_CHARS = 160
MAX_TAIL_BYTES = 480

ESC, BEL, CAN, SUB = 0x1B, 0x07, 0x18, 0x1A
LF, CR = 0x0A, 0x0D
TEXT, START, CSI, STR, STR_ESC = range(5)


def clean_line(text: str) -> str:
    """One output line as the ticker shows it."""
    out = []
    size = 0
    for ch in text:
        if ch == "\t":
            ch = " "
        if unicodedata.category(ch) == "Cc" or (ch == " " and (not out or out[-1] == " ")):
            continue
        width = len(ch.encode("utf-8", "surrogatepass"))
        if len(out) == MAX_TAIL_CHARS or size + width > MAX_TAIL_BYTES:
            break
        out.append(ch)
        size += width
    return "".join(out).rstrip()


class TailLine:
    def __init__(self):
        self.pending = bytearray()
        self.escape = TEXT
        self.tail = None
        self.changed = False

    def feed(self, data: bytes) -> bool:
        for byte in data:
            state = self.escape
            if byte in (CAN, SUB):
                state = TEXT
            elif state in (TEXT, CSI, START) and byte in (LF, CR):
                self._end_line()
            elif state in (TEXT, CSI) and byte == ESC:
                state = START
            elif state == TEXT:
                if len(self.pending) < MAX_LINE_BYTES:
                    self.pending.append(byte)
            elif state in (START, STR_ESC):
                if byte == ord("["):
                    state = CSI
                elif byte in b"]PX^_":
                    state = STR
                elif byte == ESC:
                    state = START
                else:
                    state = TEXT
            elif state == CSI:
                if 0x40 <= byte <= 0x7E:
                    state = TEXT
            elif state == STR:
                if byte == BEL:
                    state = TEXT
                elif byte == ESC:
                    state = STR_ESC
            self.escape = state
        return self.changed

    def _end_line(self):
        if not self.pending:
            return
        line = clean_line(self.pending.decode("utf-8", "replace"))
        self.pending.clear()
        if not line or line == self.tail:
            return
        self.tail = line
        self.changed = True

    def take_change(self):
        if not self.changed:
            return None
        self.changed = False
        return self.tail
