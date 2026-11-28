#!/usr/bin/env python3
"""Icon picker open bench (cx-ag5.9.2) against a running DEBUG cmux-next app.

Opens the icon picker with Set Workspace Icon (`workspace.setIcon`, no icon: the picker) `--opens`
times through the app's own CLI and control socket, each open replacing the last, then prints
each open's span from `debug.timings` (`icon_picker_opens`): catalog wait, panel and page made or
reused (`created_page`), present. With the launch warm-up the first open reuses the picker
like later ones (created_page false, no catalog wait).

  scripts/cmux-next/bench-icon-picker-open.py --cli "<app>/Contents/Resources/bin/cmux" \\
      --socket /tmp/cmux-debug-<tag>.sock [--opens 6] [--json out.json]

Never launches, quits or activates an app; it only talks to the socket it is given.
"""
import argparse
import json
import statistics
import subprocess
import sys
import time


def call(cli, socket, method, params):
    out = subprocess.run([cli, "--json", "--app-socket", socket, "app", "call", method, json.dumps(params)],
                         capture_output=True, text=True, timeout=30)
    if out.returncode != 0:
        sys.exit(f"{method} failed: {out.stderr.strip() or out.stdout.strip()}")
    return json.loads(out.stdout or "null")


def action(cli, socket, name):
    out = subprocess.run([cli, "--json", "--app-socket", socket, "action", "run", name],
                         capture_output=True, text=True, timeout=30)
    if out.returncode != 0:
        sys.exit(f"{name} failed: {out.stderr.strip() or out.stdout.strip()}")


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--cli", required=True, help="the app's bundled cmux CLI")
    parser.add_argument("--socket", required=True, help="the app's control socket")
    parser.add_argument("--opens", type=int, default=6)
    parser.add_argument("--settle", type=float, default=1.0, help="seconds between opens")
    parser.add_argument("--json")
    opts = parser.parse_args()

    call(opts.cli, opts.socket, "debug.timings", {"clear": True})
    for _ in range(opts.opens):
        action(opts.cli, opts.socket, "workspace.setIcon")
        time.sleep(opts.settle)  # bench pacing, not app code
    opens = (call(opts.cli, opts.socket, "debug.timings", {}) or {}).get("icon_picker_opens") or []
    if not opens:
        sys.exit("no icon_picker_opens: is this a build with the open timings, and did Set Icon open the picker?")

    print("open  total_ms  catalog_ms  page_ms  present_ms  created_page")
    for index, open_ in enumerate(opens, 1):
        print(f"{index:>4}  {open_['ms']:>8}  {open_['catalog_ms']:>10}  {open_['page_ms']:>7}  {open_['present_ms']:>10}  {open_['created_page']}")
    later = [open_["ms"] for open_ in opens[1:]]
    summary = {"first_ms": opens[0]["ms"], "first_created_page": opens[0]["created_page"],
               "later_median_ms": statistics.median(later) if later else None, "opens": opens}
    print(f"first {summary['first_ms']} ms (created_page {summary['first_created_page']}), "
          f"later median {summary['later_median_ms']} ms over {len(later)}")
    if opts.json:
        with open(opts.json, "w") as out:
            json.dump(summary, out, indent=2)


if __name__ == "__main__":
    main()
