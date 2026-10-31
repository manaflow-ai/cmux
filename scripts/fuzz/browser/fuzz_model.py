"""Browser fuzz (fuzz catalog row k): the pure part. No app, no socket, no clock.

browser_fuzz.py drives a tagged cmux-next app with the ops this module generates and judges what
it reads back with the oracles here, so the generator, the oracles and the shrinker are tested on
any machine (test_fuzz_model.py) and a saved repro replays the same ops.

An op is a JSON object {"op": NAME, ...}. Ops name tabs by slot (an index into the run's live
Chromium tabs, taken modulo their count when the op runs), never by id, so any subsequence of a run
is still a runnable run: the shrinker removes ops freely.
"""
from __future__ import annotations

import random
import urllib.parse

# A page script that ran from a javascript: or data: URL sets this title. It must never show.
CANARY = "FUZZPWNED"

# Schemes an agent-driven tab never shows (AgentURLPolicy.refusedSchemes, wrappers aside).
AGENT_REFUSED_SCHEMES = {"chrome", "chrome-extension", "chrome-untrusted", "chrome-search", "devtools",
                         "chrome-devtools", "view-source", "cmux"}
# Schemes that run or embed content from the URL itself: no tab may commit one from typed or agent text
# (BrowserURLResolver searches them) or from a redirect (Chromium blocks it).
SCRIPT_SCHEMES = {"javascript", "data", "vbscript"}
# Schemes a web page (http/https content) may never reach as a top-level navigation by itself.
WEB_UNREACHABLE = SCRIPT_SCHEMES | {"file"} | AGENT_REFUSED_SCHEMES

STALL_MS = 100.0


def scheme_of(url: str) -> str:
    """The URL's scheme, lowercased, as Chromium reads it (leading spaces and controls, tabs and
    newlines dropped); "" when the text has none."""
    cleaned = "".join(ch for ch in url if ch not in "\t\n\r").lstrip("".join(chr(c) for c in range(0x21)))
    head, sep, _ = cleaned.partition(":")
    if not sep or not head or not head[0].isascii() or not head[0].isalpha():
        return ""
    if not all(ch.isascii() and (ch.isalnum() or ch in "+-.") for ch in head):
        return ""
    return head.lower()


def agent_refuses(url: str, depth: int = 0) -> bool:
    """AgentURLPolicy.refuses, for the harness: whether an agent-driven tab may not show `url`."""
    if depth > 2:
        return True
    scheme = scheme_of(url)
    if not scheme:
        return False
    rest = url.split(":", 1)[1]
    if scheme in AGENT_REFUSED_SCHEMES:
        return True
    if scheme in ("blob", "filesystem"):
        return agent_refuses(rest, depth + 1)
    if scheme == "cmux-page":
        host = rest.lstrip("/\\").split("/")[0].split("?")[0].split("#")[0].split("@")[-1].split(":")[0].lower().rstrip(".")
        return "%" in host or not host or host == "cmux" or host.startswith("cmux.") or "." not in host
    if scheme == "about":
        page = rest.split("?")[0].split("#")[0].lower()
        return page not in ("blank", "srcdoc")
    return False


# ---------------------------------------------------------------- URL corpus

