#!/usr/bin/env python3
"""Web Page Replay for the Chromium tabs of a corpus story (p12-perf-process.md 3.8, task 113).

    python3 -I scripts/perf-lab/corpus/wpr.py spki [--wpr DIR]
    python3 -I scripts/perf-lab/corpus/wpr.py record --app BUNDLE --urls URLS.txt --archive OUT.wprgo [--out DIR]
    python3 -I scripts/perf-lab/corpus/wpr.py verify --app BUNDLE --urls URLS.txt (--manifest STORY.json | --archive A.wprgo)
                                              [--tabs 30] [--runs 2] [--out DIR]

Chrome's Telemetry replays its recorded pages the same way: it starts `wpr replay` on free ports and reads them from
the "Starting server on" lines (catapult telemetry/internal/util/webpagereplay_go_server.py), then launches Chrome with
--host-resolver-rules to those ports and --ignore-certificate-errors-spki-list with the replay certificate's key
(telemetry/internal/backends/chrome/chrome_startup_args.py, web_page_replay_go/README.md).

The two switches reach only the bench app: they go in its launch environment as CMUX_NEXT_BENCH_CEF_SWITCHES (task 221;
CEFSwitches keeps only this pair, and only for a development or bench bundle of a Debug or bench build), never in this
process's environment, and a run refuses a shipped bundle id, which would ignore them and load the live sites. The
rules also map every other host and port to ~NOTFOUND, so a request the archive cannot answer fails instead of
reaching the network.

record   (a lab host in pool.json only) `wpr record` while a fresh bench app opens each URL of URLS.txt (public https
         or http URLs, one per line: no credentials, port, query, private name or private address). It prints the
         manifest's `web_archive` ({wprgo: blob ref in the corpus cache, spki}); `manifest.py --upload` puts the blob
         in R2.
verify   `wpr replay` of the archive (a manifest's web_archive, fetched into the cache, or --archive), RUNS times: each
         run launches a fresh bench app with an empty Chromium root (no HTTP cache), checks debug.cef (Chromium is
         available), opens TABS tabs round-robin over URLS.txt and waits for each page (browser.page.wait, then
         debug.browser.page_status: no error page, certificate warning or sad tab). It passes when every run served
         from the archive with 0 network misses and 0 TLS handshake errors and every run loaded the same number of
         pages, all of them. A record launch starts with an empty Chromium root too, so no cached subresource is
         left out of the archive.

wpr is the build host-setup.sh makes, at pool.json's commit, in ~/Library/Application Support/cmux-perf-lab/wpr/<commit>
(--wpr DIR for another). Prints WPR-* lines; --out DIR gets the wpr logs, the app logs and wpr-<mode>.json.
Exit 0 on success, 1 when a check fails, 2 for a usage error.

Stdlib only. Tests: python3 -m unittest scripts/perf-lab/tests/test_corpus_wpr.py
"""
from __future__ import annotations

import argparse
import ast
import base64
import dataclasses
import hashlib
import importlib.util
import ipaddress
import json
import os
import pwd
import re
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import uuid
from collections.abc import Callable, Iterable, Mapping
from pathlib import Path
from typing import Any
from urllib.parse import urlsplit

HERE = Path(__file__).resolve().parent
LAB = HERE.parent
REPO_ROOT = LAB.parents[1]
POOL_PATH = LAB / "pool.json"
BENCH_LAUNCH = REPO_ROOT / "scripts" / "cmux-next" / "bench_launch.py"
BENCH_SWITCHES_ENV = "CMUX_NEXT_BENCH_CEF_SWITCHES"
# CEFSwitches.benchSwitchNames: the only switches a bench app takes from BENCH_SWITCHES_ENV.
BENCH_SWITCH_NAMES = ("host-resolver-rules", "ignore-certificate-errors-spki-list")
WPR_FILES = ("wpr", "wpr_cert.pem", "wpr_key.pem", "deterministic.js")
# Names that are never a public site; .ts.net is the tailnet.
PRIVATE_SUFFIXES = (".localhost", ".local", ".internal", ".test", ".example", ".invalid", ".lan", ".home", ".corp",
                    ".home.arpa", ".ts.net")
# Hibernation and freezing off, so every opened tab keeps its page and its requests during the run.
APP_CONFIG = {"browser": {"hibernation": "off", "freezeHiddenTabs": "off", "keepNeighborTabsAwake": 0}}

