#!/usr/bin/env python3
"""The source key and output digest of the cmux-next web bundles.

build-web-bundles.sh stores `--stamp` in .web-bundles.key after a build and
skips the next build while it still matches. The stamp is three fields: the
source key (every file git sees, tracked and untracked but not ignored, under
the inputs below and under every path outside webviews/ that a webviews source
imports), the output digest (every file the build wrote) and the
version of bun on PATH. A changed input, an edited or deleted output or
another bun therefore makes it differ. `--verify-stamp` prints the first two
fields only: the Xcode verify phase runs with a PATH that may lack bun.

`--inputs` prints the pathspecs the source key hashes, one per line.

The source key includes the pinned Bun and Node toolchain identity. Set CMUX_WEB_BUN_VERSION or
CMUX_WEB_NODE_VERSION when a workflow computes the key so a toolchain change cannot reuse a
published manifest for the same sources.

Usage: web-bundle-key.py ROOT [--stamp | --verify-stamp | --source | --outputs | --inputs]
"""
import hashlib
import json
import os
import re
import subprocess
import sys

# What the builders read, besides the files outside webviews/ that a webviews
# source imports (imported_inputs below finds those). webviews/ includes its scripts, lockfile and
# xcstrings catalogs (not the strings tables: build output, ignored since #21946, made from those
# catalogs and the settings schema); schemas/settings is imported by the settings page and read
# by gen-strings.mjs; the xcstrings catalogs feed gen-strings.mjs; the What's New highlights feed
# gen-feature-tips.mjs (the agent pane's feature tips, build output gen-strings.mjs makes);
# marked.min.js is inlined into the webviews app's agent-session.html.
INPUTS = [
    "webviews",
    "schemas/settings",
    ":(glob)release-notes/next/highlights/*.md",
    "Resources/markdown-viewer/marked.min.js",
    "scripts/build-webviews-app.sh",
    "scripts/check-webviews-bun-version.sh",
    "scripts/cmux-next/build-agent-pane-web.sh",
    "scripts/cmux-next/build-agent-activity-web.sh",
    "scripts/cmux-next/build-pages-web.sh",
    "scripts/cmux-next/build-palette-ranker.sh",
    "scripts/cmux-next/build-optchat-inspector-web.sh",
    "scripts/cmux-next/build-web-bundles.sh",
    "scripts/cmux-next/web-bundle-key.py",
    ":(glob)Packages/macOS/CmuxNext/Sources/**/*.xcstrings",
]

# What the builders write (build-web-bundles.sh). The palette ranker is one file
# in a resource directory that holds other files.
OUTPUTS = [
    "Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane/Resources/agent-pane",
    "Packages/macOS/CmuxNext/Sources/CmuxNextPages/Resources/pages",
    "Packages/macOS/CmuxNext/Sources/CmuxNextAgentActivity/Resources/agent-activity",
    "Packages/macOS/CmuxNext/Sources/CmuxNextPalette/Resources/palette-ranker.js",
    "Resources/markdown-viewer/webviews-app",
    "Native/OptChat/optchat-chief/inspector/index.html",
]

IGNORED_NAMES = {".DS_Store"}

# The bundlers resolve relative specifiers in these files. A specifier that
# leaves webviews/ (the agent pane imports web/data/model-catalog/snapshot.json,
# the webviews app imports Resources/markdown-viewer/viewer-navigation.js) names
# an input as real as webviews/ itself. Tests, benches, the dev server, the
# acpmux dev preview (preview:dev / preview:build) and gallery entries
# (`*.gallery.ts(x)`, `*.gallery.css`: read only by the dev server and gallery:build) never
# reach a shipped bundle.
SCANNED_SUFFIXES = (".ts", ".tsx", ".mts", ".cts", ".js", ".jsx", ".mjs", ".cjs", ".css", ".html")
UNSCANNED = re.compile(
    r"(^webviews/(test|bench|dev-server)/)|(^webviews/src/agent-session/acpmux-preview/)|(\.(test|spec|gallery)\.[a-z]+$)")
SPECIFIER = re.compile(
    r"""(?:\bfrom|\bimport|\bimport\s*\(|@import|@source|\burl\(|\bnew\s+URL\()\s*["'`]?(\.{1,2}/[^"'`)\s]+)""")
# import.meta.glob("a") and import.meta.glob(["a", "b"], ...), across lines.
GLOB_CALL = re.compile(r"""import\.meta\.glob(?:<[^>]*>)?\(\s*(\[[^\]]*\]|["'`][^"'`]*["'`])""", re.S)
GLOB_STRING = re.compile(r"""["'`](!?\.{1,2}/[^"'`]+)["'`]""")
VITE_QUERY = re.compile(r"\?(raw|url|inline|worker|sharedworker|no-inline)(&.*)?$")
FILE_SUFFIXES = ("", ".ts", ".tsx", ".js", ".jsx", ".mjs", ".json")
INDEX_FILES = ("/index.ts", "/index.tsx", "/index.js")
BRACES = re.compile(r"\{([^{}]*)\}")


def expand_braces(pattern):
    m = BRACES.search(pattern)
    if not m:
        return [pattern]
    return [x for alt in m.group(1).split(",") for x in expand_braces(pattern[:m.start()] + alt + pattern[m.end():])]


def unresolved(message):
    """A specifier the key cannot follow. Builds go on (stderr only); the CI check
    (tests/test_web_bundle_key_inputs.sh) sets WEB_BUNDLE_KEY_STRICT=1 and fails."""
    if os.environ.get("WEB_BUNDLE_KEY_STRICT") == "1":
        sys.exit(f"web-bundle-key: {message}")
    print(f"web-bundle-key: warning: {message}", file=sys.stderr)


