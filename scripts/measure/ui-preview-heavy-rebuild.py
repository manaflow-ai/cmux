#!/usr/bin/env python3
"""One-module incremental rebuilds of the heavy NEXT modules (scripts/measure/ui-preview-heavy-rebuild.sh).

The UI preview worker shoots a push's Swift scenes on a warm build (ui-preview-worker.py); a push that touches a module
the leaf UI shell does not link (CmuxNextAgentPane, CmuxNextApp, ...) gets no look. This times the two ways to cover them:

  A (incremental app product): `swift build --product CmuxNextApp` with a warm .build, after one edit to the module:
    the module, every module above it and the CmuxNextApp dylib link.
  B (stubbed dependencies): the changed module alone, `swift build --target MODULE`, as a shell that links it
    against fakes would rebuild it: its own compile, no module above it, no app link. A lower bound for B (its host's
    link and its fakes' own compile come on top).
  shell: today's shell (Prototypes/UiLayerHost, cmux-ui-layer) after an edit to CmuxNextTabs, the reference.

Each edit appends one internal declaration (an interface change, so dependents rebuild: the common case for a UI
push that adds a property or a view) to a file of the module, and the rebuild after taking it back is timed too (the
base side). Files are restored with git checkout when the run ends.
"""
import argparse, json, os, statistics, subprocess, sys, time

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "../.."))
PKG = "Packages/macOS/CmuxNext"
SHELL = "Prototypes/UiLayerHost"
EDITS = [
    ("CmuxNextAgentPane", f"{PKG}/Sources/CmuxNextAgentPane/AgentPaneActAsMeCard.swift"),
    ("CmuxNextApp", f"{PKG}/Sources/CmuxNextApp/Home/HomeHostView.swift"),
]
SHELL_EDIT = ("CmuxNextTabs", None)  # a file found at run time in Sources/CmuxNextTabs


def run(cmd, log):
    start = time.monotonic()
    with open(log, "a") as fh:
        fh.write(f"$ {' '.join(cmd)}\n")
        fh.flush()
        code = subprocess.call(cmd, cwd=ROOT, stdout=fh, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL)
    seconds = round(time.monotonic() - start, 2)
    if code != 0:
        with open(log) as fh:
            sys.stderr.write("".join(fh.readlines()[-60:]))
        raise SystemExit(f"ui-preview-heavy-rebuild: {' '.join(cmd)} exited {code}")
    return seconds


def edit(path, n):
    with open(os.path.join(ROOT, path), "a") as fh:
        fh.write(f"\nfunc uiPreviewHeavyRebuildProbe{n}() -> Int {{ {n} }}\n")


def restore(paths):
    if paths:
        subprocess.call(["git", "checkout", "--", *paths], cwd=ROOT)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--edits", type=int, default=2)
    args = ap.parse_args()
    os.makedirs(args.out, exist_ok=True)
    log = os.path.join(args.out, "build.log")
    tabs_dir = os.path.join(ROOT, PKG, "Sources/CmuxNextTabs")
    tabs_file = os.path.join(PKG, "Sources/CmuxNextTabs", sorted(f for f in os.listdir(tabs_dir) if f.endswith(".swift"))[0])
    touched = [p for _, p in EDITS] + [tabs_file]
    dirty = subprocess.run(["git", "status", "--porcelain", "--", *touched], cwd=ROOT, capture_output=True, text=True).stdout
    if dirty.strip():
        raise SystemExit(f"ui-preview-heavy-rebuild: local changes in {dirty.strip()}; refusing to erase them")
    rows = []

    def row(**kw):
        rows.append(kw)
        print("UI-PREVIEW-HEAVY-ROW " + json.dumps(kw), flush=True)

    product = ["swift", "build", "--package-path", PKG, "--product", "CmuxNextApp"]
    shell = ["swift", "build", "--package-path", SHELL, "--product", "cmux-ui-layer"]
    try:
        row(path="A", kind="cold", module="CmuxNextApp", seconds=run(product, log))
        row(path="A", kind="noop", module="CmuxNextApp", seconds=run(product, log))
        n = 0
        for module, path in EDITS:
            target = ["swift", "build", "--package-path", PKG, "--target", module]
            for _ in range(args.edits):
                n += 1
                edit(path, n)
                row(path="A", kind="head", module=module, seconds=run(product, log))
                restore([path])
                row(path="A", kind="base", module=module, seconds=run(product, log))
                edit(path, n)
                row(path="B", kind="head", module=module, seconds=run(target, log))
                restore([path])
                row(path="B", kind="base", module=module, seconds=run(target, log))
        row(path="shell", kind="cold", module="CmuxNextTabs", seconds=run(shell, log))
        for _ in range(args.edits):
            n += 1
            edit(tabs_file, n)
            row(path="shell", kind="head", module="CmuxNextTabs", seconds=run(shell, log))
            restore([tabs_file])
            row(path="shell", kind="base", module="CmuxNextTabs", seconds=run(shell, log))
    finally:
        restore(touched)
    summary = {}
    for r in rows:
        if r["kind"] in ("head", "base"):
            summary.setdefault(f'{r["path"]}/{r["module"]}', []).append(r["seconds"])
    summary = {k: {"median_s": statistics.median(v), "max_s": max(v), "n": len(v)} for k, v in summary.items()}
    report = {"schema": "ui-preview-heavy-rebuild/v1", "rows": rows, "summary": summary}
    with open(os.path.join(args.out, "report.json"), "w") as fh:
        json.dump(report, fh, indent=2)
    print("UI-PREVIEW-HEAVY " + json.dumps(summary), flush=True)


if __name__ == "__main__":
    main()