# wpr.go logServeStarted prints this with fmt.Printf ("parsed by downstream tools like catapult and crossbench").
STARTING = re.compile(r"Starting server on (?P<scheme>https?)://(?P<host>[^\s:]*):(?P<port>\d+)")
# Every other wpr line is log/slog text (src/webpagereplay/log.go makeHandler): `key=value` pairs, a value in Go
# quotes when it has a space, `=`, `"` or a control character. proxy.go logs each request with its `url` attribute
# (makeLogger) and one of these messages.
SLOG_ATTR = re.compile(r'(?:^|(?<=\s))(?P<key>[^\s="]+)=(?P<value>"(?:[^"\\]|\\.)*"|[^\s"]*)')
SERVED_MSG = "Proxy: SERVING response"
MISSED_MSG = "Proxy: FAILED to find request"
# net/http's server error log (the standard log package, not slog): the app refused the certificate.
TLS_ERROR = re.compile(r"TLS handshake error")


class WprError(RuntimeError):
    pass


def _load(path: Path, name: str):
    if name not in sys.modules:
        spec = importlib.util.spec_from_file_location(name, path)
        module = importlib.util.module_from_spec(spec)
        sys.modules[name] = module
        spec.loader.exec_module(module)
    return sys.modules[name]


# ---------------------------------------------------------------- wpr build, certificate and switches

def wpr_commit(pool_path: Path = POOL_PATH) -> str:
    return json.loads(pool_path.read_text(encoding="utf-8"))["wpr"]["commit"]


def default_wpr_dir(commit: str, home: Path | None = None) -> Path:
    """Where host-setup.sh builds wpr for the bench user (its check_wpr item)."""
    return (home or Path.home()) / "Library" / "Application Support" / "cmux-perf-lab" / "wpr" / commit


def checked_wpr_dir(directory: Path, commit: str) -> Path:
    """DIRECTORY when it holds host-setup.sh's wpr build of COMMIT with its certificate, key and script."""
    missing = [name for name in WPR_FILES if not (directory / name).is_file()]
    if missing:
        raise WprError(f"{directory}: no {', '.join(missing)}; run scripts/perf-lab/host-setup.sh on this host")
    if not os.access(directory / "wpr", os.X_OK):
        raise WprError(f"{directory}/wpr is not executable")
    stamp = directory / ".cmux-perf-lab-commit"
    built = stamp.read_text(encoding="utf-8").strip() if stamp.is_file() else ""
    if built != commit:
        raise WprError(f"{directory}: wpr is built at {built[:12] or 'an unknown commit'}, pool.json pins {commit[:12]}")
    return directory


def _der(data: bytes, offset: int) -> tuple[int, int, int]:
    """(tag, content start, end) of the DER item at OFFSET."""
    if offset + 2 > len(data):
        raise WprError("certificate: truncated DER")
    tag, length, start = data[offset], data[offset + 1], offset + 2
    if length & 0x80:
        count = length & 0x7F
        if count == 0 or count > 4 or start + count > len(data):
            raise WprError("certificate: bad DER length")
        length, start = int.from_bytes(data[start:start + count], "big"), start + count
    if start + length > len(data):
        raise WprError("certificate: truncated DER")
    return tag, start, start + length


def _children(data: bytes, start: int, end: int) -> list[tuple[int, int, int, int]]:
    """(tag, item start, content start, end) of each DER item in [start, end)."""
    items, offset = [], start
    while offset < end:
        tag, content, stop = _der(data, offset)
        items.append((tag, offset, content, stop))
        offset = stop
    return items


def spki_of_pem(pem: str) -> str:
    """base64(sha256(SubjectPublicKeyInfo)) of the first certificate in PEM, the value Chromium's
    --ignore-certificate-errors-spki-list takes (`openssl x509 -pubkey | openssl pkey -pubin -outform der |
    openssl dgst -sha256 -binary | base64`)."""
    match = re.search(r"-----BEGIN CERTIFICATE-----(.+?)-----END CERTIFICATE-----", pem, re.S)
    if match is None:
        raise WprError("certificate: no PEM CERTIFICATE block")
    try:
        der = base64.b64decode("".join(match.group(1).split()), validate=True)
    except ValueError as error:
        raise WprError(f"certificate: {error}") from error
    tag, start, end = _der(der, 0)
    certificate = _children(der, start, end) if tag == 0x30 else []
    if not certificate or certificate[0][0] != 0x30:
        raise WprError("certificate: not an X.509 certificate")
    tbs = _children(der, certificate[0][2], certificate[0][3])
    fields = tbs[1:] if tbs and tbs[0][0] == 0xA0 else tbs  # [0] version is optional
    # serial, signature, issuer, validity, subject, subjectPublicKeyInfo
    if len(fields) < 6 or fields[5][0] != 0x30:
        raise WprError("certificate: no SubjectPublicKeyInfo")
    _, item, _, stop = fields[5]
    return base64.b64encode(hashlib.sha256(der[item:stop]).digest()).decode("ascii")


