"""HTTP for benches: IPv4 addresses first.

urllib tries each address of a host in turn with the full timeout. On a host whose IPv6 route is
dead (some fleet and lane machines), a CDN name with several IPv6 addresses then hangs for minutes
before IPv4 is tried. curl does not (it races the families). cmux-bench sorts IPv4 first, only
inside its own process.
"""
from __future__ import annotations

import socket
import urllib.request

_orig_getaddrinfo = socket.getaddrinfo


def _v4_first(*args, **kwargs):
    infos = _orig_getaddrinfo(*args, **kwargs)
    return sorted(infos, key=lambda info: 0 if info[0] == socket.AF_INET else 1)


socket.getaddrinfo = _v4_first  # type: ignore[assignment]

UA = {"User-Agent": "cmux-bench"}


def open_url(url: str, *, method: str | None = None, headers: dict[str, str] | None = None, timeout: float = 30):
    req = urllib.request.Request(url, method=method, headers={**UA, **(headers or {})})
    return urllib.request.urlopen(req, timeout=timeout)
