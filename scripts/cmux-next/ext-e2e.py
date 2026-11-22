#!/usr/bin/env python3
"""Chrome extension end-to-end verification for tagged cmux-next builds.

  scripts/cmux-next/ext-e2e.py api   --tag <tag>   # chrome.* API conformance matrix
  scripts/cmux-next/ext-e2e.py store --tag <tag>   # real Chrome Web Store extensions
      [--only <id,id>] [--limit N] [--batch 8]
  scripts/cmux-next/ext-e2e.py report --api <run dir> --store <run dir>
      # writes plans/cmux-next/extensions-matrix.md from two runs

`api` stages the test extensions in scripts/cmux-next/ext-conformance (MV3 and
MV2) with a local results collector, launches the tagged Debug build with a
fresh Chromium profile, the extensions installed and a DevTools port, opens a
Chromium tab, lets the MV3 worker run every API that needs no UI, then drives
the UI checks: the toolbar button through `debug.ax` (the button's real click
path), the popup's user-gesture buttons through CDP input, the extension
command through `debug.key`, the page menu through `debug.menu` when the build
has it, and DevTools through the palette action.

`store` downloads each extension in scripts/cmux-next/ext-store/extensions.json
as the CRX the Web Store serves, unpacks it with its public key (same id), and
checks the worker starts with no errors, the popup opens (screenshot through
CDP) and one scripted main-use check.

Launch rules (plans/cmux-next/AGENT-BRIEF.md): clean environment, no
activation, window on the last screen, only PIDs this script started are
killed. Output goes to artifacts/ext-e2e/<tag>-<time>/ (matrix.json,
matrix.md, results.json, app.log, screenshots).

Exit status: 0 when no check failed, 1 on failures, 2 on setup errors.
"""
import argparse
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ext_e2e import matrix  # noqa: E402


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("mode", choices=["api", "store", "report"])
    parser.add_argument("--tag")
    parser.add_argument("--api", help="report: api run directory")
    parser.add_argument("--store", help="report: store run directory")
    parser.add_argument("--out")
    parser.add_argument("--only", help="store: comma-separated extension ids")
    parser.add_argument("--limit", type=int, default=0, help="store: first N extensions")
    parser.add_argument("--batch", type=int, default=6, help="store: extensions per app launch")
    args = parser.parse_args()
    root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    if args.mode == "report":
        path = os.path.join(root, "plans", "cmux-next", "extensions-matrix.md")
        matrix.write_report(path, args.api, args.store)
        print(path)
        return 0
    if not args.tag:
        parser.error("--tag is required")
    out = args.out or os.path.join(root, "artifacts", "ext-e2e", f"{args.tag}-{args.mode}-{time.strftime('%Y%m%d-%H%M%S')}")
    os.makedirs(out, exist_ok=True)

    def log(message):
        print(f"[ext-e2e] {message}", flush=True)

    if args.mode == "api":
        from ext_e2e.conformance import Run
        snapshot = Run(args.tag, out, log).execute()
        table = matrix.rows(snapshot)
        title = "API conformance"
    else:
        from ext_e2e.store import StoreRun
        table = StoreRun(args.tag, out, log, only=args.only, limit=args.limit, batch=args.batch).execute()
        title = "Real Chrome Web Store extensions"
    matrix.write(os.path.join(out, "matrix.json"), os.path.join(out, "matrix.md"), table, title,
                 [f"Tag `{args.tag}`, {time.strftime('%Y-%m-%d %H:%M')}.", ""])
    summary = matrix.counts(table)
    log(f"{title}: {summary}  ->  {out}/matrix.md")
    return 1 if summary.get("fail") or summary.get("missing") or summary.get("error") else 0


if __name__ == "__main__":
    sys.exit(main())
