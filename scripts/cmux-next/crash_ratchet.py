#!/usr/bin/env python3
"""Crash-class ratchet for cmux-next (plans/cmux-next/crash-elimination.md).

Counts the code patterns that can end the app or the daemon, per class and
per Swift module or Rust crate (so code can move between files), and compares
them with crash-safety-baseline.json next to this script. A module or crate
may never gain a hit of a class; fixing hits is free (run
--update-baseline to lower the baseline in the same commit). A line with a
reviewed `// crash-allow: <reason>` (Swift) or `// crash-allow: <reason>`
(Rust), on the line or the comment line above, does not count.

  Swift (Packages/macOS/CmuxNext/Sources and the Sources of every package in its
  `.package(path:)` closure, so code the app links is in scope, except third-party
  packages under vendor/; a module is keyed by its directory under Sources):
    force_unwrap      `x!` (a nil value traps)
    as_bang           `as!` (a failed cast traps)
    fatal_error       fatalError( outside a required init(coder:) or init(rootView:)
    precondition      precondition( / preconditionFailure( (trap in Release too)
    assume_isolated   MainActor.assumeIsolated (traps off the main actor); a hit with a
                      `// main-proof: <why the caller is on main>` comment does not count
    unowned           unowned references (trap after the owner is gone)
    iuo               implicitly unwrapped declarations (`var x: T!`)
    unchecked         nonisolated(unsafe) and @unchecked Sendable (data races)
    objc_selector     a non-override @objc func with a labeled parameter and no explicit
                      @objc(selector:) (Swift infers `mouseEnteredWith:` for
                      `mouseEntered(with:)`, and AppKit raised "unrecognized selector")
    dynamic_dispatch  NSSelectorFromString, Selector("..."), KVC value/setValue by key
                      (an unknown selector or key raises an Objective-C exception)
    env_write         setenv( / unsetenv( / putenv( / an assignment to environ. Not in
                      the baseline and not waived by crash-allow: only the call sites in
                      env-write-allowlist.json (path, call, count, reason) pass. libghostty
                      keeps a slice of environ from ghostty_init, so a write after launch
                      left it reading a NULL or freed entry (SIGSEGV, cx-9dh7). Children
                      get their variables through their spawn environment. At run time,
                      ProcessEnvironmentGuard.write refuses an allowed write after its freeze.
  Rust (cmux-tui/crates/*/src, code before an inline #[cfg(test)] module, no tests/ folders):
    unwrap            .unwrap()
    expect            .expect(
    panic_macro       panic!, unreachable!, todo!, unimplemented!
    exit              process::exit / process::abort

BAN mode (crash-allowlist.json next to this script): a class named in "banned"
("swift.<class>"; Rust classes are not bannable yet) is not in the baseline. Every hit fails, an inline
crash-allow does not waive it; only an "allow" entry {path, class, count, reason,
reviewer} passes that many hits in that file. Flip a class to banned in the commit
that brings it to zero (moving its reviewed crash-allow lines into the allowlist).

Usage: crash_ratchet.py [--repo ROOT] [--update-baseline]
Exit 1 when a module or crate gained a hit.
"""
import argparse
import subprocess
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
BASELINE = os.path.join(HERE, "crash-safety-baseline.json")
ALLOW = re.compile(r"//\s*crash-allow:\s*\S")

SWIFT = {
    "force_unwrap": re.compile(r"(?<![!=<>])[\w\)\]]!(?!=)(?=[\s\.\),\]\[;:]|$)"),
    "as_bang": re.compile(r"\bas!\s"),
    "fatal_error": re.compile(r"\bfatalError\("),
    "precondition": re.compile(r"\bprecondition(Failure)?\("),
    "assume_isolated": re.compile(r"\bassumeIsolated\b"),
    "unowned": re.compile(r"\bunowned\b"),
    "iuo": re.compile(r"\b(var|let)\s+\w+\s*:\s*[A-Z][\w\.]*(<[^>]*>)?!"),
    "unchecked": re.compile(r"nonisolated\(unsafe\)|@unchecked\s+Sendable"),
    "dynamic_dispatch": re.compile(
        r"\bNSSelectorFromString\(|\bSelector\(\"|\b(?:setValue|value)\((?:[^()]|\([^()]*\))*\bforKey(?:Path)?:"),
}
# Counted by objc_selector_hits (needs the declaration, which may span two lines).
SWIFT_KINDS = list(SWIFT) + ["objc_selector"]
OBJC_ATTR = re.compile(r"@objc(?![\w(])")
OBJC_FUNC = re.compile(r"\bfunc\s+[\w`]+\s*(?:<[^>]*>)?\s*\(")
OTHER_DECL = re.compile(r"\b(protocol|class|struct|enum|extension|var|let|init|subscript|case)\b")
MAIN_PROOF = re.compile(r"//\s*main-proof:\s*\S")
ALLOWLIST = os.path.join(HERE, "crash-allowlist.json")
APP_PACKAGE = "Packages/macOS/CmuxNext"
PACKAGE_PATH = re.compile(r"\.package\(\s*path:\s*\"([^\"]+)\"")
RUST = {
    "unwrap": re.compile(r"\.unwrap\(\)"),
    "expect": re.compile(r"\.expect\("),
    "panic_macro": re.compile(r"\b(panic|unreachable|todo|unimplemented)!\s*[\(\{\[]"),
    "exit": re.compile(r"\bprocess::(exit|abort)\("),
}
ENV_WRITE = re.compile(r"\b(setenv|unsetenv|putenv)\s*\(|\benviron\s*(\[[^\]]*\]\s*)?=(?!=)")
ENV_ALLOWLIST = os.path.join(HERE, "env-write-allowlist.json")
INLINE_TESTS = re.compile(r"#\[cfg\(test\)\]\s*(#\[[^\]]*\]\s*)*(pub(\([^)]*\))?\s+)?mod\s+\w+\s*\{")
UNREACHABLE_INIT = re.compile(r"\binit\??\((coder|rootView)\b")


