import re

MAX_LINE_BYTES = 1024
MAX_TAIL_CHARS = 160
MAX_TAIL_BYTES = 480

_ANSI = re.compile(r"\x1b(?:\[[0-?]*[ -/]*[@-~]|[\]PX^_].*?(?:\x07|\x1b\\)|.)", re.S)


def strip_ansi(text: str) -> str:
    return _ANSI.sub("", text)


def clean_line(text: str) -> str:
    """One output line as the ticker shows it."""
    out = []
    size = 0
    for ch in strip_ansi(text):
        if ch == "\t":
            ch = " "
        if ch < " " or ch == "\x7f" or (ch == " " and (not out or out[-1] == " ")):
            continue
        if len(out) == MAX_TAIL_CHARS or size + len(ch.encode()) > MAX_TAIL_BYTES:
            break
        out.append(ch)
        size += len(ch.encode())
    return "".join(out).rstrip()


class TailLine:
    def __init__(self):
        self.pending = bytearray()
        self.tail = None
        self.changed = False

    def feed(self, data: bytes) -> bool:
        segments = re.split(rb"[\r\n]", data)
        for i, segment in enumerate(segments):
            room = MAX_LINE_BYTES - len(self.pending)
            self.pending += segment[:max(room, 0)]
            if i < len(segments) - 1:
                self._end_line()
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
