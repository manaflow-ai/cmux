#!/usr/bin/env python3
"""Crash-class ratchet for cmux-next (plans/cmux-next/crash-elimination.md).

Counts the code patterns that can end the app or the daemon, per class and
per Swift module or Rust crate (so code can move between files), and compares
them with crash-safety-baseline.json next to this script. A module or crate
may never gain a hit of a class; fixing hits is free (run
--update-baseline to lower the baseline in the same commit). A line with a
reviewed `// crash-allow: <reason>` (Swift) or `// crash-allow: <reason>`
(Rust), on the line or the comment line above, does not count.

  Swift (Packages/macOS/CmuxNext/Sources, and the Sources of every root in
  mobile-scan-roots.txt next to this script, keyed by target):
    force_unwrap      `x!` (a nil value traps)
    as_bang           `as!` (a failed cast traps)
    fatal_error       fatalError( outside a required init(coder:) or init(rootView:)
    precondition      precondition( / preconditionFailure( (trap in Release too)
    assume_isolated   MainActor.assumeIsolated (traps off the main actor)
    unowned           unowned references (trap after the owner is gone)
    iuo               implicitly unwrapped declarations (`var x: T!`)
    unchecked         nonisolated(unsafe) and @unchecked Sendable (data races)
  Rust (cmux-tui/crates/*/src, code before an inline #[cfg(test)] module, no tests/ folders):
    unwrap            .unwrap()
    expect            .expect(
    panic_macro       panic!, unreachable!, todo!, unimplemented!
    exit              process::exit / process::abort

Usage: crash_ratchet.py [--repo ROOT] [--update-baseline]
Exit 1 when a module or crate gained a hit.
"""
import argparse
import json
import os
import re
import subprocess
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
}
RUST = {
    "unwrap": re.compile(r"\.unwrap\(\)"),
    "expect": re.compile(r"\.expect\("),
    "panic_macro": re.compile(r"\b(panic|unreachable|todo|unimplemented)!\s*[\(\{\[]"),
    "exit": re.compile(r"\bprocess::(exit|abort)\("),
}
INLINE_TESTS = re.compile(r"#\[cfg\(test\)\]\s*(#\[[^\]]*\]\s*)*(pub(\([^)]*\))?\s+)?mod\s+\w+\s*\{")
UNREACHABLE_INIT = re.compile(r"\binit\??\((coder|rootView)\b")
ENV_WRITE = re.compile(r"\b(setenv|unsetenv|putenv)\s*\(|\benviron\s*(\[[^\]]*\]\s*)?=(?!=)")
ENV_ALLOWLIST = os.path.join(HERE, "env-write-allowlist.json")


def swift_code(line):
    # Drop a trailing comment when no string literal could contain "//".
    return line.split("//", 1)[0] if '"' not in line else line


def allowed(lines, index):
    return bool(ALLOW.search(lines[index]) or (index > 0 and ALLOW.search(lines[index - 1])))


def swift_sources(repo):
    yield os.path.join(repo, "Packages/macOS/CmuxNext/Sources")
    with open(os.path.join(HERE, "mobile-scan-roots.txt"), encoding="utf-8") as handle:
        for raw in handle:
            entry = raw.strip()
            if entry and not entry.startswith("#"):
                yield os.path.join(repo, entry, "Sources")


def tracked_files(repo, root):
    """Files under ROOT that git tracks; ignored build output never counts."""
    rel = os.path.relpath(root, repo)
    try:
        out = subprocess.run(["git", "-C", repo, "ls-files", "-z", "--", rel],
                             check=True, capture_output=True).stdout.decode("utf-8", "replace")
        return sorted(os.path.join(repo, path) for path in out.split("\0") if path)
    except (OSError, subprocess.CalledProcessError) as error:
        print(f"crash-ratchet: WARNING: {repo} is not a git checkout ({error}); scanning every file under {rel}",
              file=sys.stderr)
        return sorted(os.path.join(directory, name)
                      for directory, _, names in os.walk(root) for name in names)


def scan_swift(repo, counts):
    for sources in swift_sources(repo):
        for path in tracked_files(repo, sources):
            name = os.path.basename(path)
            if not name.endswith(".swift") or not os.path.isfile(path):
                continue
            rel = os.path.relpath(path, sources).split(os.sep)[0]  # the Swift module
            lines = open(path, encoding="utf-8").read().split("\n")
            for index, line in enumerate(lines):
                if line.lstrip().startswith("//") or allowed(lines, index):
                    continue
                code = swift_code(line)
                for kind, pattern in SWIFT.items():
                    hits = len(pattern.findall(code))
                    if kind == "fatal_error" and hits:
                        context = " ".join(lines[max(0, index - 2):index + 1])
                        if UNREACHABLE_INIT.search(context):
                            continue
                    if hits:
                        counts.setdefault(kind, {}).setdefault(rel, 0)
                        counts[kind][rel] += hits


def scan_env_writes(repo):
    """Reject new process-environment writes outside the reviewed allowlist."""
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
    for dirpath, dirs, files in os.walk(crates):
        dirs[:] = [d for d in dirs if d not in ("target", "tests", "benches", "examples", "node_modules", "fixtures")]
        if os.sep + "src" not in dirpath:
            continue
        for name in sorted(files):
            if not name.endswith(".rs") or name in ("tests.rs",) or name.endswith("_tests.rs") or name.endswith("_test.rs"):
                continue
            path = os.path.join(dirpath, name)
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
    scan_swift(opts.repo, counts["swift"])
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
            for rel, hits in files.items():
                if counts[lang].get(kind, {}).get(rel, 0) < hits:
                    shrunk += 1
    env_over = scan_env_writes(opts.repo)
    for module, details in sorted(env_over.items()):
        hits = sum(int(detail.rsplit(" ", 1)[1]) for detail in details)
        grown.append(f"swift {module}: env_write 0 -> {hits}")
        for detail in details:
            print("crash-ratchet: env_write " + detail + " (not in scripts/cmux-next/env-write-allowlist.json)")
    for line in grown:
        print("crash-ratchet: " + line)
    if grown:
        print(f"crash-ratchet: {len(grown)} module(s) or crate(s) gained a crash-class hit (plans/cmux-next/crash-elimination.md). "
              "Remove it, or add a reviewed `// crash-allow: <reason>` (env_write: never; pass the value in the child's spawn environment instead).")
        return 1
    note = f"; {shrunk} count(s) went down: run scripts/cmux-next/crash_ratchet.py --update-baseline" if shrunk else ""
    print(f"crash-ratchet: ok{note}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
