#!/usr/bin/env python3
"""A fake Claude-Code-like TUI for the cmux-terminal-agents tests.

It reads raw terminal input from a FIFO (each `cmux terminal write` is one
chunk) and keeps its rendered screen in a file the fake cmux returns for
`screen read`. It models the failures seen with real agent TUIs:

  --swallow-ms N   a bracketed paste renders into the composer N ms after the
                   paste ends; a CR that arrives before that (in the same
                   write as the paste, or right after it) is dropped.
  --ready-ms N     input that arrives in the first N ms after launch is lost
                   (the TUI is still starting, as with a real cold start).
  --ignore-enter   CR never submits (a stuck composer).

Submitted prompts are appended to <dir>/<term>.submitted (one JSON per line)
and every input event to <dir>/<term>.events.
"""

import argparse
import json
import os
import select
import time

RULE = "─" * 40


class Tui:
    def __init__(self, a):
        self.a = a
        self.start = time.monotonic()
        self.transcript = ["Claude Code Fake Agent"]
        self.composer = ""
        self.pending = None  # (render_at, text) of a paste not yet rendered
        self.busy_until = 0.0
        self.menu = False
        self.screen_path = os.path.join(a.dir, a.term + ".screen")
        self.submitted = os.path.join(a.dir, a.term + ".submitted")
        self.events = os.path.join(a.dir, a.term + ".events")
        if a.prompt:
            self.submit(a.prompt)
        self.render()

    def log(self, **ev):
        ev["t_ms"] = int((time.monotonic() - self.start) * 1000)
        with open(self.events, "a") as f:
            f.write(json.dumps(ev) + "\n")

    def render(self):
        lines = list(self.transcript)
        if self.menu == "late":
            # Like Codex's menus: digits do nothing; arrows move, Enter picks.
            sel = getattr(self, "late_sel", 1)
            opts = ["Review hooks", "Trust all and continue", "Continue without trusting"]
            lines += ["  Hooks need review", "  1 hook is new or changed."]
            lines += [("› " if n == sel else "  ") + f"{n}. {o}" for n, o in enumerate(opts, 1)]
            lines += ["  enter confirm · esc skip"]
        elif self.menu:
            lines += ["Do you want to proceed?", "❯ 1. Yes", "  2. No", "Esc to cancel"]
        else:
            lines += [RULE] + [("❯ " if i == 0 else "  ") + l for i, l in enumerate((self.composer or "").split("\n"))] + [RULE]
            status = "  esc to interrupt" if time.monotonic() < self.busy_until else "  ? for shortcuts"
            lines.append(status)
        tmp = self.screen_path + ".tmp"
        with open(tmp, "w") as f:
            f.write("\n".join(lines) + "\n")
        os.replace(tmp, self.screen_path)

    def hook(self, state):
        """The cmux agent hook record, as `cmux agent list` reports it."""
        if not self.a.hook:
            return
        with open(os.path.join(self.a.dir, self.a.term + ".hook"), "w") as f:
            json.dump({"terminal_id": self.a.term, "state": state, "updated_at_ms": int(time.time() * 1000)}, f)

    def submit(self, text):
        self.log(ev="submit", text=text)
        # Codex's hooks report `idle` first and `working` a moment later.
        self.hook("idle")
        self.hook_working_at = time.monotonic() + 0.8
        with open(self.submitted, "a") as f:
            f.write(json.dumps({"text": text}) + "\n")
        for i, l in enumerate(text.split("\n")):
            self.transcript.append(("❯ " if i == 0 else "  ") + l)
        if text.strip() == "menu":
            self.menu = True
        else:
            self.busy_until = time.monotonic() + self.a.busy_ms / 1000
            self.answer_pending = True
        self.composer = ""

    def tick(self):
        now = time.monotonic()
        changed = False
        if self.a.late_menu_ms and not getattr(self, "late_shown", False) and (now - self.start) * 1000 >= self.a.late_menu_ms:
            self.late_shown = True
            self.menu = "late"
            changed = True
        if self.pending and now >= self.pending[0]:
            self.composer += self.pending[1]
            self.pending = None
            self.log(ev="paste_rendered")
            changed = True
        if getattr(self, "hook_working_at", None) and now >= self.hook_working_at:
            self.hook_working_at = None
            self.hook("working")
        if getattr(self, "answer_pending", False) and now >= self.busy_until:
            self.answer_pending = False
            self.transcript.append("⏺ READY")
            self.hook("idle")
            changed = True
        return changed

    def enter(self):
        if self.a.ignore_enter:
            self.log(ev="cr_ignored", reason="ignore-enter")
            return
        if self.pending:
            self.log(ev="cr_swallowed", reason="paste not rendered yet")
            return
        if self.composer.strip():
            self.submit(self.composer)

    def feed(self, data):
        now = time.monotonic()
        if (now - self.start) * 1000 < self.a.ready_ms:
            self.log(ev="lost_before_ready", bytes=len(data))
            return
        i = 0
        while i < len(data):
            if self.menu == "late" and data.startswith((b"\x1b[A", b"\x1b[B"), i):
                self.late_sel = max(1, min(3, getattr(self, "late_sel", 1) + (1 if data[i + 2:i + 3] == b"B" else -1)))
                i += 3
                continue
            if self.menu == "late" and data[i:i + 1] == b"\r":
                self.menu = False
                self.transcript.append(f"chose {getattr(self, 'late_sel', 1)}")
                self.log(ev="choose", option=str(getattr(self, "late_sel", 1)))
                i += 1
                continue
            if self.menu == "late" and (data.startswith(b"\x1b[200~", i) or not data.startswith(b"\x1b", i)):
                self.log(ev="typed_into_menu", byte=data[i:i + 1].decode(errors="replace"))
                i += 1
                continue
            if data.startswith(b"\x1b[200~", i):
                end = data.find(b"\x1b[201~", i)
                end = len(data) if end < 0 else end
                text = data[i + 6:end].decode(errors="replace").replace("\r\n", "\n").replace("\r", "\n")
                prev = self.pending[1] if self.pending else ""
                self.pending = (time.monotonic() + self.a.swallow_ms / 1000, prev + text)
                self.log(ev="paste", chars=len(text))
                i = end + 6
                continue
            b = data[i:i + 1]
            if b == b"\x1b":
                if data.startswith(b"\x1b[", i) and i + 2 < len(data):
                    i += 3  # arrow keys: ignored
                    continue
                self.log(ev="esc")
                if self.menu:
                    self.menu = False
                    self.transcript.append("cancelled")
                elif time.monotonic() < self.busy_until:
                    self.busy_until = 0
                    self.answer_pending = False
                    self.transcript.append("Interrupted")
            elif b in (b"\r", b"\n"):
                self.log(ev="cr")
                self.enter()
            elif self.menu and b.isdigit():
                self.menu = False
                self.transcript.append(f"chose {b.decode()}")
                self.log(ev="choose", option=b.decode())
            elif b == b"\x7f":
                self.composer = self.composer[:-1]
            else:
                self.composer += b.decode(errors="replace")
            i += 1


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--dir", required=True)
    p.add_argument("--term", required=True)
    p.add_argument("--swallow-ms", type=int, default=0)
    p.add_argument("--ready-ms", type=int, default=0)
    p.add_argument("--busy-ms", type=int, default=800)
    p.add_argument("--ignore-enter", action="store_true")
    p.add_argument("--hook", action="store_true", help="write a cmux agent hook record")
    p.add_argument("--late-menu-ms", type=int, default=0, help="show a menu N ms after launch")
    p.add_argument("--prompt", default="")
    a = p.parse_args()
    fifo = os.path.join(a.dir, a.term + ".in")
    fd = os.open(fifo, os.O_RDWR)  # RDWR: no EOF when a writer closes
    tui = Tui(a)
    while True:
        r, _, _ = select.select([fd], [], [], 0.03)
        changed = tui.tick()
        if r:
            data = os.read(fd, 65536)
            if data:
                tui.feed(data)
                tui.tick()
                changed = True
        if changed or time.monotonic() < tui.busy_until + 0.1:
            tui.render()


if __name__ == "__main__":
    main()