def swift_code(line):
    # Drop a trailing comment when no string literal could contain "//".
    return line.split("//", 1)[0] if '"' not in line else line


def allowed(lines, index):
    return bool(ALLOW.search(lines[index]) or (index > 0 and ALLOW.search(lines[index - 1])))


def tracked_files(repo, root):
    """Files under ROOT that git tracks (absolute paths, sorted). Ignored and untracked
    files never count: build or sync output in a per-job tree made the ratchet red while
    every tracked file equalled the tip (2026-10-07). Outside a git checkout every file
    under ROOT is scanned, with a warning."""
    rel = os.path.relpath(root, repo)
    try:
        out = subprocess.run(["git", "-C", repo, "ls-files", "-z", "--", rel],
                             check=True, capture_output=True).stdout.decode("utf-8", "replace")
        return sorted(os.path.join(repo, p) for p in out.split("\0") if p)
    except (OSError, subprocess.CalledProcessError) as error:
        print(f"crash-ratchet: WARNING: {repo} is not a git checkout ({error}); scanning every file under {rel}, "
              "ignored build output included", file=sys.stderr)
        return sorted(os.path.join(d, n) for d, _, names in os.walk(root) for n in names)


def swift_source_roots(repo):
    """Sources/ of the app package and of every package in its `.package(path:)` closure
    (transitively), relative to REPO. Without the app's Package.swift (a partial tree),
    only its Sources/."""
    roots, seen, queue = [], set(), [APP_PACKAGE]
    while queue:
        pkg = os.path.normpath(queue.pop(0))
        # vendor/ is third-party source we do not edit (tracked as its own risk, not here).
        if pkg in seen or pkg.startswith("..") or pkg.split(os.sep)[0] == "vendor":
            continue
        seen.add(pkg)
        if os.path.isdir(os.path.join(repo, pkg, "Sources")):
            roots.append(os.path.join(pkg, "Sources"))
        manifest = os.path.join(repo, pkg, "Package.swift")
        if os.path.isfile(manifest):
            for dep in PACKAGE_PATH.findall(open(manifest, encoding="utf-8").read()):
                queue.append(os.path.join(pkg, dep))
    return roots


def objc_selector_hits(lines, index, code):
    """1 when LINE starts a non-override @objc func that has a labeled parameter and no
    explicit selector. The declaration may continue on the next line."""
    if not OBJC_ATTR.search(code):
        return 0
    decl = code[OBJC_ATTR.search(code).start():]
    if OTHER_DECL.search(decl) and not OBJC_FUNC.search(decl):
        return 0
    follow = index + 1
    while not OBJC_FUNC.search(decl) and not OTHER_DECL.search(decl) and follow < len(lines) and follow <= index + 2:
        decl += " " + swift_code(lines[follow]).strip()
        follow += 1
    match = OBJC_FUNC.search(decl)
    if not match or re.search(r"\boverride\b", decl[:match.start()]) or re.search(r"\boverride\b", code):
        return 0
    depth, start, params = 0, match.end(), None
    for pos in range(start, len(decl)):
        if decl[pos] in "([<":
            depth += 1
        elif decl[pos] in ")]>":
            if depth == 0:
                params = decl[start:pos]
                break
            depth -= 1
    if not params or not params.strip():
        return 0
    parts, depth, current = [], 0, ""
    for ch in params:
        if ch in "([<":
            depth += 1
        elif ch in ")]>":
            depth -= 1
        if ch == "," and depth == 0:
            parts.append(current)
            current = ""
        else:
            current += ch
    parts.append(current)
    for part in parts:
        names = part.split(":", 1)[0].split()
        if names and names[0] != "_":
            return 1
    return 0


