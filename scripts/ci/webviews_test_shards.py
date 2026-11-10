#!/usr/bin/env python3
"""Shard and order the webviews test files by recorded duration (run-webviews-tests.sh).

    webviews_test_shards.py assign FILES SERIAL DURATIONS SHARD COUNT [WIDTHS]  # this shard's files, NUL-separated
    webviews_test_shards.py order FILE_LIST DURATIONS asc|desc          # a NUL list, shortest or longest first
    webviews_test_shards.py order-triples TRIPLES DURATIONS desc         # xargs -n 3 triples, by their first item
    webviews_test_shards.py record LINES OUT                            # the runner's `SECONDS FILE` lines as JSON
    webviews_test_shards.py merge OUT PRIOR MEASURED...                 # the next duration manifest
    webviews_test_shards.py dev-servers FILE_LIST [--rest]              # the files that start a dev server (or the rest)
    webviews_test_shards.py vite-configs FILE_LIST                      # NUL-separated CONFIG FILE pairs: the cache each warms

The shards used to take files by index mod 4: one new file moved every file after it, and the
heavy dev-server files fell together by chance (run 40815704587 on 32 vCPU: shards of 18.6, 9.9,
12.1 and 7.7 min). Now a file with a recorded duration goes to the shard with the least load so
far, longest first (greedy longest-processing-time). A file with no recorded duration (a new one)
goes by a stable hash of its path, after the others, so it moves only itself.

Load is wall time on a shard, not CPU time: the plain files run 24 at a time beside the plain files
that drive a real browser, 8 at a time (BROWSER_MARK), then the dev-server files (SERIAL) 8 at a
time, and a `// cmux-web-test-alone` file alone (ShardPlan). WIDTHS (`PLAIN,BROWSER,DEV`) are the
pool widths the runner will use; run-webviews-tests.sh passes them only when they come from the
workflow's CMUX_WEB_TEST_JOBS (and its BROWSER and DEV overrides), never from this runner's cores,
so every shard job computes the same split even when one lands on a smaller runner. Without WIDTHS
the 32 vCPU widths below stand. The split must use the widths the runner really has: #32224 took
the shards to 8 jobs (6 plain, 2 browser, 2 dev-server at once) while the split still assumed 24, 8
and 8, so it counted the dev-server files four times too cheap and put 4 shards' worth of them on
the 4 shards without an accent-glass-invariants file: shards of 8 to 40 min, three of 64 cancelled
at the 40 min timeout (the 8 base runs to 41581500665). Each shard job must get the same FILES, SERIAL, DURATIONS and
WIDTHS: the workflow reads the manifest once (web-subarea-scope) and hands every shard that copy.

DURATIONS is a JSON object {file: seconds}; a missing or unreadable file is no durations. The
runner writes each file's first-run seconds (CMUX_WEB_TEST_DURATIONS_OUT); `merge` averages them
with the prior manifest, so one noisy run moves a file's weight by half.
"""
from __future__ import annotations

import functools
import hashlib
import json
import os
import re
from pathlib import Path
import sys

# Files at once on the 32 vCPU shard: plain files (jobs - jobs / 4) beside browser files (jobs / 4),
# then dev-server files (jobs / 4), then alone files.
PLAIN_AT_ONCE, BROWSER_AT_ONCE, DEV_AT_ONCE = 24, 8, 8
ALONE_MARK = "// cmux-web-test-alone"
# run-webviews-tests.sh's browser_files: a plain file that drives a real browser.
BROWSER_MARK = re.compile(r'from "playwright"|import\("playwright"\)|requireBrowserLane\(')


def load_durations(path: str) -> dict[str, float]:
    try:
        found = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    if not isinstance(found, dict):
        return {}
    clean = {}
    for name, seconds in found.items():
        if isinstance(seconds, (int, float)) and not isinstance(seconds, bool) and 0 <= seconds < 86400:
            clean[str(name)] = float(seconds)
    return clean


def read_nul(path: str) -> list[str]:
    return [item.decode() for item in Path(path).read_bytes().split(b"\0") if item]


