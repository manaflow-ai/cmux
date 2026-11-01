"""Read fleet admission from its configured authenticated transport.

The existing controller uses HTTP over Tailscale. Accept that only for a
numeric address belonging to an online peer of the running local Tailscale
daemon. The encrypted peer connection is the existing authority; no bearer
secret or new runner trust is introduced. HTTPS uses normal certificate and
hostname verification. Neither path follows redirects or environment proxies.
"""
from __future__ import annotations

import ipaddress
import json
import shutil
import subprocess
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any, Mapping

MAX_RESPONSE_BYTES = 1 << 20


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise ValueError("fleet admission must not redirect its authority")


def verify_authority(url: str) -> None:
    parsed = urllib.parse.urlsplit(url)
    if not parsed.hostname or parsed.username or parsed.password or parsed.fragment:
        raise ValueError("invalid fleet admission authority")
    if parsed.scheme == "https":
        return
    if parsed.scheme != "http":
        raise ValueError("fleet admission needs HTTPS or the existing Tailscale transport")
    try:
        address = ipaddress.ip_address(parsed.hostname)
    except ValueError as error:
        raise ValueError("HTTP fleet admission needs a numeric Tailscale peer address") from error
    if not (address in ipaddress.ip_network("100.64.0.0/10")
            or address in ipaddress.ip_network("fd7a:115c:a1e0::/48")):
        raise ValueError("plain HTTP fleet admission is outside Tailscale")
    executable = shutil.which("tailscale")
    if executable is None:
        app = Path("/Applications/Tailscale.app/Contents/MacOS/Tailscale")
        executable = str(app) if app.is_file() else None
    if executable is None:
        raise ValueError("cannot authenticate the controller's Tailscale peer")
    result = subprocess.run([executable, "status", "--json"], check=True,
                            capture_output=True, text=True, timeout=5)
    status = json.loads(result.stdout)
    peers = status.get("Peer") or {}
    if status.get("BackendState") != "Running" or not any(
            peer.get("Online") is True and str(address) in (peer.get("TailscaleIPs") or [])
            for peer in peers.values()):
        raise ValueError("controller is not an online authenticated Tailscale peer")


def exchange(url: str, payload: Mapping[str, Any] | None = None) -> dict[str, Any]:
    verify_authority(url)
    data = json.dumps(payload).encode() if payload is not None else None
    request = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json"})
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    with opener.open(request, timeout=35) as response:
        body = response.read(MAX_RESPONSE_BYTES + 1)
    if len(body) > MAX_RESPONSE_BYTES:
        raise ValueError("admission response exceeds the bounded size")
    value = json.loads(body)
    if not isinstance(value, dict):
        raise ValueError("admission response must be an object")
    return value
