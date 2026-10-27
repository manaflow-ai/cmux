#!/usr/bin/env python3
"""The tree scans and artifact reads of stability-final.sh that a grep cannot do (p10-stability-151).

  stability_final_scan.py NAME [ARG...] [--list]

Each NAME prints one value on stdout: a count, or `missing` / `truncated` / `error` when it cannot
measure. --list also prints the items it counted on stderr. Read-only: it writes no file (run it
with python3 -B).

  memory-safety            closure Swift targets that do not get both `.strictMemorySafety()` and
                           `.treatWarning("StrictMemorySafety", as: .error)` from stability-settings.json
                           (apply-stability-settings.py's plan, per target; a vendored package's targets
                           never get them, so they count)
  settings-stale           closure manifests that differ from the rows (apply-stability-settings.py --check)
  ffi-unguarded            `extern "C" fn` exports of the 4 FFI crates whose body neither calls
                           `ffi_boundary(` nor carries an `ffi-nopanic:` reason (inline #[cfg(test)]
                           modules and test files left out)
  unsafe-impl-undocumented `unsafe impl Send/Sync` whose comment block above (shared by adjacent impls)
                           lacks `SAFETY` or a test reference (`test: NAME` or `tests::NAME`)
  forbid-unsafe-missing    cmux-tui crates with no unsafe code whose crate roots lack
                           `#![forbid(unsafe_code)]` (or Cargo.toml `unsafe_code = "forbid"`)
  supervise-unnamed        `supervise_thread/_task(_restarting)` calls whose policy argument is not Fatal or
                           Restart, or whose shutdown argument is not a `ShutdownBehavior::` value (a
                           parameter declared with that type passes)
  fuzz-targets             Rust fuzz targets: [[bin]] entries of the fuzz Cargo.toml files, not selftest_
  fuzz-suites              Swift suites (`@Suite`, XCTestCase subclasses) in test files that import
                           CmuxFuzzSupport, outside CmuxFuzzSupport's own tests
  rust-sanitize DIR        expected sanitize.sh runs (mode, crate, os) missing from DIR/runs*.jsonl or not
                           green, plus the lines of DIR/findings*.jsonl
  stability-sig ISSUES PRS OWNED
                           open stability-sig issues older than 24 h that no open PR (any base) references
                           by #N, outside the OWNED issue numbers (comma list)
"""

from __future__ import annotations

import datetime as dt
import fnmatch
import importlib.util
import json
import re
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent

FFI_CRATES = ("cmux-app-ffi", "cmux-rd-ffi", "cmux-layout-reducer-ffi", "cmux-palette-ranker")
FUZZ_MANIFESTS = ("cmux-tui/fuzz/Cargo.toml", "Native/DiffSidecar/fuzz/Cargo.toml", "Native/OptChat/fuzz/Cargo.toml",
                  "cmux-next-ios/rust/fuzz/Cargo.toml")
UNSAFE_IMPL_ROOTS = ("cmux-tui/crates/*/src/**", "Native/**", "cmux-next-ios/rust/**")
MEMORY_SAFETY = (".strictMemorySafety()", '.treatWarning("StrictMemorySafety", as: .error)')

# sanitize.sh's defaults (cmux-tui/scripts/sanitize.sh SANITIZER_CRATES_*, MIRI_CRATES); Miri on any OS.
SANITIZER_MODES = ("address", "thread", "leak")
SANITIZER_CRATES = {"linux": ("cmux-tui-core", "acpmux", "cmux-holder", "cmux-pty", "ghostty-vt"),
                    "macos": ("cmux-pty", "cmux-holder")}
MIRI_CRATES = ("cmux-pane-protocol", "cmux-remote-protocol", "cmux-rd-proto", "cmux-layout-reducer")
GREEN_RESULTS = ("pass", "unsupported")  # cmux-tui/sanitize/collect_findings.py
LIST_LIMIT = 1000  # the --limit the gh list artifacts are made with


def tracked(*pathspecs: str) -> list[str]:
    out = subprocess.run(["git", "-C", str(ROOT), "ls-files", "-z", "--", *pathspecs], capture_output=True,
                         text=True, check=True).stdout
    return sorted(path for path in out.split("\0") if path)


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8", errors="replace")


def code_of(line: str) -> str:
    """LINE without a trailing `//` comment (string contents are not parsed; good enough for these scans)."""
    at = line.find("//")
    return line if at < 0 else line[:at]


def matching(text: str, open_at: int, opener: str, closer: str) -> int:
    """The offset just past the bracket that closes TEXT[OPEN_AT], or len(TEXT)."""
    depth = 0
    for index in range(open_at, len(text)):
        if text[index] == opener:
            depth += 1
        elif text[index] == closer:
            depth -= 1
            if depth == 0:
                return index + 1
    return len(text)