def swift_line_hits(lines, index):
    """{kind: hits} for one Swift line (comment lines and crash-allow are the caller's)."""
    line = lines[index]
    code = swift_code(line)
    hits = {}
    for kind, pattern in SWIFT.items():
        found = len(pattern.findall(code))
        if not found:
            continue
        if kind == "fatal_error" and UNREACHABLE_INIT.search(" ".join(lines[max(0, index - 2):index + 1])):
            continue
        if kind == "assume_isolated" and (MAIN_PROOF.search(line) or (index > 0 and MAIN_PROOF.search(lines[index - 1]))):
            continue
        hits[kind] = found
    if objc_selector_hits(lines, index, code):
        hits["objc_selector"] = 1
    return hits


def scan_swift(repo, counts, banned_files=None):
    """Ratchet counts per module into COUNTS; hits of banned classes per file (crash-allow
    ignored) into BANNED_FILES {(kind, repo-relative path): hits}."""
    banned = banned_kinds("swift")
    for root in swift_source_roots(repo):
        sources = os.path.join(repo, root)
        for path in tracked_files(repo, sources):
            name = os.path.basename(path)
            if not name.endswith(".swift") or not os.path.isfile(path):
                continue
            rel = os.path.relpath(path, sources).split(os.sep)[0]  # the Swift module
            lines = open(path, encoding="utf-8", errors="replace").read().split("\n")
            for index, line in enumerate(lines):
                if line.lstrip().startswith("//"):
                    continue
                is_allowed = allowed(lines, index)
                for kind, hits in swift_line_hits(lines, index).items():
                    if kind in banned:
                        if banned_files is not None:
                            key = (kind, os.path.relpath(path, repo))
                            banned_files[key] = banned_files.get(key, 0) + hits
                        continue
                    if is_allowed:
                        continue
                    counts.setdefault(kind, {}).setdefault(rel, 0)
                    counts[kind][rel] += hits


def load_allowlist():
    if not os.path.exists(ALLOWLIST):
        return {"banned": [], "allow": []}
    data = json.load(open(ALLOWLIST))
    data.setdefault("banned", [])
    data.setdefault("allow", [])
    return data


def banned_kinds(lang):
    return {entry.split(".", 1)[1] for entry in load_allowlist()["banned"] if entry.startswith(lang + ".")}


def module_of(path):
    parts = path.split(os.sep)
    return parts[parts.index("Sources") + 1] if "Sources" in parts else path


def check_banned(banned_files):
    """Lines "swift <module>: <kind> <allowed> -> <hits>" for files over their allowlist
    entry, plus notes for entries that allow more than the file has."""
    allow = {}
    for entry in load_allowlist()["allow"]:
        lang, kind = entry["class"].split(".", 1)
        for field in ("path", "count", "reason", "reviewer"):
            if not entry.get(field):
                raise SystemExit(f"crash-ratchet: allowlist entry without {field}: {entry}")
        allow[(kind, entry["path"])] = allow.get((kind, entry["path"]), 0) + int(entry["count"])
    over, notes = {}, []
    for (kind, path), hits in sorted(banned_files.items()):
        allowed_hits = allow.get((kind, path), 0)
        if hits > allowed_hits:
            key = (module_of(path), kind)
            a, h = over.get(key, (0, 0))
            over[key] = (a + allowed_hits, h + hits)
            print(f"crash-ratchet: banned {kind} in {path}: {hits} hit(s), {allowed_hits} allowed by crash-allowlist.json")
    for (kind, path), allowed_hits in sorted(allow.items()):
        if banned_files.get((kind, path), 0) < allowed_hits:
            notes.append(f"crash-allowlist.json allows {allowed_hits} {kind} in {path} but it has "
                         f"{banned_files.get((kind, path), 0)}: lower the entry")
    return [f"swift {m}: {k} {a} -> {h}" for (m, k), (a, h) in sorted(over.items())], notes


def scan_env_writes(repo):
    """Process environment writes in Swift sources beyond env-write-allowlist.json:
    ["<swift module> (<path>: <call> <allowed> -> <found>)", ...]. A crash-allow comment
    does not waive one; only the allowlist (with its reason) does."""
    sources = os.path.join(repo, "Packages/macOS/CmuxNext/Sources")
    allow = json.load(open(ENV_ALLOWLIST)) if os.path.exists(ENV_ALLOWLIST) else {}
    found = {}
    for path in tracked_files(repo, sources):
        if not path.endswith(".swift") or not os.path.isfile(path):
            continue
        rel = os.path.relpath(path, repo)
        for line in open(path, encoding="utf-8").read().split("\n"):
            if line.lstrip().startswith("//"):
                continue
            for match in ENV_WRITE.finditer(swift_code(line)):
                call = match.group(1) or "environ="
                found[(rel, call)] = found.get((rel, call), 0) + 1
    over = {}
    for (rel, call), hits in sorted(found.items()):
        allowed_hits = allow.get(rel, {}).get(call, 0)
        if hits > allowed_hits:
            module = os.path.relpath(rel, "Packages/macOS/CmuxNext/Sources").split(os.sep)[0]
            over.setdefault(module, []).append(f"{rel}: {call} {allowed_hits} -> {hits}")
    return over