def bench_switches(http_port: int, https_port: int, spki: str) -> str:
    """CMUX_NEXT_BENCH_CEF_SWITCHES for a bench app over wpr's ports: one `name=value` per line. Port 80 and 443 of
    every host go to wpr, every other host and port to ~NOTFOUND (HostMappingRules: exclusions first, then the first
    MAP that matches), so nothing reaches the network; the app's own loopback stays direct."""
    rules = ",".join([f"MAP *:80 127.0.0.1:{http_port}", f"MAP *:443 127.0.0.1:{https_port}", "MAP * ~NOTFOUND",
                      "EXCLUDE localhost", "EXCLUDE 127.0.0.1"])
    return f"host-resolver-rules={rules}\nignore-certificate-errors-spki-list={spki}"


def kept_bench_switches(value: str) -> list[str]:
    """What CEFSwitches.benchSwitches keeps of VALUE (its rule, for the tests): a line whose name is allowed and that
    has a value."""
    kept = []
    for line in value.splitlines():
        line = line.lstrip("-")
        name, equals, rest = line.partition("=")
        if equals and rest and name in BENCH_SWITCH_NAMES:
            kept.append(line)
    return kept


def refuse_leaked_switches(environ: Mapping[str, str] = os.environ) -> None:
    """The switches go to the bench app only, never to a shell or the lab runner (every app started from there would
    load through wpr), so a run refuses an environment that already has the variable."""
    if BENCH_SWITCHES_ENV in environ:
        raise WprError(f"{BENCH_SWITCHES_ENV} is set in this environment; unset it: wpr.py gives it to the bench app only")


def bench_env(switches: str, environ: Mapping[str, str] = os.environ) -> dict[str, str]:
    """The env a BenchApp gets for SWITCHES (``refuse_leaked_switches`` first)."""
    refuse_leaked_switches(environ)
    return {BENCH_SWITCHES_ENV: switches}


def bench_bundle_problem(identifier: str | None) -> str | None:
    """Why the bundle would ignore the switches (CEFSwitches.current: `.debug` in the id or a `.dev` suffix)."""
    identifier = identifier or ""
    if ".debug" in identifier or identifier.endswith(".dev"):
        return None
    return (f"bundle id {identifier or '(none)'} is not a development or bench bundle; it ignores {BENCH_SWITCHES_ENV} "
            "and would load the live sites (build one with scripts/reload.sh --config bench --tag TAG)")


# ---------------------------------------------------------------- public URLs and the lab host

def read_urls(text: str) -> list[str]:
    """The URLs of a URL list: one per line; blank lines and # comments are skipped. A URL twice is refused."""
    urls = [line.strip() for line in text.splitlines() if line.strip() and not line.strip().startswith("#")]
    seen, twice = set(), []
    for url in urls:
        if url in seen:
            twice.append(url)
        seen.add(url)
    if twice:
        raise WprError(f"the URL list names {', '.join(sorted(set(twice)))} more than once")
    if not urls:
        raise WprError("the URL list is empty")
    return urls


def resolve(host: str) -> list[str]:
    try:
        return sorted({info[4][0] for info in socket.getaddrinfo(host, None, proto=socket.IPPROTO_TCP)})
    except OSError as error:
        raise WprError(f"{host}: {error}") from error


def public_url_problem(url: str, resolver: Callable[[str], list[str]] = resolve) -> str | None:
    """Why URL is not a public page to record, or None. Fails closed: an http(s) URL of a public DNS name on its
    default port, with no credentials, query or fragment, whose every address is global."""
    try:
        parts = urlsplit(url)
        port = parts.port
    except ValueError as error:
        return f"{url}: {error}"
    host = (parts.hostname or "").rstrip(".")
    if parts.scheme not in ("http", "https"):
        return f"{url}: not http or https"
    if parts.username is not None or parts.password is not None:
        return f"{url}: has credentials"
    if port is not None:
        return f"{url}: has a port; only the default port is recorded"
    if parts.query or parts.fragment or "?" in url or "#" in url:
        return f"{url}: has a query or fragment (it may carry a token); record the plain page"
    try:
        ipaddress.ip_address(host.strip("[]"))
        return f"{url}: an address, not a public name"
    except ValueError:
        pass
    if "." not in host or host == "localhost" or host.endswith(PRIVATE_SUFFIXES):
        return f"{url}: {host or '(no host)'} is not a public name"
    try:
        addresses = resolver(host)
    except WprError as error:
        return f"{url}: does not resolve ({error})"
    private = [address for address in addresses if not ipaddress.ip_address(address.split("%")[0]).is_global]
    if not addresses or private:
        return f"{url}: {host} resolves to a non-public address {', '.join(private) or '(none)'}"
    return None