CFG_TEST_MOD = re.compile(r"#\[cfg\(test\)\]\s*(?:#\[[^\]]*\]\s*)*(?:pub(?:\([^)]*\))?\s+)?mod\s+\w+\s*\{")


def without_test_modules(text: str) -> str:
    """TEXT with every inline `#[cfg(test)] mod x { ... }` blanked (newlines kept)."""
    out, last = [], 0
    for match in CFG_TEST_MOD.finditer(text):
        if match.start() < last:
            continue
        end = matching(text, match.end() - 1, "{", "}")
        out.append(text[last:match.start()])
        out.append(re.sub(r"[^\n]", " ", text[match.start():end]))
        last = end
    out.append(text[last:])
    return "".join(out)


def is_test_file(path: str) -> bool:
    name = Path(path).name
    return "/tests/" in path or name == "tests.rs" or name.endswith("_tests.rs")


# ---------------------------------------------------------------- check 9: FFI exports
EXPORT = re.compile(r'\bextern\s+"C"\s+fn\s+(\$?\w+)')


def unguarded_exports(text: str) -> list[str]:
    """Names of the `extern "C" fn` items of TEXT whose body has neither `ffi_boundary(` nor `ffi-nopanic:`."""
    text = without_test_modules(text)
    lines = text.split("\n")
    starts = [0]
    for line in lines:
        starts.append(starts[-1] + len(line) + 1)
    found = []
    for number, line in enumerate(lines):
        for match in EXPORT.finditer(code_of(line)):
            at = starts[number] + match.end()
            depth, body_at = 0, None
            for index in range(at, len(text)):
                char = text[index]
                if char == "(":
                    depth += 1
                elif char == ")":
                    depth -= 1
                elif depth == 0 and char == ";":
                    break  # a declaration, not an export
                elif depth == 0 and char == "{":
                    body_at = index
                    break
            if body_at is None:
                continue
            body = text[body_at:matching(text, body_at, "{", "}")]
            if "ffi_boundary(" not in body and "ffi-nopanic:" not in body:
                found.append(match.group(1))
    return found


def ffi_unguarded() -> list[str]:
    items = []
    for path in tracked(*(f"cmux-tui/crates/{crate}/src/**" for crate in FFI_CRATES)):
        if path.endswith(".rs") and not is_test_file(path):
            items += [f"{path}: {name}" for name in unguarded_exports(read(path))]
    return items


# ---------------------------------------------------------------- check 11: unsafe impl Send/Sync
UNSAFE_IMPL = re.compile(r"^\s*unsafe\s+impl\b.*\b(?:Send|Sync)\b.*\bfor\b")
TEST_REFERENCE = re.compile(r"\btests?(?:::\w+|:\s*\S)")


def undocumented_impls(text: str) -> list[int]:
    """1-based lines of TEXT's `unsafe impl Send/Sync` whose comment block above lacks SAFETY or a test reference.
    The block runs up over comments, attributes and adjacent unsafe impls, so `// SAFETY: as for Send` and two
    impls under one comment share it."""
    lines = text.split("\n")
    bad = []
    for number, line in enumerate(lines):
        if not UNSAFE_IMPL.match(line):
            continue
        comments, index = [], number - 1
        while index >= 0:
            above = lines[index].strip()
            if above.startswith("//"):
                comments.append(above)
            elif not (above.startswith("#[") or UNSAFE_IMPL.match(lines[index])):
                break
            index -= 1
        block = "\n".join(comments)
        if "SAFETY" not in block or not TEST_REFERENCE.search(block):
            bad.append(number + 1)
    return bad


def unsafe_impl_undocumented() -> list[str]:
    return [f"{path}:{line}" for path in tracked(*UNSAFE_IMPL_ROOTS) if path.endswith(".rs")
            for line in undocumented_impls(read(path))]


# ---------------------------------------------------------------- check 11: forbid(unsafe_code)
UNSAFE_CODE = re.compile(r"\bunsafe\s*(?:\{|fn\b|impl\b|extern\b|trait\b)|#\[\s*(?:unsafe\s*\(|no_mangle|export_name|"
                         r"link_section)")
FORBID = re.compile(r"#!\[\s*forbid\s*\([^)]*\bunsafe_code\b")
CARGO_FORBID = re.compile(r'^\s*unsafe_code\s*=\s*(?:"forbid"|\{[^}]*level\s*=\s*"forbid")', re.M)


def uses_unsafe(texts: list[str]) -> bool:
    return any(UNSAFE_CODE.search(code_of(line)) for text in texts for line in text.split("\n")
               if not line.lstrip().startswith("//"))


