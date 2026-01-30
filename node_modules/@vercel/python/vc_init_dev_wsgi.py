"""
Auto-generated template used by vercel dev (Python, WSGI)
Serves static files from PUBLIC_DIR before delegating to the user WSGI app.

This file is written to the project at .vercel/python/vc_init_dev_wsgi.py
and imported by the dev server launcher.
"""
from importlib import import_module
from os import path as _p
import os
import mimetypes

# Simple ANSI coloring. Respect NO_COLOR environment variable.
_NO_COLOR = 'NO_COLOR' in os.environ
_RESET = "\x1b[0m"
_YELLOW = "\x1b[33m"
_GREEN = "\x1b[32m"

def _color(text: str, code: str) -> str:
    if _NO_COLOR:
        return text
    return f"{code}{text}{_RESET}"

USER_MODULE = "__VC_DEV_MODULE_PATH__"
PUBLIC_DIR = "public"

_mod = import_module(USER_MODULE)
_app = getattr(_mod, "app", None)
if _app is None:
    raise RuntimeError(
        f"Missing 'app' in module '{USER_MODULE}'. Define `app = ...` (WSGI app)."
    )


def _is_safe_file(base_dir: str, target: str) -> bool:
    try:
        base = _p.realpath(base_dir)
        tgt = _p.realpath(target)
        return (tgt == base or tgt.startswith(base + os.sep)) and _p.isfile(tgt)
    except Exception:
        return False


def _static_wsgi_app(environ, start_response):
    # Only handle GET/HEAD requests for static assets
    if environ.get("REQUEST_METHOD", "GET") not in ("GET", "HEAD"):
        return _not_found(start_response)

    req_path = environ.get("PATH_INFO", "/") or "/"
    safe = _p.normpath(req_path).lstrip("/")
    full = _p.join(PUBLIC_DIR, safe)
    if not _is_safe_file(PUBLIC_DIR, full):
        return _not_found(start_response)

    ctype, encoding = mimetypes.guess_type(full)
    headers = [("Content-Type", ctype or "application/octet-stream")]
    try:
        # For HEAD requests, send headers only
        if environ.get("REQUEST_METHOD") == "HEAD":
            start_response("200 OK", headers)
            return []
        with open(full, "rb") as f:
            data = f.read()
        headers.append(("Content-Length", str(len(data))))
        start_response("200 OK", headers)
        return [data]
    except Exception:
        return _not_found(start_response)


def _not_found(start_response):
    start_response("404 Not Found", [("Content-Type", "text/plain; charset=utf-8")])
    return [b"Not Found"]


def _combined_app(environ, start_response):
    # Try static first; if 404 then delegate to user app
    captured_status = ""
    captured_headers = tuple()
    body_chunks = []

    def capture_start_response(status, headers, exc_info=None):  # type: ignore[no-redef]
        nonlocal captured_status, captured_headers
        captured_status = status
        captured_headers = tuple(headers)
        # Return a writer that buffers the body
        def write(chunk: bytes):
            body_chunks.append(chunk)
        return write

    result = _static_wsgi_app(environ, capture_start_response)
    # If static handler produced 200, forward its response
    if captured_status.startswith("200 "):
        # Send headers and any chunks collected
        writer = start_response(captured_status, list(captured_headers))
        for chunk in body_chunks:
            writer(chunk)
        return result

    # Otherwise, delegate to user's WSGI app
    return _app(environ, start_response)


# Public WSGI application consumed by the dev runner
app = _combined_app


if __name__ == "__main__":
    # Development runner: prefer Werkzeug, fall back to stdlib wsgiref.
    # Bind to localhost on an ephemeral port and emit a recognizable log line
    # so the caller can detect the bound port.
    host = "127.0.0.1"
    try:
        from werkzeug.serving import run_simple
        run_simple(host, 0, app, use_reloader=False)
    except Exception:
        import sys
        print(_color("Werkzeug not installed; falling back to wsgiref (no reloader).", _YELLOW), file=sys.stderr)
        from wsgiref.simple_server import make_server
        httpd = make_server(host, 0, app)
        port = httpd.server_port
        print(_color(f"Serving on http://{host}:{port}", _GREEN))
        httpd.serve_forever()