def scan_rust(repo, counts):
    crates = os.path.join(repo, "cmux-tui/crates")
    skipped_dirs = {"target", "tests", "benches", "examples", "node_modules", "fixtures"}
    for path in tracked_files(repo, crates):
        dirpath, name = os.path.split(path)
        parts = os.path.relpath(dirpath, crates).split(os.sep)
        if skipped_dirs.intersection(parts) or os.sep + "src" not in dirpath or not os.path.isfile(path):
            continue
        if not name.endswith(".rs") or name in ("tests.rs",) or name.endswith("_tests.rs") or name.endswith("_test.rs"):
            continue
        rel = os.path.relpath(path, crates).split(os.sep)[0]  # the crate
        text = open(path, encoding="utf-8", errors="replace").read()
        # Inline test modules (`#[cfg(test)] mod x {`) are cut; a
        # `#[cfg(test)] mod x;` declaration is not code.
        inline = INLINE_TESTS.search(text)
        lines = (text if not inline else text[:inline.start()]).split("\n")
        for index, line in enumerate(lines):
            stripped = line.lstrip()
            if stripped.startswith("//") or allowed(lines, index):
                continue
            code = line.split("//", 1)[0] if '"' not in line else line
            for kind, pattern in RUST.items():
                hits = len(pattern.findall(code))
                if hits:
                    counts.setdefault(kind, {}).setdefault(rel, 0)
                    counts[kind][rel] += hits


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repo", default=os.path.abspath(os.path.join(HERE, "../..")))
    parser.add_argument("--update-baseline", action="store_true")
    opts = parser.parse_args()
    counts = {"swift": {}, "rust": {}}
    banned_files = {}
    scan_swift(opts.repo, counts["swift"], banned_files)
    scan_rust(opts.repo, counts["rust"])
    if opts.update_baseline:
        with open(BASELINE, "w") as out:
            json.dump(counts, out, indent=1, sort_keys=True)
            out.write("\n")
        totals = {f"{lang}.{kind}": sum(files.values()) for lang, kinds in counts.items() for kind, files in kinds.items()}
        print("crash-ratchet: baseline written: " + ", ".join(f"{k} {v}" for k, v in sorted(totals.items())))
        return 0
    baseline = json.load(open(BASELINE)) if os.path.exists(BASELINE) else {}
    grown, shrunk = [], 0
    for lang, kinds in counts.items():
        for kind, files in kinds.items():
            known = baseline.get(lang, {}).get(kind, {})
            for rel, hits in sorted(files.items()):
                if hits > known.get(rel, 0):
                    grown.append(f"{lang} {rel}: {kind} {known.get(rel, 0)} -> {hits}")
        for kind, files in baseline.get(lang, {}).items():
            if kind in banned_kinds(lang):
                continue
            for rel, hits in files.items():
                if counts[lang].get(kind, {}).get(rel, 0) < hits:
                    shrunk += 1
    banned_over, banned_notes = check_banned(banned_files)
    grown.extend(banned_over)
    for line in banned_notes:
        print("crash-ratchet: note: " + line)
    env_over = scan_env_writes(opts.repo)
    for module, details in sorted(env_over.items()):
        hits = sum(int(d.rsplit(" ", 1)[1]) for d in details)
        grown.append(f"swift {module}: env_write 0 -> {hits}")
        for detail in details:
            print("crash-ratchet: env_write " + detail + " (not in scripts/cmux-next/env-write-allowlist.json)")
    for line in grown:
        print("crash-ratchet: " + line)
    if grown:
        print(f"crash-ratchet: {len(grown)} module(s) or crate(s) gained a crash-class hit (plans/cmux-next/crash-elimination.md). "
              "Remove it, or add a reviewed `// crash-allow: <reason>` (banned classes: only a reviewed "
              "scripts/cmux-next/crash-allowlist.json entry; env_write: never, pass the value in the child's "
              "spawn environment instead).")
        return 1
    note = f"; {shrunk} count(s) went down: run scripts/cmux-next/crash_ratchet.py --update-baseline" if shrunk else ""
    print(f"crash-ratchet: ok{note}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