def forbid_unsafe_missing() -> list[str]:
    files = tracked("cmux-tui/crates/*/Cargo.toml", "cmux-tui/crates/*/src/**")
    crates = sorted({path.split("/")[2] for path in files if path.endswith("/Cargo.toml") and path.count("/") == 3})
    missing = []
    for crate in crates:
        base = f"cmux-tui/crates/{crate}"
        sources = [path for path in files if path.startswith(f"{base}/src/") and path.endswith(".rs")]
        if not sources or uses_unsafe([read(path) for path in sources]):
            continue
        if CARGO_FORBID.search(read(f"{base}/Cargo.toml")):
            continue
        roots = [path for path in sources if path in (f"{base}/src/lib.rs", f"{base}/src/main.rs")
                 or fnmatch.fnmatch(path, f"{base}/src/bin/*.rs") and path.count("/") == 5
                 or fnmatch.fnmatch(path, f"{base}/src/bin/*/main.rs")]
        lacking = [path for path in roots if not FORBID.search(read(path))]
        if lacking or not roots:
            missing.append(f"{crate}: {', '.join(lacking) or 'no crate root'}")
    return missing


# ---------------------------------------------------------------- check 10: supervise_* calls
SUPERVISE_CALL = re.compile(r"(?<!fn )\bsupervise_(?:thread|task)(?:_restarting)?\s*\(")


def top_level_args(call: str) -> list[str]:
    """The top-level comma-separated arguments of CALL, which starts just after its `(`."""
    args, depth, current = [], 0, []
    for char in call:
        if char in "([{":
            depth += 1
        elif char in ")]}":
            if depth == 0:
                break
            depth -= 1
        if char == "," and depth == 0:
            args.append("".join(current).strip())
            current = []
            continue
        current.append(char)
    tail = "".join(current).strip()
    if tail:
        args.append(tail)
    return args


def unnamed_supervise_calls(text: str) -> list[int]:
    """1-based lines of TEXT's supervise_* calls that do not name a policy and a ShutdownBehavior."""
    code = "\n".join(code_of(line) for line in text.split("\n"))
    bad = []
    for match in SUPERVISE_CALL.finditer(code):
        args = top_level_args(code[match.end():])
        policy, shutdown = (args[1], args[2]) if len(args) >= 3 else ("", "")

        def declared(arg: str, types: str) -> bool:
            return bool(re.fullmatch(r"\w+", arg)) and bool(re.search(rf"\b{arg}\s*:\s*(?:{types})\b", code))

        policy_ok = bool(re.search(r"\b(?:Fatal|Restart)\b", policy)) or declared(policy, "Fatal|Restart")
        shutdown_ok = "ShutdownBehavior::" in shutdown or declared(shutdown, "ShutdownBehavior")
        if not (policy_ok and shutdown_ok):
            bad.append(code.count("\n", 0, match.start()) + 1)
    return bad


def supervise_unnamed() -> list[str]:
    return [f"{path}:{line}" for path in tracked("cmux-tui/crates/*/src/**") if path.endswith(".rs")
            for line in unnamed_supervise_calls(read(path))]