def write_nul(names: list[str]) -> None:
    sys.stdout.buffer.write(b"".join(name.encode() + b"\0" for name in names))


def runs_alone(name: str) -> bool:
    try:
        with open(name, encoding="utf-8", errors="replace") as stream:
            return any(line.rstrip("\n") == ALONE_MARK for _, line in zip(range(20), stream))
    except OSError:
        return False


def runs_browser(name: str) -> bool:
    try:
        return BROWSER_MARK.search(Path(name).read_text(encoding="utf-8", errors="replace")) is not None
    except OSError:
        return False


def stable_shard(name: str, count: int) -> int:
    return int.from_bytes(hashlib.sha256(name.encode()).digest()[:8], "big") % count


# A dev-server file: one that starts a Vite dev server, whose optimizer writes dependencies into
# the config's cache directory. Two at once on one cache lose each other's files (composer-mention
# beside composer-send-stop on node_modules/.vite), so the runner gives each its own
# (CMUX_VITE_CACHE_DIR). The marks: a dev config by name, `"dev",` (the argument a file passes when it
# spawns `vp dev` itself), or Vite's createServer with a config (`configFile: …`).
DEV_SERVER_MARK = re.compile(
    r'vite\.config\.(acpmux-pane\.mjs|gallery-dev\.ts)|"dev",|configFile: path\.join\(webviews, "vite\.config')
# Vite's createServer called in a module that imports Vite: `createServer({` with any config path
# (`path.join(root, "vite.config.ts")`, `path.resolve(…)`), not only the `webviews` spelling above.
# Without it the gallery control audit's parts all took one `.vite-dev-deps-0` (port 0, no
# CMUX_VITE_CACHE_DIR) in the browser pool, two at once on one shard (#40720).
VITE_CREATE_SERVER = re.compile(r"\bcreateServer\(\{")
VITE_IMPORT = re.compile(r'from "vite"|import\("vite"\)')
# A local module a file imports (`from "./support/x"`, `import("../support/x")`, `export … from`).
LOCAL_IMPORT = re.compile(r'(?:\bfrom|\bimport\s*\(?)\s*"(\.\.?/[^"]+)"')
MODULE_SUFFIXES = ("", ".ts", ".tsx", ".mts", ".mjs", ".js", "/index.ts")


@functools.cache
def _text(path: str) -> str:
    try:
        return Path(path).read_text(encoding="utf-8", errors="replace")
    except OSError:
        return ""


@functools.cache
def _helpers_imported(path: str) -> tuple[str, ...]:
    """The test support modules PATH imports itself: files under a `test` directory that are not
    test files. Only these are followed, so a test's import of app code never makes it a
    dev-server file."""
    found = []
    for spec in LOCAL_IMPORT.findall(_text(path)):
        for suffix in MODULE_SUFFIXES:
            candidate = os.path.normpath(os.path.join(os.path.dirname(path), spec + suffix))
            if os.path.isfile(candidate):
                if "test" in Path(candidate).parts and ".test." not in os.path.basename(candidate):
                    found.append(candidate)
                break
    return tuple(found)


def _modules(name: str) -> list[str]:
    """FILE and each test support module it imports, directly or through another."""
    seen: list[str] = []
    pending = [os.path.normpath(name)]
    while pending:
        path = pending.pop()
        if path not in seen:
            seen.append(path)
            pending.extend(_helpers_imported(path))
    return seen


@functools.cache
def _module_starts_server(path: str) -> bool:
    text = _text(path)
    # Module by module: a createServer in one helper and a Vite type import in another are no server.
    return DEV_SERVER_MARK.search(text) is not None or (
        VITE_CREATE_SERVER.search(text) is not None and VITE_IMPORT.search(text) is not None)


def starts_dev_server(name: str) -> bool:
    """Whether FILE, or a test support module it imports, starts a Vite dev server: a file that
    starts its server through a helper (test/support/papercutChat.ts, galleryControlSurfaces.ts)
    holds no mark itself, and must still get a Vite cache of its own."""
    return any(_module_starts_server(path) for path in _modules(name))


