#!/usr/bin/env python3
"""The Python share of a Swift live mode save, timed on any machine with a fake toolchain (no Mac, no Xcode).

A save in `cmux live start --swift` goes: file event -> live-mode.py's watcher finds the changed file -> patch.py
finds the build's compile command in xcodebuild.log -> compile -> link -> sign -> move into the live folder -> the
app loads it. The compile, link and load are the toolchain's and the app's; this times everything around them:

  scan_s     the watcher finding what changed: the full walk of every Swift source (the 1 s poll's work)
             against rescanning only the paths a file event named
  patch_s    one patch.py run with a swift-frontend, swiftc and codesign that only write their outputs, so
             all of it is patch.py's own cost (log lookup, file list, real paths, sidecar git)
  lookup_s   patch.py's lookup_s: the first save (reads the log) and a later one (LOG.commands.json)

The fake log has one frontend line per file of a module of FILES files, LINE_KB long each, plus other modules'
lines; the tree has the checkout's real Packages/macOS/CmuxNext/Sources (9k Swift files) when run from a checkout.

  scripts/measure/live-code-save-overhead.py [--files 1308] [--line-kb 6] [--patch OLD_PATCH_PY] [--json]

--patch times another patch.py (the one before this change: `git show REV:scripts/live-code/patch.py > F`).

The real loop on a Mac (save to the app's applied line, the watcher's phases.jsonl) is
scripts/measure/live-mode-swift.sh.
"""
import argparse
import importlib.util
import json
import os
import shutil
import statistics
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MODULE = "CmuxNextApp"


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def fake_toolchain(bin_dir):
    bin_dir.mkdir(parents=True)
    writer = """#!/usr/bin/env python3
import sys
args = sys.argv[1:]
for i, a in enumerate(args[:-1]):
    if a == "-o":
        open(args[i + 1], "wb").close()
"""
    for name in ("swift-frontend", "swiftc", "codesign"):
        (bin_dir / name).write_text(writer)
        (bin_dir / name).chmod(0o755)


def fake_log(work, tree, files, line_kb):
    """An xcodebuild.log shaped like a live code build's: a driver line with the module's .SwiftFileList and
    one frontend line per file of the module, each padded with search paths to LINE_KB."""
    sources = sorted(str(p) for p in (tree / "Packages/macOS/CmuxNext/Sources" / MODULE).rglob("*.swift"))[:files]
    while len(sources) < files:  # a tree with fewer files: made-up names keep the log's size
        sources.append(str(tree / f"Packages/macOS/CmuxNext/Sources/{MODULE}/Fake{len(sources)}.swift"))
    filelist = work / f"{MODULE}.SwiftFileList"
    filelist.write_text("\n".join(sources) + "\n")
    frontend = work / "toolchain/swift-frontend"
    pad = " ".join(f"-I/Users/runner/Library/Developer/Xcode/DerivedData/cmux/Build/Products/Debug/include/{i:04d}"
                   for i in range(max(1, line_kb * 1024 // 90)))
    flags = f"-target arm64-apple-macos14.0 -sdk /Applications/Xcode.app/SDKs/MacOSX.sdk -Onone -enable-testing {pad}"
    log = work / "xcodebuild.log"
    with open(log, "w") as out:
        for other in ("CmuxNextCore", "CmuxNextPages", "CmuxNextLiveCode"):
            for i in range(files // 3):
                out.write(f"    {frontend} -frontend -c -primary-file /x/{other}/F{i}.swift -module-name {other} {flags}\n")
        out.write(f"builtin-SwiftDriver -- swiftc -module-name {MODULE} @{filelist}\n")
        for source in sources:
            out.write(f"    {frontend} -frontend -c -filelist {filelist} -primary-file {source} -module-name {MODULE} "
                      f"{flags} -o {work}/obj.o\n")
    return log, sources


def timed(fn, runs):
    samples = []
    for _ in range(runs):
        began = time.perf_counter()
        fn()
        samples.append(time.perf_counter() - began)
    return round(statistics.median(samples), 4)


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--files", type=int, default=1308, help="the module's file count (CmuxNextApp: 1308)")
    parser.add_argument("--line-kb", type=int, default=6, help="each frontend line's length in KB")
    parser.add_argument("--patch", default=str(ROOT / "scripts/live-code/patch.py"), help="the patch.py to time")
    parser.add_argument("--runs", type=int, default=5)
    parser.add_argument("--json", action="store_true")
    opts = parser.parse_args()
    live_mode = load("live_mode", ROOT / "scripts/live-code/live-mode.py")
    work = Path(tempfile.mkdtemp(prefix="live-code-save-overhead."))
    try:
        fake_toolchain(work / "toolchain")
        log, sources = fake_log(work, ROOT, opts.files, opts.line_kb)
        edited = next((s for s in sources if os.path.exists(s)), sources[0])
        if not os.path.exists(edited):
            Path(edited).parent.mkdir(parents=True, exist_ok=True)
            Path(edited).write_text("struct A {}\n")
        seen = live_mode.swift_sources(ROOT)
        result = {"files": opts.files, "line_kb": opts.line_kb, "log_mb": round(log.stat().st_size / 2**20, 1),
                  "tree_swift_files": len(seen),
                  "scan_full_s": timed(lambda: live_mode.swift_sources(ROOT, seen), opts.runs),
                  "scan_event_s": timed(lambda: live_mode.rescanned(ROOT, seen, [edited]), opts.runs)}
        env = dict(os.environ, PATH=f"{work / 'toolchain'}:{os.environ['PATH']}")

        def patch_once(fresh):
            if fresh:
                Path(f"{log}.commands.json").unlink(missing_ok=True)
            run = subprocess.run([sys.executable, opts.patch, "--log", str(log), "--module", MODULE,
                                  "--live", str(work / "live"), edited], capture_output=True, text=True, env=env, cwd=ROOT)
            if run.returncode:
                sys.exit(run.stderr[-2000:])
            return run.stdout

        result["patch_first_s"] = timed(lambda: patch_once(True), opts.runs)
        result["patch_next_s"] = timed(lambda: patch_once(False), opts.runs)
        line = patch_once(False)
        for field in ("lookup_s", "compile_s", "total_s"):
            found = [part.split("=", 1)[1] for part in line.split() if part.startswith(field + "=")]
            if found:
                result[f"next_{field}"] = float(found[0])
    finally:
        shutil.rmtree(work, ignore_errors=True)
    if opts.json:
        print(json.dumps(result))
    else:
        for key, value in result.items():
            print(f"{key:>18} {value}")


if __name__ == "__main__":
    main()
