"""The terminal: the chat scrolls above, one status bar and one input line stay at the bottom.

`TtyUI` uses a scroll region, so text that streams in never runs through what the person is
typing. `PlainUI` prints lines (a pipe, a test, a log)."""

import os
import shutil
import signal
import sys
import threading

DIM, BOLD, CYAN, YELLOW, GREEN, RED, RESET = "\x1b[2m", "\x1b[1m", "\x1b[36m", "\x1b[33m", "\x1b[32m", "\x1b[31m", "\x1b[0m"


def who(holder):
    holder = holder or ""
    if holder.startswith("vm:"):
        return "cloud:" + holder[3:]
    if holder.startswith("device:"):
        return holder[7:]
    return holder or "?"


def lines_of(event, color=True):
    """An event as the lines the chat shows."""
    c = (lambda code, text: code + text + RESET) if color else (lambda code, text: text)
    kind = event.get("kind")
    if kind == "user":
        sender = who(event.get("sender"))
        return ["", c(CYAN + BOLD, "> " + event.get("text", "")) + c(DIM, "   (%s)" % sender)]
    if kind == "text":
        return [event.get("text", "").rstrip()]
    if kind == "tool":
        return [c(DIM, "  * %s" % event.get("label", "tool"))]
    if kind == "tool_result":
        mark = "ok" if event.get("ok") else "failed"
        return [c(DIM, "    -> %s %s" % (mark, event.get("label", "")))]
    if kind == "turn_end":
        if event.get("ok"):
            return [c(DIM, "  (done on %s)" % who(event.get("by")))]
        return [c(RED, "  (the turn failed on %s: %s)" % (who(event.get("by")), event.get("error")))]
    if kind == "note":
        return [c(YELLOW, "-- %s --" % event.get("text", ""))]
    return []


class PlainUI:
    def __init__(self, out=None, color=False):
        self.out = out or sys.stdout
        self.color = color
        self.lock = threading.Lock()
        self._status = None
        self._mid = False

    def _write(self, text):
        self.out.write(text)
        self.out.flush()

    def line(self, text=""):
        with self.lock:
            if self._mid:
                self._write("\n")
                self._mid = False
            if os.environ.get("AUTO_DEBUG"):
                import time
                text = "%.1f %s" % (time.time() % 1000, text)
            self._write(text + "\n")

    def event(self, event):
        for line in lines_of(event, self.color):
            self.line(line)

    def delta(self, text):
        with self.lock:
            self._mid = True
            self._write(text)

    def end_delta(self):
        with self.lock:
            if self._mid:
                self._write("\n")
                self._mid = False

    def note(self, text):
        self.line((YELLOW + "-- %s --" + RESET if self.color else "-- %s --") % text)

    def status(self, text):
        if text != self._status:
            self._status = text
            self.line((DIM + "[%s]" + RESET if self.color else "[%s]") % text)

    def read_line(self):
        line = sys.stdin.readline()
        return None if line == "" else line.rstrip("\n")

    def close(self):
        pass


class TtyUI:
    def __init__(self):
        import termios
        import tty
        self.fd = sys.stdin.fileno()
        self.saved = termios.tcgetattr(self.fd)
        tty.setcbreak(self.fd)
        self.lock = threading.RLock()
        self.buffer = ""
        self.bar = ""
        self.mid = False
        self.closed = False
        self._layout()
        try:
            signal.signal(signal.SIGWINCH, lambda *_: self._layout())
        except ValueError:
            pass

    def _w(self, text):
        os.write(sys.stdout.fileno(), text.encode("utf-8", "replace"))

    def _layout(self):
        with self.lock:
            size = shutil.get_terminal_size((100, 30))
            self.rows, self.cols = max(6, size.lines), max(20, size.columns)
            # Rows 1..rows-2 scroll; the bar and the input line stay.
            self._w("\x1b[1;%dr\x1b[%d;1H\x1b7" % (self.rows - 2, self.rows - 2))
            self._draw_fixed()

    def _draw_fixed(self):
        bar = (" " + self.bar)[: self.cols].ljust(self.cols)
        shown = self.buffer[-(self.cols - 4):]
        self._w("\x1b[%d;1H\x1b[7m%s\x1b[0m\x1b[%d;1H\x1b[2K%s> %s%s" % (
            self.rows - 1, bar, self.rows, CYAN, RESET, shown))

    def _out(self, text):
        """Text into the scrolling part, at the place the last output ended."""
        with self.lock:
            if self.closed:
                return
            self._w("\x1b8" + text.replace("\n", "\r\n") + "\x1b7")
            self._draw_fixed()

    def line(self, text=""):
        with self.lock:
            lead = "\n" if self.mid else ""
            self.mid = False
            self._out(lead + text + "\n")

    def event(self, event):
        for line in lines_of(event, True):
            self.line(line)

    def delta(self, text):
        with self.lock:
            self.mid = True
            self._out(text)

    def end_delta(self):
        with self.lock:
            if self.mid:
                self.mid = False
                self._out("\n")

    def note(self, text):
        self.line(YELLOW + "-- %s --" % text + RESET)

    def status(self, text):
        with self.lock:
            if text != self.bar and not self.closed:
                self.bar = text
                self._draw_fixed()

    def read_line(self):
        """One line the person typed, or None at Ctrl-D."""
        while True:
            try:
                data = os.read(self.fd, 1024)
            except OSError:
                return None
            if not data:
                return None
            text = data.decode("utf-8", "ignore")
            done = None
            with self.lock:
                i = 0
                while i < len(text):
                    ch = text[i]
                    i += 1
                    if ch in "\r\n":
                        done, self.buffer = self.buffer, ""
                        break
                    if ch == "\x04":
                        return None
                    if ch in "\x7f\x08":
                        self.buffer = self.buffer[:-1]
                    elif ch == "\x15":
                        self.buffer = ""
                    elif ch == "\x1b":
                        # An arrow or another key sequence: skip it.
                        while i < len(text) and not text[i].isalpha() and text[i] != "~":
                            i += 1
                        i += 1
                    elif ch >= " ":
                        self.buffer += ch
                self._draw_fixed()
            if done is not None:
                return done

    def close(self):
        import termios
        with self.lock:
            if self.closed:
                return
            self.closed = True
            self._w("\x1b[r\x1b[%d;1H\n" % self.rows)
            termios.tcsetattr(self.fd, termios.TCSADRAIN, self.saved)


def make():
    if sys.stdin.isatty() and sys.stdout.isatty() and os.environ.get("AUTO_PLAIN") != "1":
        return TtyUI()
    return PlainUI(color=sys.stdout.isatty())