def host_names() -> list[str]:
    """This Mac's names: its host name and, on macOS, LocalHostName and ComputerName (scutil)."""
    names = [socket.gethostname().split(".")[0]]
    if sys.platform == "darwin":
        for key in ("LocalHostName", "ComputerName"):
            out = subprocess.run(["/usr/sbin/scutil", "--get", key], capture_output=True, text=True, timeout=10)
            if out.returncode == 0 and out.stdout.strip():
                names.append(out.stdout.strip())
    return names


def lab_host_problem(names: Iterable[str], pool_path: Path = POOL_PATH) -> str | None:
    """Why this is not a pool.json lab host (record runs only there), or None."""
    pool = json.loads(pool_path.read_text(encoding="utf-8"))
    lab = {host["name"].lower() for host in pool["hosts"]}
    names = list(names)
    if any(name.lower() in lab for name in names):
        return None
    return f"record runs on a lab host of {pool_path.name} ({', '.join(sorted(lab))}); this is {', '.join(names)}"


# ---------------------------------------------------------------- the wpr server and its log

@dataclasses.dataclass
class ReplayLog:
    served: int
    misses: list[str]
    tls_errors: list[str]

    @property
    def report(self) -> dict[str, Any]:
        return {"served": self.served, "misses": len(self.misses), "miss_urls": sorted(set(self.misses)),
                "tls_errors": len(self.tls_errors), "tls_error_lines": self.tls_errors[:20]}


def slog_attrs(line: str) -> dict[str, str]:
    """The `key=value` pairs of one slog text line, quoted values unquoted (Go's escapes are Python's)."""
    attrs = {}
    for match in SLOG_ATTR.finditer(line):
        value = match.group("value")
        if value.startswith('"'):
            try:
                value = ast.literal_eval(value)
            except (SyntaxError, ValueError):
                value = value[1:-1]
        attrs.setdefault(match.group("key"), value)
    return attrs


def parse_log(text: str) -> ReplayLog:
    """What a `wpr replay` log says about the requests it answered (proxy.go ReplayingProxy.ServeHTTP):
    msg="Proxy: SERVING response" (a hit), msg="Proxy: FAILED to find request" (a miss: the page asked for what the
    archive does not hold), each with the request's url=, and the TLS handshake errors of its HTTPS server (the app
    refused the certificate)."""
    served, misses, tls = 0, [], []
    for line in text.splitlines():
        if TLS_ERROR.search(line):
            tls.append(line.strip())
            continue
        attrs = slog_attrs(line)
        if attrs.get("msg") == SERVED_MSG:
            served += 1
        elif attrs.get("msg") == MISSED_MSG:
            misses.append(attrs.get("url") or "(no url)")
    return ReplayLog(served, misses, tls)


def wpr_argv(directory: Path, mode: str, archive: Path) -> list[str]:
    """wpr on free loopback ports, with the build's certificate, key and deterministic.js, as Telemetry runs it. The
    pinned wpr.go takes urfave/cli v2 flags, whose names have hyphens (CommonConfig.Flags)."""
    return [str(directory / "wpr"), mode, "--host=127.0.0.1", "--http-port=0", "--https-port=0",
            f"--https-cert-file={directory / 'wpr_cert.pem'}", f"--https-key-file={directory / 'wpr_key.pem'}",
            f"--inject-scripts={directory / 'deterministic.js'}", str(archive)]