def _payloads() -> dict[str, list[str]]:
    canary_js = f"document.title='{CANARY}'"
    canary_html = f"<title>{CANARY}</title><script>document.title='{CANARY}'</script>"
    return {
        "malformed": [
            "", " ", "http://", "https://", "://", "http:///", "http://[::1", "http://[zz::]/", "https://exa mple.test/",
            "http://%zz/", "http://a..b/", "ht!tp://x/", "http://256.256.256.256/", "http://127.0.0.1:99999/",
            "http://user:pass@127.0.0.1/", "user@example.test", "http://[fe80::1%25en0]/", "http://-x-.test/",
            "http://.test/", "http://x.test:/", "http://x.test:-1/", "http://0x7f.1/", "http://\u0000/",
            "http://a‮b.test/", "%00", "\\\\server\\share", "http:\\\\x.test\\", "javascript", "data",
        ],
        "huge": [
            "http://" + "a" * 70 + ".test/",  # a label over 63 bytes
            "http://" + ".".join(["a" * 63] * 5) + "/",  # a host over 253 bytes
            "http://127.0.0.1/?" + "q" * 70_000,
            "https://x.test/" + "/".join(["seg"] * 5000),
            "http://x.test/#" + "f" * 200_000,
        ],
        "script": [
            f"javascript:{canary_js}", f"JAVASCRIPT:{canary_js}", f"  javascript:{canary_js}", f"java\tscript:{canary_js}",
            f"javascript:javascript:{canary_js}", f"jav\nascript:{canary_js}", "javascript:void(0)",
            "data:text/html," + urllib.parse.quote(canary_html), "data:text/html;base64,PHRpdGxlPkZVWlpQV05FRDwvdGl0bGU+",
            "DATA:text/html,<title>" + CANARY + "</title>", "data:,hello", "vbscript:msgbox(1)",
        ],
        "internal": [
            "chrome://settings", "chrome://settings/passwords", "chrome://password-manager", "chrome://extensions",
            "chrome://version", "chrome://crash", "chrome://gpu", "chrome-untrusted://print/", "chrome-extension://abc/",
            "devtools://devtools/bundled/inspector.html", "view-source:http://127.0.0.1/", "about:settings", "about:version",
            "about:blank", "about:srcdoc", "blob:chrome://settings/x", "filesystem:chrome://settings/x", "cmux://history",
            "cmux://bookmarks", "cmux-page://cmux/", "cmux-page://shell/", "chrome://downloads",
        ],
        "file": ["file:///etc/hosts", "file:///", "file:///nonexistent-fuzz", "file://", "file://localhost/etc/hosts",
                 "file:///private/var/../etc/hosts", "~/", "/etc/hosts"],
        "external": ["mailto:fuzz@example.test", "tel:+15555550100", "sms:+15555550100", "x-apple.systempreferences:com.apple.preference.security",
                     "facetime:fuzz@example.test", "cmux-no-handler-fuzz:x", "intent://x#Intent;scheme=http;end", "ftp://127.0.0.1/",
                     "ws://127.0.0.1/", "itms-apps://x"],
        "idn": ["https://münchen.test/", "https://例え.テスト/", "https://аррӏе.test/",
                "https://مثال.إختبار/", "https://\U0001f600.test/", "http://xn--zz.test/",
                "http://xn--nxasmq6b.test/", "https://ß.test/", "https://faß.test/", "http://Ⓐ.test/",
                "https://x‍.test/", "https://☃.invalid/"],
    }


# Paths on the run's own server (browser_fuzz.py LocalSite): "{origin}" is filled in when the op runs.
LOCAL_PATHS = [
    "/page?id={n}", "/page?id={n}#frag", "/slow?ms={ms}", "/big?kb={kb}", "/redirect?n={k}&to=/page%3Fid%3D{n}",
    "/redirect?n=25&to=/page", "/redirect-loop", "/redirect?n=1&to={unsafe}", "/meta?to={unsafe}", "/script-nav?to={unsafe}",
    "/status?code={code}", "/popups?n={k}", "/history?n={k}", "/beforeunload", "/download?kb={kb}&name={name}",
]
UNSAFE_REDIRECT_TARGETS = ["javascript:document.title='" + CANARY + "'", "data:text/html,<title>" + CANARY + "</title>",
                           "file:///etc/hosts", "chrome://settings", "view-source:http://127.0.0.1/", "about:version",
                           "mailto:fuzz@example.test", "cmux://history"]
ODD_DOWNLOAD_NAMES = ["fuzz.bin", "../../fuzz-escape.bin", "..%2F..%2Ffuzz-escape.bin", "/etc/fuzz-abs.bin", "fuzz‮gnp.exe",
                      "con.bin", "a" * 300 + ".bin", ".hidden-fuzz.bin", "fuzz\u0000nul.bin", "例え.bin", "fuzz .bin.",
                      "fuzz\r\nX-Injected: 1.bin"]


