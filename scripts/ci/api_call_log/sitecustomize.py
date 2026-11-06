"""Name every GitHub API request a Python process makes, for REST budget attribution (see env.sh).

On PYTHONPATH only while env.sh is active. Wraps http.client (which urllib, urllib3 and requests
all use) so each response from api.github.com or uploads.github.com writes one `gh-call` line
(the format scripts/ci/gh_call_log.py reads). The line goes to the step shell's stderr, never this
process's own. It holds the method, the path with ids folded and no query string, the
X-RateLimit-Resource/Used/Remaining/Reset headers, and the script's file name. It never holds
another header, a body or a token. It makes no request, and nothing it does can raise into the
caller. A sitecustomize this one shadows (Ubuntu's apport hook) still runs.
"""
import os
import sys

_HOSTS = {"api.github.com", "uploads.github.com"}


def _install() -> None:
    import http.client
    import re
    import time

    sink = os.environ.get("API_CALL_LOG_SINK", "")
    if not sink:
        return
    pending = os.path.join(os.environ.get("API_CALL_LOG_DIR", "/nonexistent"), "pending.log")
    script = os.path.basename(sys.argv[0]) if sys.argv and sys.argv[0] else "-"
    script = re.sub(r"[^A-Za-z0-9_.-]", "", script)[:64] or "-"
    secretish = re.compile(r"gh[pousr]_|github_pat_")
    segment = re.compile(r"[A-Za-z0-9_.:{}-]{1,100}")

    def fold(path: str) -> str:
        path = path.split("?", 1)[0].split("#", 1)[0]
        if "://" in path:
            path = "/" + path.split("://", 1)[1].partition("/")[2]
        out = []
        for part in path.split("/"):
            if not part:
                continue
            if part.isdigit():
                out.append("{n}")
            elif re.fullmatch(r"[0-9a-f]{40}", part):
                out.append("{sha}")
            elif secretish.search(part) or not segment.fullmatch(part):
                out.append("{x}")
            else:
                out.append(part)
        return "/" + "/".join(out)

    def clean(value) -> str:
        return " ".join(str(value or "").split()) or "-"

    def write(text: str) -> None:
        target = sink
        if target.startswith("/proc/"):
            try:
                if os.readlink(target) != os.environ.get("API_CALL_LOG_PIPE", ""):
                    target = pending
            except OSError:
                target = pending
        for path in (target, pending):
            try:
                fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
                try:
                    os.write(fd, text.encode("utf-8", "replace"))
                finally:
                    os.close(fd)
                return
            except OSError:
                continue

    orig_putrequest = http.client.HTTPConnection.putrequest
    orig_getresponse = http.client.HTTPConnection.getresponse

    def putrequest(self, method, url, *args, **kwargs):
        try:
            host = getattr(self, "_tunnel_host", None) or getattr(self, "host", "")
            self._api_call_log = (str(method), str(url)) if host in _HOSTS else None
        except Exception:  # noqa: BLE001 - logging only
            pass
        return orig_putrequest(self, method, url, *args, **kwargs)

    def getresponse(self, *args, **kwargs):
        response = orig_getresponse(self, *args, **kwargs)
        try:
            noted = getattr(self, "_api_call_log", None)
            if noted:
                self._api_call_log = None
                method, url = noted
                get = response.getheader
                path = fold(url)
                if path == "/graphql":
                    method = "GRAPHQL"
                fields = (
                    time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                    os.environ.get("GITHUB_WORKFLOW", ""), os.environ.get("GITHUB_JOB", ""),
                    get("X-RateLimit-Resource"), get("X-RateLimit-Used"), get("X-RateLimit-Remaining"),
                    get("X-RateLimit-Reset"),
                    f"{method.upper()} {path} {response.status} [py:{script}]",
                )
                write("\t".join(["gh-call", *(clean(f) for f in fields)]) + "\n")
        except Exception:  # noqa: BLE001 - logging only
            pass
        return response

    http.client.HTTPConnection.putrequest = putrequest
    http.client.HTTPConnection.getresponse = getresponse


def _chain() -> None:
    """Run the sitecustomize this file shadows, as Python would have."""
    import importlib.machinery
    import importlib.util

    here = os.path.dirname(os.path.abspath(__file__))
    rest = [p for p in sys.path if os.path.abspath(p or ".") != here]
    spec = importlib.machinery.PathFinder.find_spec("sitecustomize", rest)
    if spec is None or spec.loader is None or not spec.origin or os.path.abspath(spec.origin) == os.path.abspath(__file__):
        return
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)


try:
    _install()
except Exception:  # noqa: BLE001 - logging only
    pass
try:
    _chain()
except Exception:  # noqa: BLE001 - the shadowed hook's own failure stays as quiet as Python keeps it
    pass