class WprServer:
    """One `wpr record` or `wpr replay` process. Its output goes to LOG_PATH; `http_port` and `https_port` are the
    ports it printed. `stop()` sends SIGINT, which makes `wpr record` write the archive, and waits for the exit."""

    def __init__(self, directory: Path, mode: str, archive: Path, log_path: Path, *, ready_timeout_s: float = 60,
                 stop_timeout_s: float = 120, argv: list[str] | None = None):
        if mode not in ("record", "replay"):
            raise WprError(f"wpr mode {mode!r} is not record or replay")
        self.mode, self.archive, self.log_path = mode, Path(archive), Path(log_path)
        self.argv = argv or wpr_argv(directory, mode, self.archive)
        self.cwd = directory
        self.ready_timeout_s, self.stop_timeout_s = ready_timeout_s, stop_timeout_s
        self.ports: dict[str, int] = {}
        self.process: subprocess.Popen | None = None
        self.returncode: int | None = None
        self._settled = threading.Event()  # both ports printed, or the output ended
        self._reader: threading.Thread | None = None

    @property
    def http_port(self) -> int:
        return self.ports["http"]

    @property
    def https_port(self) -> int:
        return self.ports["https"]

    def __enter__(self) -> WprServer:
        self.start()
        return self

    def __exit__(self, *_exc) -> None:
        self.stop()

    def start(self) -> None:
        if self.mode == "replay" and not self.archive.is_file():
            raise WprError(f"{self.archive}: no archive to replay")
        self.log_path.parent.mkdir(parents=True, exist_ok=True)
        environ = {key: value for key, value in os.environ.items() if key != BENCH_SWITCHES_ENV}
        self.process = subprocess.Popen(self.argv, cwd=self.cwd, env=environ, stdin=subprocess.DEVNULL,
                                        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, errors="replace",
                                        start_new_session=True)
        self._reader = threading.Thread(target=self._read, name=f"wpr-{self.mode}-log", daemon=True)
        self._reader.start()
        if not self._settled.wait(self.ready_timeout_s) or set(self.ports) != {"http", "https"}:
            self.stop()
            raise WprError(f"wpr {self.mode} printed no http and https ports within {self.ready_timeout_s:.0f} s "
                           f"(exit {self.returncode}): {self.tail()}")

    def _read(self) -> None:
        with self.log_path.open("w", encoding="utf-8") as log:
            for line in self.process.stdout:
                log.write(line)
                log.flush()
                match = STARTING.search(line)
                if match and not self._settled.is_set():
                    self.ports[match.group("scheme")] = int(match.group("port"))
                    if set(self.ports) == {"http", "https"}:
                        self._settled.set()
        self._settled.set()

    def stop(self) -> int | None:
        if self.process is None:
            return self.returncode
        if self.process.poll() is None:
            self.process.send_signal(signal.SIGINT)
            try:
                self.process.wait(self.stop_timeout_s)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()
        if self._reader is not None:
            self._reader.join()
        self.process.stdout.close()
        self.returncode = self.process.returncode
        self.process = None
        return self.returncode

    def log_text(self) -> str:
        return self.log_path.read_text(encoding="utf-8", errors="replace") if self.log_path.is_file() else ""

    def tail(self, lines: int = 8) -> str:
        return " | ".join(self.log_text().splitlines()[-lines:]) or "(no output)"


# ---------------------------------------------------------------- the app's pages

def cef_problem(cef: Any) -> str | None:
    """Why debug.cef says Chromium cannot show the pages (its error, `unavailable` or a WebKit `fallback`), or None."""
    if not isinstance(cef, dict) or not cef:
        return "debug.cef did not answer"
    if cef.get("error"):
        return f"debug.cef: {cef['error']}"
    if cef.get("unavailable"):
        return f"Chromium is unavailable: {json.dumps(cef['unavailable'])[:200]}"
    if cef.get("fallback"):
        return f"tabs fell back to WebKit: {json.dumps(cef['fallback'])[:200]}"
    return None


def page_problem(status: Any) -> str | None:
    """Why debug.browser.page_status says the page did not load: an error page, certificate warning, the engine's
    own error page or the sad tab. None for a loaded page."""
    if not isinstance(status, dict) or "certificate" not in status:  # a refusal, or no such tab
        return f"debug.browser.page_status: {json.dumps(status)[:200]}"
    if status.get("certificate") == "1":
        return "certificate warning (the spki switch did not apply)"
    if status.get("enginePage") == "1":
        return "Chromium's error page"
    if status.get("gone") == "1":
        return "sad tab"
    if status.get("error"):
        return f"error page: {status['error'][:200]}"
    return None


class AppPages:
    """The Chromium tabs of a launched app, through its control socket (`rpc(method, params, timeout)` returns the
    result or {"error": ...}, as BenchApp.rpc does)."""

    def __init__(self, rpc: Callable[..., Any]):
        self._rpc = rpc

    def cef(self) -> Any:
        return self._rpc("debug.cef", {}, timeout=30)

    def open(self, url: str) -> tuple[str | None, str | None]:
        """(tab id, None) of a new foreground Chromium tab at URL, or (None, why)."""
        answer = self._rpc("action.run", {"action": "openBrowser.chromium", "args": {"url": url}, "wait": True,
                                          "origin": "script", "focus": True,
                                          "idempotency_key": f"mutation_{uuid.uuid4().hex}"}, timeout=120)
        answer = answer if isinstance(answer, dict) else {"error": repr(answer)}
        created = [str(item) for item in answer.get("created") or [] if str(item).startswith("tab_")]
        if answer.get("error") or not created:
            return None, str(answer.get("error") or answer)[:200]
        return created[0], None

    def load(self, tab: str, timeout_ms: int) -> str | None:
        """None once the tab's document is complete and nothing covers it; else why not."""
        waited = self._rpc("browser.page.wait", {"tab": tab, "load_state": "complete", "timeout_ms": timeout_ms},
                           timeout=timeout_ms / 1000 + 10)
        status = self._rpc("debug.browser.page_status", {"tab": tab}, timeout=30)
        problem = page_problem(status)
        if problem is None and isinstance(waited, dict) and waited.get("error"):
            problem = f"not complete in {timeout_ms} ms: {str(waited['error'])[:200]}"
        return problem