def vite_config(name: str) -> str:
    """The Vite config whose cache a dev-server file warms, read from the file and its helpers."""
    text = "\n".join(_text(path) for path in _modules(name))
    for config, marker in (("pane", "vite.config.acpmux-pane.mjs"), ("gallery", "vite.config.gallery-dev.ts"),
                           ("settings", "vite.config.settings-page.mjs")):
        if marker in text:
            return config
    return "default"


class ShardPlan:
    """One shard's estimated wall time in integer milliseconds, phase by phase as run-webviews-tests.sh
    runs them: its plain files on PLAIN_AT_ONCE lanes beside its browser files on BROWSER_AT_ONCE
    lanes (the phase lasts as long as the longer pool); one warming file per Vite config, alone, one
    after another (the config's shortest: files come longest first, so each new file of a config
    takes over warming and the one it replaces joins the pool); the other dev-server files on
    DEV_AT_ONCE lanes; then the alone files in series. Lanes, not seconds divided by width: a 549 s
    file in an 8-wide pool still takes 549 s (accent-glass-invariants)."""

    def __init__(self, widths: tuple[int, int, int] | None = None) -> None:
        plain, browser, dev = widths or (PLAIN_AT_ONCE, BROWSER_AT_ONCE, DEV_AT_ONCE)
        self.plain = [0] * plain
        self.browser = [0] * browser
        self.warm: dict[str, int] = {}
        self.dev = [0] * dev
        self.alone = 0
        self.total = 0

    @staticmethod
    def _onto(lanes: list[int], cost: int) -> list[int]:
        lanes = list(lanes)
        lanes[lanes.index(min(lanes))] += cost
        return lanes

    def _after(self, kind: str, cost: int, config: str):
        plain, browser, warm, dev, alone = self.plain, self.browser, self.warm, self.dev, self.alone
        if kind == "plain":
            plain = self._onto(plain, cost)
        elif kind == "browser":
            browser = self._onto(browser, cost)
        elif kind == "dev":
            warm = dict(warm)
            if config in warm:
                dev = self._onto(dev, warm[config])  # the longer warming file joins the pool
            warm[config] = cost
        elif kind == "alone":
            alone += cost
        return plain, browser, warm, dev, alone

    def wall(self, kind: str = "", cost: int = 0, config: str = "") -> int:
        plain, browser, warm, dev, alone = self._after(kind, cost, config)
        return max(max(plain), max(browser)) + sum(warm.values()) + max(dev) + alone

    def add(self, kind: str, cost: int, config: str = "") -> None:
        self.plain, self.browser, self.warm, self.dev, self.alone = self._after(kind, cost, config)
        self.total += cost


def parse_widths(text: str) -> tuple[int, int, int] | None:
    """`PLAIN,BROWSER,DEV` lane counts, each at least 1; anything else is no widths."""
    parts = text.split(",")
    if len(parts) != 3 or not all(part.isdigit() for part in parts):
        return None
    plain, browser, dev = (max(1, int(part)) for part in parts)
    return plain, browser, dev


def assign(files: list[str], serial: set[str], durations: dict[str, float], count: int,
           widths: tuple[int, int, int] | None = None) -> list[int]:
    """Each file's zero-based shard, the same for the same inputs on every runner. Known files go
    longest first to the shard whose estimated wall time grows least (ties: less work, then the
    lower shard); unknown files by path hash, after, so they never move a known one."""
    shards = [0] * len(files)
    plans = [ShardPlan(widths) for _ in range(count)]
    known = []
    for index, name in enumerate(files):
        if name not in durations:
            shards[index] = stable_shard(name, count)
            continue
        if name in serial:
            kind = "alone" if runs_alone(name) else "dev"
        else:
            kind = "browser" if runs_browser(name) else "plain"
        config = vite_config(name) if kind == "dev" else ""
        known.append((round(durations[name] * 1000), name, kind, config, index))
    for cost, _, kind, config, index in sorted(known, key=lambda item: (-item[0], item[1])):
        target = min(range(count), key=lambda shard: (plans[shard].wall(kind, cost, config), plans[shard].total, shard))
        plans[target].add(kind, cost, config)
        shards[index] = target
    return shards


