"""Tell the chat a `cmux live` loop's build is in place, so its frames show it (cmuxterm-hq RFD 0152).

acpmux takes a frame of the chat's page after each UI edit (RFD 0151), 1.5 s after the save. A live
loop's build lands later: a Rust daemon swap or a Chromium engine build takes minutes, a Swift patch a
second or two. Each loop calls `built(SOURCE)` once that build is in place (the daemon swapped, the
renderers restarted, the patch applied), and acpmux keeps a `build` frame of the result in the chat's
running turn (`acpmux frame SESSION --built SOURCE --tree TREE`, `hub/turn_frames.rs` `built`).

The loop's chat is `ACPMUX_SESSION_ID` when it runs in the agent's shell. With its checkout (`tree`),
every other chat whose running turn worked in that checkout gets the frame too, and a loop started
from a plain terminal reaches them by the tree alone. With neither, or no `acpmux` on PATH, nothing
happens. Never blocks the loop and never fails it: the ask runs on a thread
bounded by `LIMIT_S`.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import threading

SOURCES = ("rust", "swift", "chromium", "web")
LIMIT_S = 10.0


def command(source: str, env: dict | None = None, tree: str | os.PathLike | None = None) -> list[str] | None:
    """The `acpmux frame` argv for `source`, or None when there is neither a chat nor a tree, or no acpmux."""
    env = os.environ if env is None else env
    session = (env.get("ACPMUX_SESSION_ID") or "").strip()
    tree = os.path.abspath(tree) if tree else None
    if source not in SOURCES or not (session or tree):
        return None
    binary = (env.get("ACPMUX_BIN") or "").strip() or shutil.which("acpmux", path=env.get("PATH"))
    if not binary:
        return None
    argv = [binary, "frame", session or "@", "--built", source]
    return argv + ["--tree", tree] if tree else argv


def ask(argv: list[str]) -> int | None:
    try:
        return subprocess.run(argv, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                              stderr=subprocess.DEVNULL, timeout=LIMIT_S).returncode
    except (OSError, subprocess.SubprocessError):
        return None


def built(source: str, env: dict | None = None, tree: str | os.PathLike | None = None) -> threading.Thread | None:
    """Ask the chats for a frame of `source`'s build of `tree`, in the background. The thread, or None."""
    argv = command(source, env, tree)
    if argv is None:
        return None
    thread = threading.Thread(target=ask, args=(argv,), name="live-frames", daemon=True)
    thread.start()
    return thread
