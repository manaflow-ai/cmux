"""Move top-level inline `#[cfg(test)] mod NAME { .. }` blocks of Rust files into sibling files declared with #[path].

The convention of cmux#38898: `mod tests { .. }` in src/a/foo.rs becomes
    #[cfg(test)]
    #[path = "foo_tests.rs"]
    mod tests;
with the body in src/a/foo_tests.rs, one indent level less; lines that continue a string literal are untouched.
lib.rs, main.rs and mod.rs put a `tests` module in tests.rs. A module named X_tests goes to <stem>_X_tests.rs;
any other name to <stem>_<name>_tests.rs, so every new file ends in `_tests.rs` (or is `tests.rs`). A file directly
in src/bin, examples, benches or tests puts its tests in <stem>/, where Cargo does not make a target of them.

Skipped: blocks not at column 0, blocks holding `mod x;`, `#[path`, `file!()`, `line!()`, `include!(`, and files
whose target already exists. Each move is checked: the new file plus the declaration equal the old block with
only leading indentation removed.

After a run, the checks that count lines per source file see the move (cmux#43353): lower what
check-no-raw-spawn.py and check-no-process-scan.py name, move tests/fleet-rule-allowlist.json rows to the new
_tests.rs files, re-count acpmux's single_shot_list_tests tables, and keep a `serialized by NAME` static beside its
hook (the test-hooks check wants both in one file).

usage: scripts/cmux-next/move-inline-tests.py [--apply] [--min-bytes N] FILE...   (prints one line per move and a total)
"""
import os
import re
import sys

START = re.compile(r"^#\[cfg\(test\)\]\n((?:#\[[^\n]*\]\n)*)(?:pub(?:\([^)\n]*\))? )?mod (\w+) \{\n", re.M)
UNSAFE = re.compile(r"^\s*(?:pub(?:\([^)]*\))?\s+)?mod \w+;|#\[path|\bfile!\(|\bline!\(|\binclude!\(", re.M)


def lex_end(text, i):
    """Index just past the `}` closing the block whose body starts at i, and the set of offsets of newlines that
    fall inside string literals (their next line continues the literal)."""
    depth, n, in_string = 1, len(text), set()
    while i < n:
        c = text[i]
        if text.startswith("//", i):
            j = text.find("\n", i)
            i = n if j < 0 else j
            continue
        if text.startswith("/*", i):
            level, i = 1, i + 2
            while i < n and level:
                if text.startswith("/*", i):
                    level, i = level + 1, i + 2
                elif text.startswith("*/", i):
                    level, i = level - 1, i + 2
                else:
                    i += 1
            continue
        raw = re.match(r'b?r(#*)"', text[i:i + 300])
        if raw and (i == 0 or not (text[i - 1].isalnum() or text[i - 1] == "_")):
            close = '"' + raw.group(1)
            j = text.find(close, i + raw.end())
            if j < 0:
                raise ValueError("unterminated raw string")
            in_string.update(k for k in range(i, j) if text[k] == "\n")
            i = j + len(close)
            continue
        if c == '"':
            j = i + 1
            while j < n and text[j] != '"':
                j += 2 if text[j] == "\\" else 1
            in_string.update(k for k in range(i, j) if text[k] == "\n")
            i = j + 1
            continue
        if c == "'":
            m = re.match(r"'(?:\\(?:x[0-9a-fA-F]{2}|u\{[0-9a-fA-F]{1,6}\}|.)|[^\\'\n])'", text[i:i + 14])
            i += m.end() if m else 1
            continue
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                return i + 1, in_string
        i += 1
    raise ValueError("unbalanced braces")


def dedent(body, base, in_string):
    """body (text[base:base+len(body)]) with one 4-space indent removed from each line that does not continue a
    string literal."""
    out, offset = [], base
    for line in body.split("\n"):
        continues = (offset - 1) in in_string
        if not continues and line.startswith("    "):
            out.append(line[4:])
        elif not continues and line.strip() == "":
            out.append("")
        else:
            out.append(line)
        offset += len(line) + 1
    return "\n".join(out)


AUTO_TARGETS = ("bin", "examples", "benches", "tests")  # Cargo makes a target of every .rs file directly in these


def target_name(path, mod):
    stem = os.path.basename(path)[:-3]
    if mod == "tests":
        name = "tests.rs"
    elif mod.endswith("_tests"):
        name = f"{mod}.rs"
    else:
        name = f"{mod}_tests.rs"
    if stem in ("lib", "main", "mod"):
        return name
    if os.path.basename(os.path.dirname(path)) in AUTO_TARGETS:
        return f"{stem}/{name}"  # a new file beside src/bin/foo.rs would be a binary of its own
    return f"{stem}_tests.rs" if mod == "tests" else f"{stem}_{name}"


COMMENTS = re.compile(r"//[^\n]*|/\*.*?\*/", re.S)


def only_tests_after(text, end, spans):
    """True when nothing but whitespace, comments and test blocks follows `end`: crash_ratchet.py scans a file only
    up to its first inline test module, so moving one with code after it would expose that code to the ratchet."""
    rest, cursor = [], end
    for s, e in spans:
        if s >= end:
            rest.append(text[cursor:s])
            cursor = e
    rest.append(text[cursor:])
    return COMMENTS.sub("", "".join(rest)).strip() == ""