def order(names: list[str], durations: dict[str, float], direction: str) -> list[str]:
    """asc: known files shortest first, then unknown ones, then alone files (the warming pick).
    desc: known files longest first, then unknown ones (the order a pool should start them)."""
    def key(name: str):
        if direction == "asc":
            return (runs_alone(name), name not in durations, durations.get(name, 0.0))
        return (name not in durations, -durations.get(name, 0.0))
    return sorted(names, key=key)  # stable: equal keys keep the git index order


def record(lines: str) -> dict[str, float]:
    """Each file's first run: a retry runs alone and says nothing about the file among the others."""
    found: dict[str, float] = {}
    for line in lines.splitlines():
        seconds, _, name = line.partition(" ")
        if name and seconds.isdigit():
            found.setdefault(name, float(seconds))
    return found


def merge(prior: dict[str, float], measured: list[dict[str, float]]) -> dict[str, float]:
    latest: dict[str, float] = {}
    for found in measured:
        latest.update(found)
    merged = dict(prior)
    for name, seconds in latest.items():
        merged[name] = round((prior[name] + seconds) / 2 if name in prior else seconds, 1)
    return dict(sorted(merged.items()))


def main(argv: list[str]) -> int:
    if len(argv) in (6, 7) and argv[0] == "assign":
        files, serial = read_nul(argv[1]), set(read_nul(argv[2]))
        shard, count = int(argv[4]), int(argv[5])
        if not 1 <= shard <= count:
            print(f"error: shard {shard} is not in 1..{count}", file=sys.stderr)
            return 2
        widths = parse_widths(argv[6]) if len(argv) == 7 else None
        if len(argv) == 7 and widths is None:
            print(f"error: widths {argv[6]!r} are not PLAIN,BROWSER,DEV", file=sys.stderr)
            return 2
        shards = assign(files, serial, load_durations(argv[3]), count, widths)
        write_nul([name for name, target in zip(files, shards) if target == shard - 1])
        return 0
    if len(argv) == 4 and argv[0] == "order" and argv[3] in ("asc", "desc"):
        write_nul(order(read_nul(argv[1]), load_durations(argv[2]), argv[3]))
        return 0
    if len(argv) == 4 and argv[0] == "order-triples" and argv[3] == "desc":
        items = read_nul(argv[1])
        triples = [items[index:index + 3] for index in range(0, len(items), 3)]
        durations = load_durations(argv[2])
        ranked = order([triple[0] for triple in triples], durations, "desc")
        by_file = {}
        for triple in triples:
            by_file.setdefault(triple[0], []).append(triple)
        write_nul([item for name in ranked for item in by_file[name].pop(0)])
        return 0
    if len(argv) in (2, 3) and argv[0] == "dev-servers" and argv[2:] in ([], ["--rest"]):
        rest = argv[2:] == ["--rest"]
        write_nul([name for name in read_nul(argv[1]) if starts_dev_server(name) != rest])
        return 0
    if len(argv) == 2 and argv[0] == "vite-configs":
        write_nul([item for name in read_nul(argv[1]) for item in (vite_config(name), name)])
        return 0
    if len(argv) == 3 and argv[0] == "record":
        try:
            lines = Path(argv[1]).read_text(encoding="utf-8")
        except OSError:
            lines = ""
        Path(argv[2]).write_text(json.dumps(record(lines), indent=0, sort_keys=True) + "\n", encoding="utf-8")
        return 0
    if len(argv) >= 3 and argv[0] == "merge":
        merged = merge(load_durations(argv[2]), [load_durations(path) for path in argv[3:]])
        Path(argv[1]).parent.mkdir(parents=True, exist_ok=True)
        Path(argv[1]).write_text(json.dumps(merged, indent=0, sort_keys=True) + "\n", encoding="utf-8")
        print(f"duration manifest: {len(merged)} files")
        return 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
