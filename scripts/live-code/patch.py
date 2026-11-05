#!/usr/bin/env python3
"""Live code patch for the app (Packages/macOS/CmuxNext/Sources/CmuxNextLiveCode/LiveCode.swift).

Compiles edited Swift files, of any CmuxNext module, with the frontend command Xcode used for each
file's module in the running app's build (scripts/live-code/build.sh keeps it in its xcodebuild log),
with the edited files as the only primaries: every file of the module is read, only the edited ones
are compiled. Links their objects alone into one dylib, signs it ad hoc and moves it into the live folder
the app watches (CMUX_LIVE_CODE_DIR). The app repoints its functions to the patch's and redraws.

  scripts/live-code/patch.py --log OUT/xcodebuild.log --live DIR FILE.swift...
  scripts/live-code/patch.py --log LOG --live DIR --tree TREE Packages/.../FILE.swift...

--tree reads the module's sources from TREE instead of the build's checkout (try-pr.sh: the build's
commit with a pull request applied); FILE is then a path relative to the checkout's root, and the
build's generated sources (outside the checkout) stay as built.

Hot optimize: the live code build you edited, optimized while it runs, with no rebuild or relaunch.

  scripts/live-code/patch.py --log LOG --live DIR --optimize --all

--optimize compiles at -O instead of the build's -Onone; --all takes every file of the module, the
edits on disk included. A file that defines stored global or static state is left out: a patch
would bring its own copy of that state, empty, and the app's would be lost. That file's functions
keep the code they run now (the build's, or an earlier patch's).

Prints `patch.py: DIR/patch-....dylib compile_s=... link_s=...`.
"""
import argparse
import concurrent.futures
import json
import os
import re
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


def source_root(edited):
    """The git checkout the edited files are in, or None."""
    run = subprocess.run(["git", "-C", os.path.dirname(edited[0]), "rev-parse", "--show-toplevel"], capture_output=True, text=True)
    return run.stdout.strip() if run.returncode == 0 else None