def load_pages(pages: Any, urls: list[str], tabs: int, timeout_ms: int) -> list[dict[str, Any]]:
    """Opens TABS tabs round-robin over URLS, one after another, each loaded before the next opens."""
    rows = []
    for index in range(tabs):
        url = urls[index % len(urls)]
        tab, problem = pages.open(url)
        if tab is not None:
            problem = pages.load(tab, timeout_ms)
        rows.append({"index": index, "url": url, "tab": tab, "loaded": problem is None, "problem": problem})
        print(f"WPR-PAGE index={index} loaded={int(problem is None)} url={url}" + (f" problem={problem}" if problem else ""),
              flush=True)
    return rows


# ---------------------------------------------------------------- the app's Chromium storage

def account_home() -> Path:
    """The home the app resolves (bench_launch.account_home): the password database's."""
    try:
        return Path(pwd.getpwuid(os.getuid()).pw_dir)
    except KeyError:
        return Path.home()


def chromium_root(bundle: str, home: Path | None = None) -> Path:
    """CEFProfileStorage.forApplication's root_cache_path of BUNDLE: `<Application Support>/<bundle id>/Chromium`,
    which holds every profile's HTTP cache, cookies and service workers. BenchApp.start_fresh does not reach it."""
    return (home or account_home()) / "Library" / "Application Support" / bundle / "Chromium"


def empty_chromium_root(root: Path) -> None:
    """Moves ROOT aside to `<root>.wpr-prev` (the older one removed), as start_fresh does with the tag state, so the
    next launch has no HTTP cache: a cached subresource would never reach `wpr record` (the archive would lack it)
    or `wpr replay` (a second run would not go through wpr)."""
    if os.path.lexists(root):
        prev = root.with_name(root.name + ".wpr-prev")
        if os.path.lexists(prev):
            shutil.rmtree(prev, ignore_errors=True)
        os.rename(root, prev)
    if os.path.lexists(root):
        raise WprError(f"{root}: could not move the Chromium storage aside")


# ---------------------------------------------------------------- one run and the verdict

@dataclasses.dataclass
class RunPlan:
    wpr_dir: Path
    app: str
    urls: list[str]
    tabs: int
    spki: str
    out: Path
    chromium_root: Path  # the bench app's Chromium storage, emptied before each launch (empty_chromium_root)
    load_timeout_ms: int = 60_000
    settle_s: float = 5.0


def run_once(plan: RunPlan, mode: str, archive: Path, label: str, launch: Callable[[dict[str, str], Path], Any],
             server_factory: Callable[..., WprServer] = WprServer) -> dict[str, Any]:
    """wpr in MODE, a fresh bench app with the switches and an empty Chromium root (`launch(env, out)` returns a
    started app with `rpc`, `launched_env` and `stop`), the pages, then the app and wpr stop. Returns the run's
    report."""
    log_path = plan.out / f"wpr-{label}.log"
    report: dict[str, Any] = {"label": label, "mode": mode, "wpr_log": str(log_path), "tabs": plan.tabs,
                              "chromium_root": str(plan.chromium_root)}
    empty_chromium_root(plan.chromium_root)
    with server_factory(plan.wpr_dir, mode, archive, log_path) as server:
        switches = bench_switches(server.http_port, server.https_port, plan.spki)
        report["ports"] = dict(server.ports)
        app = launch(bench_env(switches), plan.out / label)
        try:
            if (getattr(app, "launched_env", None) or {}).get(BENCH_SWITCHES_ENV) != switches:
                raise WprError("the bench app was not launched with the WPR switches")
            pages = AppPages(app.rpc)
            cef = pages.cef()
            report["cef"] = {key: cef.get(key) for key in ("state", "backend", "trigger")} if isinstance(cef, dict) else cef
            report["cef_problem"] = cef_problem(cef)
            rows = [] if report["cef_problem"] else load_pages(pages, plan.urls, plan.tabs, plan.load_timeout_ms)
            if rows and plan.settle_s > 0:
                time.sleep(plan.settle_s)  # bench script: the pages' late requests reach wpr before it stops
        finally:
            app.stop()
    report["wpr_exit"] = server.returncode
    report["pages"] = rows
    report["loaded"] = sum(1 for row in rows if row["loaded"])
    if mode == "replay":
        report.update(parse_log(server.log_text()).report)
    return report


