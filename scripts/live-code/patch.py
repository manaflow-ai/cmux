#!/usr/bin/env python3
"""Live code patch for the app (Packages/macOS/CmuxNext/Sources/CmuxNextLiveCode/LiveCode.swift).

Compiles edited Swift files of one module with the frontend command Xcode used for that module in
the running app's build (reload.sh with CMUX_LIVE_CODE_BUILD=1 keeps it in its xcodebuild log), with
the edited files as the only primaries: every file of the module is read, only the edited ones are
compiled. Links their objects alone into a dylib, signs it ad hoc and moves it into the live folder
the app watches (CMUX_LIVE_CODE_DIR). The app repoints its functions to the patch's and redraws.

  scripts/live-code/patch.py --log /tmp/cmux-reload-TAG.log --module CmuxNextApp --live DIR FILE.swift...

Prints `patch.py: DIR/patch-....dylib compile_s=... link_s=...`.
"""
import argparse
import os
import shlex
import shutil
import subprocess
import sys
import tempfile
import time

# Options whose value is an output of the build (or a temporary file the driver removed): the patch
# writes one object and nothing else.
DROP_WITH_VALUE = {
    "-o", "-supplementary-output-file-map", "-output-filelist", "-filelist", "-primary-filelist",
    "-primary-file", "-num-threads", "-index-store-path", "-index-unit-output-path",
    "-emit-module-path", "-emit-module-doc-path", "-emit-module-source-info-path", "-emit-objc-header-path",
    "-emit-dependencies-path", "-emit-reference-dependencies-path", "-serialize-diagnostics-path",
    "-emit-const-values-path", "-const-gather-protocols-file", "-emit-abi-descriptor-path",
    "-emit-api-descriptor-path", "-emit-module-interface-path", "-emit-private-module-interface-path",
    "-emit-package-module-interface-path", "-emit-loaded-module-trace-path", "-emit-tbd-path",
    "-pch-output-dir", "-emit-module-summary-path",
}
DROP = {
    "-whole-module-optimization", "-emit-module", "-emit-objc-header", "-frontend-parseable-output",
    "-index-system-modules", "-index-ignore-system-modules", "-enable-batch-mode", "-emit-dependencies",
    "-experimental-emit-module-separately",
}


def module_commands(log, module):
    """The last frontend compile argv for `module` in the log, and its driver's .SwiftFileList."""
    frontend, filelist = None, None
    with open(log, errors="replace") as lines:
        for raw in lines:
            text = raw.strip()
            if f"-module-name {module} " not in text:
                continue
            try:
                argv = shlex.split(text)
            except ValueError:
                continue
            if text.startswith("builtin-SwiftDriver "):
                filelist = next((a[1:] for a in argv if a.startswith("@") and a.endswith(".SwiftFileList")), filelist)
                continue
            start = next((i for i, a in enumerate(argv) if a.endswith("/swift-frontend")), None)
            if start is not None and "-frontend" in argv and "-c" in argv:
                frontend = argv[start:]
    if frontend and not filelist:
        # No driver line: the frontend's own list of the module's files (a file-at-a-time build).
        filelist = next((frontend[i + 1] for i, a in enumerate(frontend[:-1]) if a == "-filelist"), None)
    return frontend, filelist


def read_filelist(path):
    with open(path) as f:
        return [line.strip().replace("\\ ", " ") for line in f if line.strip()]


def patch_argv(frontend, files, edited, work):
    """The build's command, rewritten to compile `edited` (inside `files`) into one object each."""
    argv, skip = [], False
    for arg in frontend:
        if skip:
            skip = False
            continue
        if arg in DROP_WITH_VALUE:
            skip = True
            continue
        if arg in DROP or arg.endswith(".swift"):
            continue
        argv.append(arg)
    listing = os.path.join(work, "sources")
    primaries = os.path.join(work, "primaries")
    with open(listing, "w") as f:
        f.write("\n".join(files) + "\n")
    with open(primaries, "w") as f:
        f.write("\n".join(edited) + "\n")
    objects = [os.path.join(work, os.path.basename(path)[:-len(".swift")] + ".o") for path in edited]
    argv += ["-filelist", listing, "-primary-filelist", primaries]
    for obj in objects:
        argv += ["-o", obj]
    return argv, objects


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--log", required=True, help="reload.sh's xcodebuild log of the running build")
    parser.add_argument("--module", default="CmuxNextApp")
    parser.add_argument("--live", required=True, help="the live folder the app watches")
    parser.add_argument("files", nargs="+")
    opts = parser.parse_args()
    started = time.time()
    frontend, filelist = module_commands(opts.log, opts.module)
    if not frontend:
        sys.exit(f"patch.py: no frontend compile of {opts.module} in {opts.log} (built with CMUX_LIVE_CODE_BUILD=1?)")
    if not filelist or not os.path.exists(filelist):
        sys.exit(f"patch.py: the {opts.module} driver's file list is missing ({filelist})")
    files = read_filelist(filelist)
    edited = [os.path.realpath(path) for path in opts.files]
    real = {os.path.realpath(path): path for path in files}
    missing = [path for path in edited if path not in real]
    if missing:
        sys.exit(f"patch.py: not in {opts.module}'s build: {', '.join(missing)} (a new file needs a rebuild for now)")
    if "-Onone" not in frontend or "-enable-testing" not in frontend:
        print(f"patch.py: warning: {opts.module} was not built -Onone and testable; a patch may not show", file=sys.stderr)
    work = tempfile.mkdtemp(prefix="cmux-live-code-patch.")
    argv, objects = patch_argv(frontend, files, [real[path] for path in edited], work)
    with open(os.path.join(work, "command"), "w") as f:
        f.write(shlex.join(argv) + "\n")
    compile_run = subprocess.run(argv, capture_output=True, text=True)
    if compile_run.returncode != 0:
        sys.stderr.write(compile_run.stderr[-6000:])
        sys.exit(f"patch.py: the compile failed (command in {work}/command)")
    compiled = time.time()
    target = argv[argv.index("-target") + 1]
    sdk = argv[argv.index("-sdk") + 1] if "-sdk" in argv else None
    name = f"patch-{time.time_ns()}-{os.getpid()}.dylib"  # unique and in order, even for two saves in a second
    dylib = os.path.join(work, name)
    # The swiftc beside the build's frontend: the same toolchain compiles and links.
    swiftc = os.path.join(os.path.dirname(frontend[0]), "swiftc")
    link = [swiftc if os.path.exists(swiftc) else "swiftc", "-emit-library", *objects, "-o", dylib, "-target", target,
            "-module-name", f"{opts.module}LiveCodePatch", "-Xlinker", "-undefined", "-Xlinker", "dynamic_lookup"]
    if sdk:
        link += ["-sdk", sdk]
    link_run = subprocess.run(link, capture_output=True, text=True)
    if link_run.returncode != 0:
        sys.stderr.write(link_run.stderr[-6000:])
        sys.exit("patch.py: the link failed")
    subprocess.run(["codesign", "--force", "--sign", "-", dylib], capture_output=True, check=True)
    linked = time.time()
    os.makedirs(opts.live, exist_ok=True)
    # Moved into place in one step, so the app never reads a half-written file.
    hidden = os.path.join(opts.live, "." + name)
    shutil.move(dylib, hidden)
    os.replace(hidden, os.path.join(opts.live, name))
    print(f"patch.py: {os.path.join(opts.live, name)} compile_s={compiled - started:.2f} link_s={linked - compiled:.2f} "
          f"started={started:.3f}")


if __name__ == "__main__":
    main()