def url_for(rng: random.Random, origin: str, run: str) -> tuple[str, str]:
    """One URL for a navigation and its corpus category. Local pages are most of the corpus so the
    run stays on the mini; example.com is the one real site (the smoke gate's)."""
    roll = rng.random()
    if roll < 0.45:
        path = rng.choice(LOCAL_PATHS)
        filled = path.format(
            n=rng.randrange(1000), ms=rng.choice([0, 50, 400, 3000]), kb=rng.choice([1, 64, 1024, 8192]),
            k=rng.randrange(1, 8), code=rng.choice([204, 301, 400, 404, 418, 500, 503]),
            unsafe=urllib.parse.quote(rng.choice(UNSAFE_REDIRECT_TARGETS), safe=""),
            name=urllib.parse.quote(f"{run}-{rng.randrange(1 << 20)}-" + rng.choice(ODD_DOWNLOAD_NAMES), safe=""),
        )
        return origin + filled, "local"
    if roll < 0.48:
        return "https://example.com/", "example"
    category = rng.choice(sorted(_payloads()))
    return rng.choice(_payloads()[category]), category


# ---------------------------------------------------------------- op generator

# Op weights: navigation and opens most, then moves and closes, then the heavy ones.
WEIGHTS = {
    "open": 12, "navigate": 22, "back": 6, "forward": 4, "reload": 5, "hard_reload": 1, "stop": 1,
    "close": 6, "focus": 5, "omnibar": 6,
    "move_next_pane": 3, "move_new_split": 3, "move_workspace": 3, "move_new_workspace": 2, "move_new_window": 1,
    "new_workspace": 2, "new_window": 1,
    "open_storm": 2, "close_storm": 1, "move_storm": 2,
    "devtools": 4, "download": 4,
    "kill_renderer": 2, "crash_page": 1, "oom_page": 1,
}


def generate(seed: int, count: int, origin: str = "{origin}", run: str = "fz") -> list[dict]:
    """`count` ops from `seed`. The same seed, count and origin give the same ops."""
    rng = random.Random(seed)
    names = sorted(WEIGHTS)
    weights = [WEIGHTS[n] for n in names]
    ops: list[dict] = [{"op": "open", "url": origin + "/page?id=0", "category": "local", "settle_ms": 600}]
    while len(ops) < count:
        name = rng.choices(names, weights)[0]
        op: dict = {"op": name, "slot": rng.randrange(64), "settle_ms": rng.choice([0, 0, 50, 200, 600, 1500])}
        if name in ("open", "navigate", "omnibar"):
            op["url"], op["category"] = url_for(rng, origin, run)
        elif name == "download":
            op["kb"] = rng.choice([1, 64, 512, 4096])
            op["name"] = f"{run}-{rng.randrange(1 << 20)}-" + rng.choice(ODD_DOWNLOAD_NAMES)
        elif name == "open_storm":
            op["n"] = rng.randrange(4, 16)
        elif name in ("close_storm", "move_storm"):
            op["n"] = rng.randrange(3, 10)
            op["seeds"] = [rng.randrange(64) for _ in range(op["n"])]
        elif name == "move_workspace":
            op["to"] = rng.randrange(16)
        elif name == "move_new_split":
            op["direction"] = rng.choice(["left", "right", "up", "down"])
        elif name == "devtools":
            op["hold_ms"] = rng.choice([0, 100, 800, 2500])
        if name == "omnibar" and rng.random() < 0.15:
            # A person types a Chromium crash page (user origin: allowed; it must show a crashed page).
            op["url"], op["category"] = "chrome://crash", "crash"
        ops.append(op)
    return ops


# ---------------------------------------------------------------- oracles (pure judgements on readings)

def stalls_over(records: list[dict], limit_ms: float = STALL_MS) -> list[dict]:
    """The main-thread stalls (not busy windows or over-budget tasks) longer than `limit_ms` in a debug.hangs reading."""
    return [r for r in records or [] if r.get("kind", "stall") == "stall" and float(r.get("duration_ms") or 0) > limit_ms]