def verify_problems(runs: list[dict[str, Any]]) -> list[str]:
    """Why the replay runs fail task 113's acceptance (0 network misses, the same page count), or []."""
    problems = []
    for run in runs:
        label = run["label"]
        if run.get("cef_problem"):
            problems.append(f"{label}: {run['cef_problem']}")
        if run.get("misses"):
            problems.append(f"{label}: {run['misses']} network misses: {', '.join(run['miss_urls'][:10])}")
        if run.get("tls_errors"):
            problems.append(f"{label}: {run['tls_errors']} TLS handshake errors (the spki switch did not apply)")
        if not run.get("served"):
            problems.append(f"{label}: wpr served nothing (the host-resolver-rules switch did not apply)")
        if run["loaded"] != run["tabs"]:
            failed = [f"{row['url']} ({row['problem']})" for row in run["pages"] if not row["loaded"]][:5]
            problems.append(f"{label}: {run['loaded']} of {run['tabs']} pages loaded: {'; '.join(failed)}")
    if len({run["loaded"] for run in runs}) > 1:
        problems.append(f"page counts differ between runs: {[run['loaded'] for run in runs]}")
    return problems


def record_problems(run: dict[str, Any], archive: Path) -> list[str]:
    problems = [f"{run['label']}: {run['cef_problem']}"] if run.get("cef_problem") else []
    if run["loaded"] != run["tabs"]:
        failed = [f"{row['url']} ({row['problem']})" for row in run["pages"] if not row["loaded"]][:5]
        problems.append(f"{run['loaded']} of {run['tabs']} pages loaded: {'; '.join(failed)}")
    if run.get("wpr_exit") != 0:
        problems.append(f"wpr record exited {run.get('wpr_exit')}")
    if not archive.is_file() or archive.stat().st_size == 0:
        problems.append(f"{archive}: wpr record wrote no archive")
    return problems


# ---------------------------------------------------------------- CLI

def bench_launcher(app: str, build_config: str | None) -> Callable[[dict[str, str], Path], Any]:
    """`launch(env, out)` with a fresh BenchApp of APP (its scratch config, an empty saved session)."""
    bench_launch = _load(BENCH_LAUNCH, "perf_lab_bench_launch")

    def launch(env: dict[str, str], out: Path) -> Any:
        if os.environ.get("CI_JOB_DIR"):
            env = {**env, "CI_JOB_DIR": os.environ["CI_JOB_DIR"]}  # the fleet worker finds the step's processes
        bench = bench_launch.BenchApp(app, out=str(out), env=env, config=APP_CONFIG, build_config=build_config)
        try:
            bench.launch()
        except BaseException:
            bench.stop()
            raise
        return bench

    return launch


def archive_of(args: argparse.Namespace) -> tuple[Path, str | None]:
    """The archive to replay and the spki its story names (None for --archive)."""
    if args.archive:
        return args.archive, None
    manifest_module = _load(HERE / "manifest.py", "perf_lab_corpus_manifest")
    manifest = json.loads(args.manifest.read_text(encoding="utf-8"))
    web = manifest.get("web_archive") or {}
    if not web.get("wprgo") or not web.get("spki"):
        raise WprError(f"{args.manifest}: web_archive has no recorded wprgo and spki")
    cache = manifest_module.BlobCache(args.cache or manifest_module.default_cache_dir(), manifest_module.http_fetcher())
    try:
        cache.get(web["wprgo"])
    except manifest_module.CorpusError as error:
        raise WprError(str(error)) from error
    return cache.path(web["wprgo"]), web["spki"]