def resolve(root, target):
    """The file a bundler resolves `target` to (a file before a directory index), or the
    directory itself, or None."""
    for candidate in [target + s for s in FILE_SUFFIXES] + [target + s for s in INDEX_FILES]:
        if os.path.isfile(os.path.join(root, candidate)):
            return candidate
    return target if os.path.isdir(os.path.join(root, target)) else None


def git_files(root, pathspecs):
    if not pathspecs:
        return []
    listed = subprocess.run(
        ["git", "-C", root, "ls-files", "-z", "--cached", "--others", "--exclude-standard", "--", *pathspecs],
        check=True, capture_output=True).stdout.split(b"\0")
    return sorted({os.fsdecode(p) for p in listed if p})


def specifiers(text):
    for m in SPECIFIER.finditer(text):
        yield m.group(1)
    for m in GLOB_CALL.finditer(text):
        for g in GLOB_STRING.finditer(m.group(1)):
            yield g.group(1)


def imported_inputs(root):
    """Pathspecs outside webviews/ that a bundled webviews source imports, followed
    through the imported files themselves."""
    found = set()
    queue = [rel for rel in git_files(root, ["webviews"])
             if rel.endswith(SCANNED_SUFFIXES) and not UNSCANNED.search(rel)]
    seen = set(queue)
    while queue:
        rel = queue.pop()
        try:
            with open(os.path.join(root, rel), encoding="utf-8", errors="replace") as f:
                text = f.read()
        except OSError:
            continue
        for spec in specifiers(text):
            if spec.startswith("!"):
                continue
            spec = VITE_QUERY.sub("", spec.split("#", 1)[0])
            target = os.path.normpath(os.path.join(os.path.dirname(rel), spec))
            if target.startswith("..") or target == "webviews" or target.startswith("webviews/"):
                continue
            if "${" in target:
                unresolved(f"{rel} imports {spec}, a template the key cannot resolve; "
                           "import a literal path or add the directory to INPUTS")
                continue
            if any(c in target for c in "*?[{"):
                globs = [":(glob)" + g for g in expand_braces(target)]
                if not git_files(root, globs):
                    unresolved(f"{rel} imports {spec}, which matches no file")
                found.update(globs)
                continue
            path = resolve(root, target)
            if path is None:
                unresolved(f"{rel} imports {spec}, which resolves to no file ({target})")
                path = target
            found.add(path)
            if path not in seen and path.endswith(SCANNED_SUFFIXES) and os.path.isfile(os.path.join(root, path)):
                seen.add(path)
                queue.append(path)
    return sorted(found)


def source_inputs(root):
    return INPUTS + imported_inputs(root)


def file_digest(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def declared_bun_version(root):
    with open(os.path.join(root, "webviews/package.json"), encoding="utf-8") as f:
        package_manager = (json.load(f).get("devEngines") or {}).get("packageManager") or {}
    return package_manager.get("version", "1.4.4") if package_manager.get("name") == "bun" else "1.4.4"


def toolchain_identity(root):
    # Keep these defaults in one place: workflows export the same values before computing keys.
    bun = normalize_toolchain_version(os.environ.get("CMUX_WEB_BUN_VERSION", declared_bun_version(root)))
    node = normalize_toolchain_version(os.environ.get("CMUX_WEB_NODE_VERSION", "24.22.1"))
    return f"bun={bun}\nnode={node}\n"


def normalize_toolchain_version(value):
    """Normalize runtime version output for stable manifest comparisons."""
    return value.strip().removeprefix("v")


def manifest_matches_toolchain(manifest, bun, node):
    return all(
        normalize_toolchain_version(manifest.get(name, "")) == normalize_toolchain_version(expected)
        for name, expected in (("bun", bun), ("node", node))
    )


def source_key(root):
    h = hashlib.sha256()
    h.update(b"web-bundle-toolchain\0" + toolchain_identity(root).encode())
    for rel in git_files(root, source_inputs(root)):
        path = os.path.join(root, rel)
        # A tracked file deleted in the worktree is listed but absent.
        if os.path.isfile(path) and not os.path.islink(path):
            h.update(os.fsencode(rel) + b"\0" + file_digest(path).encode() + b"\n")
    return h.hexdigest()


def bun_version():
    try:
        return subprocess.run(["bun", "--version"], capture_output=True, text=True).stdout.strip() or "none"
    except FileNotFoundError:
        return "none"


def output_digest(root):
    h = hashlib.sha256()
    for top in OUTPUTS:
        base = os.path.join(root, top)
        if os.path.isfile(base):
            files = [base]
        elif os.path.isdir(base):
            files = []
            for d, dirs, names in os.walk(base):
                dirs.sort()
                files += [os.path.join(d, n) for n in sorted(names) if n not in IGNORED_NAMES]
        else:
            h.update(f"missing {top}\n".encode())
            continue
        if not files:
            h.update(f"empty {top}\n".encode())
        for path in files:
            rel = os.path.relpath(path, root)
            h.update(f"{rel}\0{file_digest(path)}\n".encode())
    return h.hexdigest()


def main(argv):
    if len(argv) < 2 or len(argv) > 3:
        print(__doc__.strip().splitlines()[-1], file=sys.stderr)
        return 2
    root, mode = argv[1], (argv[2] if len(argv) == 3 else "--stamp")
    if mode == "--source":
        print(source_key(root))
    elif mode == "--inputs":
        print("\n".join(source_inputs(root)))
    elif mode == "--outputs":
        print(output_digest(root))
    elif mode == "--stamp":
        print(f"{source_key(root)} {output_digest(root)} bun-{bun_version()}")
    elif mode == "--verify-stamp":
        print(f"{source_key(root)} {output_digest(root)}")
    else:
        print(f"unknown mode {mode}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
