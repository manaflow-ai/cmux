# Auto-generated template used by vercel dev (Python, ASGI)
# Serves static files from PUBLIC_DIR before delegating to the user ASGI app.
import sys
import os
from os import path as _p
from importlib import import_module


# Simple ANSI coloring. Respect NO_COLOR environment variable.
_NO_COLOR = 'NO_COLOR' in os.environ
_RESET = "\x1b[0m"
_YELLOW = "\x1b[33m"
_GREEN = "\x1b[32m"
_RED = "\x1b[31m"

def _color(text: str, code: str) -> str:
    if _NO_COLOR:
        return text
    return f"{code}{text}{_RESET}"


# Optional StaticFiles import; tolerate missing deps
StaticFiles = None
try:
    from fastapi.staticfiles import StaticFiles as _SF
    StaticFiles = _SF
except Exception:
    try:
        from starlette.staticfiles import StaticFiles as _SF
        StaticFiles = _SF
    except Exception:
        StaticFiles = None

USER_MODULE = "__VC_DEV_MODULE_PATH__"
_mod = import_module(USER_MODULE)
_app = getattr(_mod, 'app', None)
if _app is None:
    raise RuntimeError(
        f"Missing 'app' in module '{USER_MODULE}'. Define `app = ...` (ASGI app)."
    )

# Prefer a callable app.asgi when available; some frameworks expose a boolean here
_CAND = getattr(_app, 'asgi', None)
USER_ASGI_APP = _CAND if callable(_CAND) else _app

PUBLIC_DIR = 'public'

# Prepare static files app (if starlette/fastapi installed)
static_app = None
if StaticFiles is not None:
    try:
        try:
            static_app = StaticFiles(directory=PUBLIC_DIR, check_dir=False)
        except TypeError:
            # Older Starlette without check_dir parameter
            static_app = StaticFiles(directory=PUBLIC_DIR)
    except Exception:
        static_app = None


async def app(scope, receive, send):
    if static_app is not None and scope.get('type') == 'http':
        req_path = scope.get('path', '/') or '/'
        safe = _p.normpath(req_path).lstrip('/')
        full = _p.join(PUBLIC_DIR, safe)
        try:
            base = _p.realpath(PUBLIC_DIR)
            target = _p.realpath(full)
            if (target == base or target.startswith(base + _p.sep)) and _p.isfile(target):
                await static_app(scope, receive, send)
                return
        except Exception:
            pass
    await USER_ASGI_APP(scope, receive, send)


if __name__ == '__main__':
    # Development runner for ASGI: prefer uvicorn, then hypercorn.
    # Bind to localhost on an ephemeral port and emit a recognizable log line
    # so the caller can detect the bound port.
    host = '127.0.0.1'
    try:
        import uvicorn
        uvicorn.run('vc_init_dev_asgi:app', host=host, port=0, use_colors=True)
    except Exception:
        try:
            import asyncio
            from hypercorn.config import Config
            from hypercorn.asyncio import serve

            config = Config()
            config.bind = [f'{host}:0']

            async def _run():
                await serve(app, config)

            asyncio.run(_run())
        except Exception:
            print(_color('No ASGI server found. Please install either "uvicorn" or "hypercorn" (e.g. "pip install uvicorn").', _RED), file=sys.stderr)
            sys.exit(1)