def parse(argv: list[str] | None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = parser.add_subparsers(dest="mode", required=True)
    spki = sub.add_parser("spki", help="print the spki of the wpr build's certificate")
    record = sub.add_parser("record", help="record URLS into an archive (lab host, public URLs)")
    verify = sub.add_parser("verify", help="replay an archive and check 0 network misses")
    for each in (spki, record, verify):
        each.add_argument("--wpr", type=Path, default=None, help="the wpr build (default: host-setup.sh's)")
    for each in (record, verify):
        each.add_argument("--app", required=True, help="a tagged development or bench build")
        each.add_argument("--tag", default=None, help="the lab runner's tag (unused; the app names its tag)")
        each.add_argument("--urls", type=Path, required=True, help="the page list, one public URL per line")
        each.add_argument("--out", type=Path, default=None)
        each.add_argument("--build-config", default=None, help="bench or bench-checks (BenchApp build_config)")
        each.add_argument("--load-timeout-ms", type=int, default=60_000)
        each.add_argument("--settle", type=float, default=5.0, help="seconds after the last page before wpr stops")
    record.add_argument("--archive", type=Path, required=True, help="the .wprgo to write")
    record.add_argument("--cache", type=Path, default=None, help="the corpus blob cache (manifest.py's default)")
    source = verify.add_mutually_exclusive_group(required=True)
    source.add_argument("--manifest", type=Path, help="a corpus story with a recorded web_archive")
    source.add_argument("--archive", type=Path, help="a .wprgo file")
    verify.add_argument("--cache", type=Path, default=None, help="the corpus blob cache (manifest.py's default)")
    verify.add_argument("--tabs", type=int, default=30)
    verify.add_argument("--runs", type=int, default=2)
    args = parser.parse_args(argv)
    if getattr(args, "tabs", 1) < 1 or getattr(args, "runs", 2) < 2:
        parser.error("--tabs is at least 1 and --runs at least 2 (the page count is compared across runs)")
    return args


def main(argv: list[str] | None = None) -> int:
    args = parse(argv)
    try:
        wpr_dir = checked_wpr_dir(args.wpr or default_wpr_dir(wpr_commit()), wpr_commit())
        spki = spki_of_pem((wpr_dir / "wpr_cert.pem").read_text(encoding="utf-8"))
        if args.mode == "spki":
            print(spki)
            return 0
        if sys.platform != "darwin":
            raise WprError(f"wpr.py {args.mode} launches the app: run it on a lab Mac")
        refuse_leaked_switches()
        bench_launch = _load(BENCH_LAUNCH, "perf_lab_bench_launch")
        bundle = bench_launch.bundle_id(args.app)
        problem = bench_bundle_problem(bundle)
        if problem:
            raise WprError(problem)
        urls = read_urls(args.urls.read_text(encoding="utf-8"))
        out = Path(args.out or tempfile.mkdtemp(prefix=f"wpr-{args.mode}-")).resolve()
        out.mkdir(parents=True, exist_ok=True)
        launch = bench_launcher(args.app, args.build_config)
        if args.mode == "record":
            return record(args, wpr_dir, spki, urls, out, chromium_root(bundle), launch)
        return verify(args, wpr_dir, spki, urls, out, chromium_root(bundle), launch)
    except (WprError, OSError, ValueError, KeyError) as error:
        print(f"WPR-ERROR {error}", file=sys.stderr)
        return 1


def record(args, wpr_dir: Path, spki: str, urls: list[str], out: Path, root: Path, launch) -> int:
    problems = [problem for problem in [lab_host_problem(host_names())] + [public_url_problem(url) for url in urls]
                if problem]
    if problems:
        raise WprError("; ".join(problems))
    archive = args.archive.resolve()
    if archive.exists():
        raise WprError(f"{archive} exists; record into a new file")
    plan = RunPlan(wpr_dir, args.app, urls, len(urls), spki, out, root, args.load_timeout_ms, args.settle)
    run = run_once(plan, "record", archive, "record", launch)
    problems = record_problems(run, archive)
    report = {"run": run, "problems": problems}
    if not problems:
        manifest_module = _load(HERE / "manifest.py", "perf_lab_corpus_manifest")
        cache = manifest_module.BlobCache(args.cache or manifest_module.default_cache_dir(), manifest_module.http_fetcher())
        report["web_archive"] = {"wprgo": cache.add(archive.read_bytes()), "spki": spki}
        report["urls"] = urls
    (out / "wpr-record.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    for problem in problems:
        print(f"WPR-RECORD FAIL {problem}", flush=True)
    if problems:
        return 1
    print(f"WPR-RECORD ok pages={run['loaded']} bytes={report['web_archive']['wprgo']['bytes']} "
          f"web_archive={json.dumps(report['web_archive'])}", flush=True)
    return 0


def verify(args, wpr_dir: Path, spki: str, urls: list[str], out: Path, root: Path, launch) -> int:
    archive, story_spki = archive_of(args)
    if story_spki is not None and story_spki != spki:
        raise WprError(f"the story's spki {story_spki} is not this wpr build's certificate {spki}: its archive was "
                       "recorded with another wpr commit; record it again")
    plan = RunPlan(wpr_dir, args.app, urls, args.tabs, spki, out, root, args.load_timeout_ms, args.settle)
    runs = []
    for index in range(args.runs):
        run = run_once(plan, "replay", archive, f"replay-{index + 1}", launch)
        runs.append(run)
        print(f"WPR-VERIFY run={index + 1} pages={run['loaded']}/{run['tabs']} served={run.get('served')} "
              f"misses={run.get('misses')} tls_errors={run.get('tls_errors')}", flush=True)
    problems = verify_problems(runs)
    report = {"archive": str(archive), "spki": spki, "urls": urls, "runs": runs, "problems": problems,
              "ok": not problems}
    (out / "wpr-verify.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    for problem in problems:
        print(f"WPR-VERIFY FAIL {problem}", flush=True)
    if problems:
        return 1
    print(f"WPR-VERIFY ok runs={len(runs)} pages={runs[0]['loaded']} misses=0", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
