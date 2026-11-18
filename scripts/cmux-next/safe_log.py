"""safe_print: a progress line that can never stop the cleanup after it.

A script that launched an app or a daemon and prints a line right before it stops it (`print(...)`, then
`app.terminate()`, `os.kill(...)` or a `try`/`finally` that kills) must not die at the print. Python ignores
SIGPIPE, so a print to a stdout or stderr nobody reads any more (the caller's pipe closed: a cancelled run, a
`| head`, an agent that stopped reading) raises BrokenPipeError, and the kill after it never runs: the app lives on.
cmux#41832 review F1 and cmux#41803 F1 are the same class in shell and in push_range.py's fetch guard.

    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    from safe_log import safe_print

    safe_print(f"app pid {app.pid}", flush=True)

tests/test_python_guard_logs_survive_closed_pipe.py: in a function that stops a process, every line is safe_print.
"""

from __future__ import annotations


def safe_print(*args: object, **kwargs: object) -> None:
    """print(), except that a closed or broken output drops the line instead of raising."""
    try:
        print(*args, **kwargs)  # type: ignore[call-overload]
    except (BrokenPipeError, OSError, ValueError):  # ValueError: the stream was closed in this process
        pass  # the line is lost; what comes after it (the kill) still runs