def source_commit(edited):
    """The checkout's commit, with `+dirty` when the edited files differ from it."""
    root = source_root(edited)
    if not root:
        return None
    head = subprocess.run(["git", "-C", root, "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
    dirty = subprocess.run(["git", "-C", root, "diff", "--quiet", "HEAD", "--", *edited]).returncode != 0
    return head + ("+dirty" if dirty else "") if head else None


def checkout_root(files, module):
    """The build's checkout: the folder its module sources sit under (.../Packages/.../<module>/)."""
    for path in files:
        at = path.find("/Packages/")
        if at > 0 and f"/{module}/" in path[at:]:
            return path[:at]
    return None


def from_tree(files, tree, root):
    """The build's file list with every file of the checkout read from TREE at the same path."""
    moved = []
    for path in files:
        if path.startswith(root + "/"):
            rel = path[len(root) + 1:]
            if not os.path.exists(os.path.join(tree, rel)):
                sys.exit(f"patch.py: {rel} is in the build but not in {tree} (a deleted file needs a rebuild)")
            moved.append(os.path.join(tree, rel))
        else:
            moved.append(path)
    return moved


# A Swift variable's storage (`...vp`, a static's `...vpZ`): a defined data symbol of that name means
# the object holds state of its own.
STORAGE = re.compile(r"^_\$s\S*vpZ?$")


def holds_state(obj):
    """Whether the object defines storage for a global or static variable."""
    listing = subprocess.run(["nm", "-U", obj], capture_output=True, text=True, check=True).stdout
    for line in listing.splitlines():
        fields = line.split()
        if len(fields) == 3 and fields[1] not in ("T", "t") and STORAGE.match(fields[2]):
            return True
    return False


def compile_all(argv, work, jobs):
    """Runs the patch command once per chunk of its primaries, `jobs` at a time (one frontend compiles
    its primaries one after another). Returns the failed runs' stderr."""
    primaries = read_filelist(argv[argv.index("-primary-filelist") + 1])
    outputs = [argv[i + 1] for i, a in enumerate(argv) if a == "-o"]
    base, skip = [], False
    for arg in argv:
        if skip:
            skip = False
            continue
        if arg in ("-o", "-primary-filelist"):
            skip = True
            continue
        base.append(arg)
    size = max(1, -(-len(primaries) // jobs))
    runs = []
    for start in range(0, len(primaries), size):
        listing = os.path.join(work, f"primaries-{start}")
        with open(listing, "w") as f:
            f.write("\n".join(primaries[start:start + size]) + "\n")
        chunk = base + ["-primary-filelist", listing]
        for out in outputs[start:start + size]:
            chunk += ["-o", out]
        runs.append(chunk)
    with concurrent.futures.ThreadPoolExecutor(max_workers=jobs) as pool:
        done = pool.map(lambda chunk: subprocess.run(chunk, capture_output=True, text=True), runs)
        return [run.stderr for run in done if run.returncode != 0]


def patch_argv(frontend, files, edited, work, optimize=False):
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
        argv.append("-O" if optimize and arg == "-Onone" else arg)
    listing = os.path.join(work, "sources")
    primaries = os.path.join(work, "primaries")
    with open(listing, "w") as f:
        f.write("\n".join(files) + "\n")
    with open(primaries, "w") as f:
        f.write("\n".join(edited) + "\n")
    # Numbered: two files of a module may share a name in different folders.
    objects = [os.path.join(work, f"{index}-{os.path.basename(path)[:-len('.swift')]}.o") for index, path in enumerate(edited)]
    argv += ["-filelist", listing, "-primary-filelist", primaries]
    for obj in objects:
        argv += ["-o", obj]
    return argv, objects


def module_of(path):
    """The CmuxNext module a source file belongs to: its folder under Sources/."""
    parts = os.path.realpath(path).split(os.sep)
    at = len(parts) - 1 - parts[::-1].index("Sources") if "Sources" in parts else -1
    return parts[at + 1] if 0 <= at < len(parts) - 2 else None


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--log", required=True, help="reload.sh's xcodebuild log of the running build")
    parser.add_argument("--module", help="every file's module (default: each file's folder under Sources/)")
    parser.add_argument("--live", required=True, help="the live folder the app watches")
    parser.add_argument("--tree", help="read the module's sources from this tree; FILE is relative to its root")
    parser.add_argument("--sign", default=os.environ.get("CMUX_LIVE_CODE_SIGN_IDENTITY", "-"),
                        help="codesign identity (default: CMUX_LIVE_CODE_SIGN_IDENTITY, else - for ad hoc); outside Debug "
                             "and bench an app signed by a team loads only a patch signed by that team")
    parser.add_argument("--optimize", action="store_true", help="compile at -O instead of the build's -Onone")
    parser.add_argument("--all", action="store_true", help="every file of the module, not only FILE")
    parser.add_argument("--jobs", type=int, default=os.cpu_count() or 4, help="compiles at once")
    parser.add_argument("files", nargs="*")
    opts = parser.parse_args()
    if not opts.files and not opts.all:
        parser.error("name the edited FILEs, or --all")
    started = time.time()
    # Each module's edited files compile with that module's own command; one dylib holds them all.
    # --all is one module's every file: --module's, else CmuxNextApp's.
    modules = {}
    for path in opts.files:
        module = opts.module or module_of(path)
        if not module:
            sys.exit(f"patch.py: {path} is in no module's Sources/ folder; pass --module")
        modules.setdefault(module, []).append(path)
    if opts.all and not modules:
        modules[opts.module or "CmuxNextApp"] = []
    if opts.all and len(modules) > 1:
        sys.exit("patch.py: --all is one module's files; these are in " + ", ".join(sorted(modules)))
    work = tempfile.mkdtemp(prefix="cmux-live-code-patch.")
    objects, argv, frontend = [], None, None
    for module, edited in modules.items():
        frontend, filelist = module_commands(opts.log, module)
        if not frontend:
            sys.exit(f"patch.py: no frontend compile of {module} in {opts.log} (built with scripts/live-code/build.sh?)")
        if not filelist or not os.path.exists(filelist):
            sys.exit(f"patch.py: the {module} driver's file list is missing ({filelist})")
        files = read_filelist(filelist)
        if opts.tree:
            root = checkout_root(files, module)
            if not root:
                sys.exit(f"patch.py: no checkout folder in {module}'s file list")
            tree = os.path.realpath(opts.tree)
            files = from_tree(files, tree, root)
            edited = [os.path.join(tree, path) for path in edited]
        else:
            edited = [os.path.realpath(path) for path in edited]
        real = {path if opts.tree else os.path.realpath(path): path for path in files}
        if opts.all:
            edited = list(real)
        missing = [path for path in edited if path not in real]
        if missing:
            sys.exit(f"patch.py: not in {module}'s build: {', '.join(missing)} (a new file needs a rebuild for now)")
        if "-Onone" not in frontend or "-enable-testing" not in frontend:
            print(f"patch.py: warning: {module} was not built -Onone and testable; a patch may not show", file=sys.stderr)
        module_work = os.path.join(work, module)
        os.makedirs(module_work)
        argv, module_objects = patch_argv(frontend, files, [real[path] for path in edited], module_work, optimize=opts.optimize)
        with open(os.path.join(module_work, "command"), "w") as f:
            f.write(shlex.join(argv) + "\n")
        failed = compile_all(argv, module_work, max(1, opts.jobs))
        if failed:
            sys.stderr.write(failed[0][-6000:])
            sys.exit(f"patch.py: the compile of {module} failed (command in {module_work}/command)")
        objects += module_objects
    compiled = time.time()
    kept = 0
    if opts.all:
        # The whole module: leave out each file with state of its own (the docstring says why).
        stateless = [obj for obj in objects if not holds_state(obj)]
        kept = len(objects) - len(stateless)
        objects = stateless
        if not objects:
            sys.exit(f"patch.py: every file of {next(iter(modules))} holds state; nothing to patch")
    target = argv[argv.index("-target") + 1]
    sdk = argv[argv.index("-sdk") + 1] if "-sdk" in argv else None
    name = f"patch-{int(time.time())}-{os.getpid()}.dylib"
    dylib = os.path.join(work, name)
    # The swiftc beside the build's frontend: the same toolchain compiles and links.
    swiftc = os.path.join(os.path.dirname(frontend[0]), "swiftc")
    link = [swiftc if os.path.exists(swiftc) else "swiftc", "-emit-library", *objects, "-o", dylib, "-target", target,
            "-module-name", "CmuxNextLiveCodePatch", "-Xlinker", "-undefined", "-Xlinker", "dynamic_lookup"]
    if sdk:
        link += ["-sdk", sdk]
    link_run = subprocess.run(link, capture_output=True, text=True)
    if link_run.returncode != 0:
        sys.stderr.write(link_run.stderr[-6000:])
        sys.exit("patch.py: the link failed")
    sign = subprocess.run(["codesign", "--force", "--timestamp=none", "--sign", opts.sign, dylib], capture_output=True, text=True)
    if sign.returncode != 0:
        sys.stderr.write(sign.stderr[-2000:])
        sys.exit(f"patch.py: codesign --sign {opts.sign} failed")
    if opts.sign == "-":
        print("patch.py: signed ad hoc: only a Debug or bench build loads it (a live code NIGHTLY needs "
              "--sign with the app's team identity)", file=sys.stderr)
    linked = time.time()
    os.makedirs(opts.live, exist_ok=True)
    # The sidecar first (`cmux live-code status` shows its commit and files), then the dylib.
    with open(os.path.join(opts.live, name[:-len(".dylib")] + ".json"), "w") as f:
        json.dump({"commit": source_commit(edited), "files": [os.path.relpath(p, source_root(edited) or "/") for p in edited]}, f)
    # Moved into place in one step, so the app never reads a half-written file.
    hidden = os.path.join(opts.live, "." + name)
    shutil.move(dylib, hidden)
    os.replace(hidden, os.path.join(opts.live, name))
    print(f"patch.py: {os.path.join(opts.live, name)} compile_s={compiled - started:.2f} link_s={linked - compiled:.2f} "
          f"started={started:.3f} files={len(objects)} kept_for_state={kept} optimized={int(opts.optimize)}")


if __name__ == "__main__":
    main()
