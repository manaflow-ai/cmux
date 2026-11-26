MARK = b"\x1b]133;"
KEYBOARD_RESET = b"\x1b[<u\x1b[?2004l"
PROMPT_RESET = b"\x1b[?1000l\x1b[?1002l\x1b[?1003l\x1b[?1006l\x1b[?25h"


class ShellMarks:
    def __init__(self):
        self.running = False

    def feed(self, data: bytes) -> bytes:
        out = bytearray()
        start = 0
        while True:
            at = data.find(MARK, start)
            if at < 0 or at + len(MARK) >= len(data):
                break
            letter = data[at + len(MARK)]
            out += data[start:at]
            if letter == ord("C"):
                self.running = True
            elif letter == ord("D") and self.running:
                out += KEYBOARD_RESET
                self.running = False
            elif letter == ord("A") and not self.running:
                out += PROMPT_RESET
            out += MARK
            start = at + len(MARK)
        out += data[start:]
        return bytes(out)

    def flush(self) -> bytes:
        return b""