def stall_summary(record: dict, frames: int = 6) -> str:
    keep = [f for f in record.get("frames") or [] if "cmux" in f or "CmuxNext" in f or "AppKit" in f or "CEF" in f or "cef" in f]
    return f"{float(record.get('duration_ms') or 0):.0f} ms (cpu {float(record.get('cpu_ms') or 0):.0f} ms): " + \
        " < ".join((keep or record.get("frames") or [])[:frames])


def stall_signature(record: dict, depth: int = 3) -> str:
    """A stall's identity across runs: its top app frames without addresses or offsets."""
    import re
    frames = [f for f in record.get("frames") or [] if "cmux" in f or "CmuxNext" in f or "CEF" in f or "cef_" in f]
    names = [re.sub(r"0x[0-9a-f]+|\+ ?\d+|\s+", " ", f).strip() for f in (frames or record.get("frames") or [])]
    return " < ".join(names[:depth]) or "(no frames)"


def committed_url_violation(url: str, title: str, *, agent_op: bool, via_web: bool) -> str | None:
    """What is wrong with a tab that shows `url` titled `title` after an op, or None.

    agent_op: the op came through the socket (an agent or script). via_web: a page of the run's server
    sent the tab there (a redirect, a meta refresh or a page script)."""
    if title == CANARY:
        return f"a javascript:/data: payload ran (title {CANARY!r}) at {url[:200]!r}"
    scheme = scheme_of(url or "")
    if scheme in SCRIPT_SCHEMES:
        return f"the tab committed a {scheme}: URL {url[:200]!r}"
    if agent_op and agent_refuses(url or ""):
        return f"an agent-driven tab shows a page the agent policy refuses: {url[:200]!r}"
    if via_web and scheme in WEB_UNREACHABLE:
        return f"a web page took the tab to {url[:200]!r}"
    return None


def download_violation(row: dict, downloads_dir: str) -> str | None:
    """A finished download must land in the downloads folder under a plain file name."""
    destination = row.get("destination") or ""
    if not destination:
        return None
    import os.path
    real_dir = os.path.realpath(downloads_dir)
    real = os.path.realpath(destination)
    if os.path.dirname(real) != real_dir:
        return f"a download landed outside {real_dir}: {destination!r}"
    name = os.path.basename(real)
    if name.startswith(".") or "‮" in name or "\r" in name or "\n" in name or "\x00" in name:
        return f"a download kept an unsafe file name: {name!r}"
    return None


def tab_count_violation(expected: int, seen: int, closed_by_policy: int = 0) -> str | None:
    """Every Chromium tab the run opened and did not close is still in the topology."""
    if seen < expected - closed_by_policy:
        return f"{expected - seen} Chromium tab(s) went missing (expected {expected}, the topology has {seen})"
    return None


# ---------------------------------------------------------------- shrinking

def ddmin(ops: list[dict], fails, budget: int) -> tuple[list[dict], int]:
    """Delta debugging (Zeller) of `ops` with `fails(candidate) -> bool`, at most `budget` calls.
    The first op (the run's first open) always stays: it gives every later op a tab.
    Returns the smallest failing list found and the number of calls spent."""
    head, rest = ops[:1], ops[1:]
    calls = 0
    granularity = 2
    while len(rest) >= 1 and calls < budget:
        size = max(1, len(rest) // granularity)
        chunks = [rest[i:i + size] for i in range(0, len(rest), size)]
        reduced = False
        # Try each chunk alone, then each complement.
        for candidate in chunks + [[op for j, c in enumerate(chunks) if j != i for op in c] for i in range(len(chunks))]:
            if calls >= budget:
                break
            if not candidate or len(candidate) == len(rest):
                continue
            calls += 1
            if fails(head + candidate):
                rest = candidate
                granularity = max(granularity - 1, 2) if len(candidate) > size else 2
                reduced = True
                break
        if not reduced:
            if size == 1:
                break
            granularity = min(len(rest), granularity * 2)
    return head + rest, calls