def plan(path, min_bytes):
    text = open(path, encoding="utf-8").read()
    moves, taken = [], set()
    spans = []
    for m in START.finditer(text):
        try:
            spans.append((m.start(), lex_end(text, m.end())[0]))
        except ValueError:
            pass
    for m in START.finditer(text):
        body_start = m.end()
        try:
            end, in_string = lex_end(text, body_start)
        except ValueError as err:
            print(f"skip {path}:{m.group(2)}: {err}", file=sys.stderr)
            continue
        if text[end - 2] != "\n":  # the closing brace must sit alone at column 0
            continue
        block = text[m.start():end]
        body = text[body_start:end - 1]
        if len(block.encode()) < min_bytes or UNSAFE.search(body):
            continue
        if not only_tests_after(text, end, spans):
            print(f"skip {path}:{m.group(2)}: code follows it", file=sys.stderr)
            continue
        name = target_name(path, m.group(2))
        dest = os.path.join(os.path.dirname(path), name)
        if "/" in name and re.search(r"\binclude_(str|bytes)!\(", body):
            continue  # its relative paths would resolve from the new folder
        if os.path.exists(dest) or dest in taken:
            print(f"skip {path}:{m.group(2)}: {name} exists", file=sys.stderr)
            continue
        taken.add(dest)
        new_body = dedent(body, body_start, in_string).rstrip("\n") + "\n"
        if re.sub(r"\s", "", new_body) != re.sub(r"\s", "", body):
            raise SystemExit(f"{path}:{m.group(2)}: dedent changed more than whitespace")
        decl = "#[cfg(test)]\n" + m.group(1) + f'#[path = "{name}"]\n' + m.group(0)[len("#[cfg(test)]\n") + len(m.group(1)):].replace(" {\n", ";")
        moves.append((m.start(), end, decl, dest, new_body, len(block.encode())))
    return text, moves


def main():
    args = sys.argv[1:]
    apply = "--apply" in args
    args = [a for a in args if a != "--apply"]
    min_bytes = 0
    if "--min-bytes" in args:
        k = args.index("--min-bytes")
        min_bytes = int(args[k + 1])
        del args[k:k + 2]
    total = count = 0
    written = []
    for path in args:
        text, moves = plan(path, min_bytes)
        if not moves:
            continue
        for _, _, _, dest, _, size in moves:
            print(f"{size:8d} {dest}")
            total += size
            count += 1
        if apply:
            for start, end, decl, dest, new_body, _ in reversed(moves):
                text = text[:start] + decl + text[end:]
                os.makedirs(os.path.dirname(dest), exist_ok=True)
                with open(dest, "w", encoding="utf-8") as f:
                    f.write(new_body)
            with open(path, "w", encoding="utf-8") as f:
                f.write(text)
            written += [dest for _, _, _, dest, _, _ in moves]
    if written:
        rustfmt(written)
    print(f"total {total} bytes in {count} moves")


def crate_edition(path):
    """The edition rustfmt must use for `path`: its crate's, as `cargo fmt` (CI's autofix) reads it. The nearest
    Cargo.toml with a [package] says `edition = "Y"`, or `edition.workspace = true` and the workspace root's
    [workspace.package] says it. cmux-tui's workspace is 2024, but cmux-hub-host and cmux-rd-host are 2021, and a
    2024 format of their moved tests is a diff the autofix bot would push back (cmux#49132)."""
    d = os.path.dirname(os.path.abspath(path))
    inherit = False
    while True:
        toml = os.path.join(d, "Cargo.toml")
        if os.path.isfile(toml):
            with open(toml, encoding="utf-8") as f:
                text = f.read()
            if not inherit and re.search(r"^\[package\]", text, re.M):
                m = re.search(r'^edition\s*=\s*"(\d+)"', text, re.M)
                if m:
                    return m.group(1)
                inherit = bool(re.search(r"^edition\.workspace\s*=\s*true", text, re.M))
            if inherit:
                m = re.search(r'^\[workspace\.package\][^\[]*?^edition\s*=\s*"(\d+)"', text, re.M | re.S)
                if m:
                    return m.group(1)
        parent = os.path.dirname(d)
        if parent == d:
            return "2024"
        d = parent


def rustfmt(paths):
    """Format the moved bodies as CI's autofix would: one level less indentation lets rustfmt join lines it had
    wrapped, and an unformatted file draws a bot commit that moves the PR's head (cmux#49124 twice). rustfmt finds
    the nearest rustfmt.toml itself; the edition is each file's crate's ([`crate_edition`])."""
    import shutil
    import subprocess
    if not shutil.which("rustfmt"):
        print("warning: rustfmt not found; the moved files are unformatted", file=sys.stderr)
        return
    by_edition = {}
    for path in paths:
        by_edition.setdefault(crate_edition(path), []).append(path)
    for edition, group in sorted(by_edition.items()):
        done = subprocess.run(["rustfmt", "--edition", edition, *group], check=False)
        if done.returncode:
            print(f"warning: rustfmt --edition {edition} exited {done.returncode} on the moved files", file=sys.stderr)


main()
