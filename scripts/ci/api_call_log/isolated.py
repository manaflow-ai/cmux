"""Run a `python3 -I` / `-E` program with sitecustomize.py's hook installed first (see env.sh).

env.sh's python3 function turns `python3 -I [options] TARGET ARGS...` into
`python3 -I [options] -c "$(cat isolated.py)" MODE TARGET ARGS...`, MODE one of `file`, `-m` or `-c`. This
runs the hook from $API_CALL_LOG_DIR/py, then the program as Python would have: sys.argv as it would be,
`__name__ == "__main__"`, sys.path[0] as -I/-E set it, its exit code and its exceptions. It never prints.
"""
import os as _o
import sys as _s

_p = _o.path.join(_o.environ.get("API_CALL_LOG_DIR", "/nonexistent"), "py", "sitecustomize.py")
try:
    with open(_p, encoding="utf-8") as _f:
        exec(compile(_f.read(), _p, "exec"), {"__name__": "_api_call_log_hook", "__file__": _p,
                                             "_api_call_log_no_chain": True})
except Exception:  # noqa: BLE001 - logging only
    pass
_mode, _target, _rest = _s.argv[1], _s.argv[2], _s.argv[3:]
import runpy as _r  # noqa: E402

# 3.11+ names it safe_path (-I implies it); 3.9 and 3.10 leave the script's directory out only under -I.
_safe = getattr(_s.flags, "safe_path", False) or bool(_s.flags.isolated)
if _s.path and _s.path[0] == "" and _mode != "-c":
    del _s.path[0]  # `-c` put the working directory first; the program's own mode decides below

if _mode == "-m":
    _s.argv = [_target, *_rest]
    if not _safe:
        _s.path.insert(0, _o.getcwd())
    _r.run_module(_target, run_name="__main__", alter_sys=True)
elif _mode == "-c":
    _s.argv = ["-c", *_rest]
    _g = {"__name__": "__main__", "__builtins__": __builtins__}
    exec(compile(_target, "<string>", "exec"), _g)
else:
    _s.argv = [_target, *_rest]
    if not _safe:
        _s.path.insert(0, _o.path.dirname(_o.path.abspath(_target)))
    _r.run_path(_target, run_name="__main__")
