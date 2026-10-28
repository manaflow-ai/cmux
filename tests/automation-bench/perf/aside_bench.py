#!/usr/bin/env python3
"""cmux REPL against `aside repl`, public pages only (plans/cmux-next/browser-use-perf.md, "Aside").

Aside runs in the person's Aside Browser, so this script only opens a NEW tab with openTab() on a public page
(example.com, Hacker News, Wikipedia), times goto / snapshot / interactive snapshot / one click inside that
same call, and closes the tab with closeTab(). It never lists, attaches to or reads the person's tabs, and
never visits a site that could be signed in. cmux runs the same script body in a private headless host.

  python3 -I aside_bench.py --runs 20 --out DIR [--bin DIR_WITH_cmux-browser-host]
"""
import argparse
import json
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bench  # noqa: E402  (HostProcess, LineConn, pct)

PAGES = [
    ("example", "https://example.com/", None),
    ("hn", "https://news.ycombinator.com/", "new"),
    ("wiki_rust", "https://en.wikipedia.org/wiki/Rust_(programming_language)", None),
]

# One call: N rounds of goto, full snapshot, interactive snapshot (and on HN a click on the "new" link),
# timed inside the REPL with Date.now(); prints one JSON line. the @...@ parts differ per tool.
BODY = """
const __u = @URL@; const __n = @N@; const __click = @CLICK@; const __out = [];
@OPEN@
for (let __i = 0; __i < __n; __i++) {
  const __a = Date.now(); await __p.goto(__u, { waitUntil: "load" });
  const __b = Date.now(); const __s = await @SNAPFULL@;
  const __c = Date.now(); const __si = await @SNAPINT@;
  const __d = Date.now();
  const __r = { goto: __b - __a, state: __c - __b, state_interactive: __d - __c, chars: __s.length, chars_interactive: __si.length };
  if (__click) {
    const __e = Date.now(); await __p.getByRole("link", { name: __click, exact: true }).first().click();
    __r.click = Date.now() - __e;
  }
  __out.push(__r);
}
@CLOSE@
console.log("BENCH" + JSON.stringify(__out));
"""


def script(tool, url, n, click):
    if tool == "aside":
        open_, close = "const __p = await openTab(__u);", "await closeTab(__p);"
        full, inter = "snapshot(__p).then((x) => x.tree)", "snapshot(__p, { interactive: true }).then((x) => x.tree)"
    else:
        open_, close = "const __p = page;", ""
        full, inter = "snapshot().then((x) => String(x))", "snapshot({ interactive: true }).then((x) => String(x))"
    return (BODY.replace("@URL@", json.dumps(url)).replace("@N@", str(n)).replace("@CLICK@", json.dumps(click))
            .replace("@OPEN@", open_).replace("@CLOSE@", close).replace("@SNAPFULL@", full).replace("@SNAPINT@", inter))


def parse(out):
    for line in out.splitlines():
        if line.startswith("BENCH"):
            return json.loads(line[5:])
    raise RuntimeError(out[-400:])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--runs", type=int, default=20)
    ap.add_argument("--per-call", type=int, default=10, help="rounds per REPL call (aside's call limit is 120 s)")
    ap.add_argument("--bin", default=bench.APP_BIN)
    ap.add_argument("--out", required=True)
    opts = ap.parse_args()
    bench.APP_BIN = opts.bin
    os.makedirs(opts.out, exist_ok=True)
    rows = []
    host = bench.HostProcess(opts.out)
    conn = bench.LineConn(host.sock)
    conn.call("browser.repl.open", {"session": "aside-cmp", "engine": "headless", "cwd": host.dir})
    try:
        for sid, url, click in PAGES:
            for call in range(max(1, opts.runs // opts.per_call)):
                for tool in ("cmux", "aside"):
                    code = script(tool, url, opts.per_call, click)
                    t0 = time.perf_counter()
                    try:
                        if tool == "aside":
                            p = subprocess.run(["aside", "repl", code], capture_output=True, text=True, timeout=150,
                                               cwd=host.dir)
                            out = p.stdout + p.stderr
                        else:
                            r = conn.call("browser.repl.eval", {"session": "aside-cmp", "code": code, "timeoutMs": 150000})
                            out = (r.get("output") or "") + (r.get("error") or "")
                        wall = (time.perf_counter() - t0) * 1000
                        for i, r in enumerate(parse(out)):
                            for prim in ("goto", "state", "state_interactive", "click"):
                                if prim in r:
                                    row = {"tool": tool, "site": sid, "prim": prim, "run": call * opts.per_call + i,
                                           "ms": r[prim], "ok": True}
                                    if prim == "state":
                                        row["chars"] = r["chars"]
                                    if prim == "state_interactive":
                                        row["chars"] = r["chars_interactive"]
                                    rows.append(row)
                        rows.append({"tool": tool, "site": sid, "prim": "call_wall", "run": call, "ms": round(wall, 1), "ok": True})
                    except Exception as e:
                        rows.append({"tool": tool, "site": sid, "prim": "call", "run": call, "ms": 0, "ok": False,
                                     "error": str(e)[:300]})
                print(f"{sid} call {call + 1} done", file=sys.stderr, flush=True)
    finally:
        try:
            conn.call("browser.repl.close", {"session": "aside-cmp"})
        except Exception:
            pass
        conn.close()
        host.stop()
    with open(os.path.join(opts.out, "aside-rows.jsonl"), "w") as f:
        for r in rows:
            f.write(json.dumps(r) + "\n")
    summary = bench.summarize(rows)
    with open(os.path.join(opts.out, "aside-summary.json"), "w") as f:
        json.dump({"summary": summary}, f, indent=1)
    for s in summary:
        print(json.dumps(s))


if __name__ == "__main__":
    main()