# ---------------------------------------------------------------- check 4: settings per target
def lander():
    spec = importlib.util.spec_from_file_location("apply_stability_settings", HERE / "apply-stability-settings.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module  # dataclasses resolve their annotations through sys.modules
    spec.loader.exec_module(module)
    return module


def memory_safety() -> list[str]:
    settings = lander()
    tree = settings.WorkTree(ROOT)
    plan = settings.plan(tree, settings.load_rows(tree))
    missing = []
    for package in settings.closure(tree):
        this = plan.packages[package]
        carrying = settings.carriers(tree.read(f"{package}/{settings.MANIFEST}") or "")
        vendored = tree.has_file(f"{package}/{settings.VENDORED_MARKER}")
        for target in settings.swift_targets(tree, package):
            effective = set((this.shared if target in carrying else []) + this.swift.get(target, []))
            if vendored or not set(MEMORY_SAFETY) <= effective:
                missing.append(f"{package} {target}" + (" (vendored)" if vendored else ""))
    return missing


def settings_stale() -> list[str]:
    settings = lander()
    problems, _ = settings.check(settings.WorkTree(ROOT))
    return problems


# ---------------------------------------------------------------- check 15: fuzz inventory
def fuzz_targets() -> list[str]:
    names = []
    for manifest in FUZZ_MANIFESTS:
        if not (ROOT / manifest).is_file():
            continue
        in_bin = False
        for line in read(manifest).split("\n"):
            stripped = line.strip()
            if stripped.startswith("["):
                in_bin = stripped == "[[bin]]"
                continue
            found = re.match(r'name\s*=\s*"([^"]+)"', stripped)
            if in_bin and found and not found.group(1).startswith("selftest_"):
                names.append(f"{manifest}: {found.group(1)}")
    return names


SUITE = re.compile(r"^\s*@Suite\b|:\s*XCTestCase\b")


def fuzz_suites() -> list[str]:
    suites = []
    for path in tracked("Packages/**/Tests/**/*.swift"):
        if path.startswith("Packages/Shared/CmuxFuzzSupport/"):
            continue
        text = read(path)
        if not re.search(r"^\s*(?:@testable\s+)?import\s+CmuxFuzzSupport\b", text, re.M):
            continue
        suites += [f"{path}:{number + 1}" for number, line in enumerate(text.split("\n"))
                   if not line.lstrip().startswith("//") and SUITE.search(code_of(line))]
    return suites


# ---------------------------------------------------------------- check 14: Rust sanitizer runs
def jsonl(paths: list[Path]) -> list[dict]:
    rows = []
    for path in paths:
        for line in path.read_text(encoding="utf-8", errors="replace").split("\n"):
            if line.strip():
                rows.append(json.loads(line))
    return rows


def rust_sanitize(folder: str) -> list[str] | None:
    """The expected runs that are missing or not green, and one item per finding; None without a runs file."""
    directory = Path(folder)
    runs_files = sorted(directory.glob("runs*.jsonl"))
    if not runs_files:
        return None
    runs = jsonl(runs_files)
    expected = [(mode, crate, os_name) for os_name, crates in SANITIZER_CRATES.items()
                for mode in SANITIZER_MODES for crate in crates]
    expected += [("miri", crate, None) for crate in MIRI_CRATES]
    items = []
    for mode, crate, os_name in expected:
        rows = [row for row in runs if row.get("tool") == mode and row.get("crate") == crate
                and (os_name is None or row.get("os") == os_name)]
        if not rows:
            items.append(f"{mode} {crate} {os_name or 'any os'}: no run")
        elif any(row.get("result") not in GREEN_RESULTS or row.get("findings") for row in rows):
            items.append(f"{mode} {crate} {os_name or 'any os'}: {sorted({row.get('result') for row in rows})}")
    for finding in jsonl(sorted(directory.glob("findings*.jsonl"))):
        items.append(f"finding {finding.get('tool')} {finding.get('crate')}: {finding.get('hash12', finding.get('exception'))}")
    return items


# ---------------------------------------------------------------- check 19: stability-sig issues
def stability_sig(issues_path: str, prs_path: str, owned: str) -> list[str] | str:
    try:
        issues = json.loads(Path(issues_path).read_text(encoding="utf-8"))
        prs = json.loads(Path(prs_path).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return "missing"
    if not isinstance(issues, list) or not isinstance(prs, list):
        return "missing"
    if len(issues) >= LIST_LIMIT or len(prs) >= LIST_LIMIT:
        return "truncated"
    owned_numbers = {part.strip() for part in owned.split(",") if part.strip()}
    texts = [f"{pr.get('title') or ''}\n{pr.get('body') or ''}" for pr in prs]
    cutoff = time.time() - 86400
    stale = []
    for issue in issues:
        number = str(issue.get("number"))
        created = dt.datetime.fromisoformat(str(issue.get("createdAt")).replace("Z", "+00:00")).timestamp()
        if created >= cutoff or number in owned_numbers:
            continue
        reference = re.compile(rf"(?:#|/issues/){number}\b")
        if not any(reference.search(text) for text in texts):
            stale.append(f"#{number}")
    return stale


SCANS = {
    "memory-safety": memory_safety,
    "settings-stale": settings_stale,
    "ffi-unguarded": ffi_unguarded,
    "unsafe-impl-undocumented": unsafe_impl_undocumented,
    "forbid-unsafe-missing": forbid_unsafe_missing,
    "supervise-unnamed": supervise_unnamed,
    "fuzz-targets": fuzz_targets,
    "fuzz-suites": fuzz_suites,
}


def main(argv: list[str]) -> int:
    show = "--list" in argv
    args = [arg for arg in argv if arg != "--list"]
    if not args:
        print(__doc__, file=sys.stderr)
        return 2
    name, rest = args[0], args[1:]
    try:
        if name in SCANS and not rest:
            items = SCANS[name]()
        elif name == "rust-sanitize" and len(rest) == 1:
            items = rust_sanitize(rest[0])
        elif name == "stability-sig" and len(rest) == 3:
            items = stability_sig(*rest)
        else:
            print(__doc__, file=sys.stderr)
            return 2
    except Exception as error:  # a scan that cannot measure prints error, which misses its target
        print(f"stability_final_scan {name}: {error}", file=sys.stderr)
        print("error")
        return 0
    if items is None:
        print("missing")
    elif isinstance(items, str):
        print(items)
    else:
        print(len(items))
        if show:
            print("\n".join(items), file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
