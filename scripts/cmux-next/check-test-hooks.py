#!/usr/bin/env python3
"""No process-wide test hooks in acpmux (cmux#41350).

The test harness runs tests on parallel threads of one process. A test hook
kept in a process-wide static lets one test's hook replace or clear another's
before the code it was meant to stop ran, so the race the test forces never
happens, or a test runs another test's hook. folder_instructions::SWAP_HOOK
failed 50 of 50 runs that way; hub::transfer_in::SWEEP_PAUSE was one second
user away from it.

This guard fails on a static in cmux-tui/crates/acpmux/src that holds a test
hook, outside a `thread_local!` or `task_local!`:
  - a test slot: a `Mutex<Option<...>>` or `RwLock<Option<...>>` (also inside
    a OnceLock or LazyLock) under `#[cfg(test)]`, in a `#[cfg(test)]` module
    or in a test file;
  - a closure in a cell: a Mutex, RwLock, OnceLock, LazyLock or OnceCell
    whose type holds `dyn Fn`/`FnMut`/`FnOnce`, `impl Fn...` or a `fn(...)`
    pointer;
  - any static named `...HOOK`.
Production caches (`Mutex<Option<Cached>>` outside test code, `Cached` a type
the file shows) are not hooks. `thread_local!` and `task_local!` count in both
forms, `{ ... }` and `( ... )`.

A static's type is judged after the file's own names in it are resolved:
type aliases, transitive ones included (`type A = Mutex<Option<B>>; type B =
Box<dyn Fn()>;`), structs and enums of the file (by their fields), and `use
... as` renames (`Mutex as StdMutex`). A name the lint cannot see (one from
another file of the crate, a glob import, or no import at all) is reported as
`unresolved` when it heads the type or sits inside a cell, never passed:
a lint that resolves only the syntax it has seen would mark what it cannot
see as safe. Two kinds of name are taken at their word: one ending in a
cell's name (`StdMutex`) is a cell, and the std names in WELL_KNOWN are std's.

The fixes: a per-thread hook, a `thread_local!` slot set through an `on_*`
guard that takes it off when dropped (folder_instructions::on_swap); or, when
the code the hook stops runs on another thread, a static only an `on_*` guard
sets, holding a `Mutex<()>` serializer until it drops (the `HOOK_TEST`
pattern). The second needs a marker on the static, in the comment and
attribute lines directly above it or on its line:

    // test-hook-allow: serialized by HOOK_TEST, which every test that sets it holds

A marker that says `serialized by NAME` must name a `static NAME: Mutex<()>`
(std or tokio) in the same file. Any other marker states why the hook cannot
race (one process per test, say), in at least three words.

Usage: check-test-hooks.py [repo-root]   (default: this repository)
Exit 0: no finding; 1: findings, one `path:line: NAME: why` line each.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

SCOPE = "cmux-tui/crates/acpmux/src"
MARKER = re.compile(r"//\s*test-hook-allow:\s*(?P<why>.*)$")
SERIALIZED = re.compile(r"\bserialized by (?P<name>[A-Za-z_][A-Za-z0-9_]*)")
STATIC = re.compile(r"^\s*(?:pub(?:\([^)]*\))?\s+)?static\s+(?:mut\s+)?(?P<name>[A-Za-z_][A-Za-z0-9_]*)\s*:")
# A cell, std's or a renamed one (`Mutex as StdMutex`): a name ending in a cell's is taken as one.
CELL_NAME = r"[A-Za-z_]*(?:Mutex|RwLock|OnceLock|LazyLock|OnceCell|Lazy)"
CELL = re.compile(r"\b" + CELL_NAME + r"\s*<")
SLOT = re.compile(r"\b[A-Za-z_]*(?:Mutex|RwLock)\s*<\s*Option\s*<")
CLOSURE = re.compile(r"\bdyn\s+(?:Fn|FnMut|FnOnce)\b|\bimpl\s+(?:Fn|FnMut|FnOnce)\b|\bfn\s*\(")
SERIALIZER = re.compile(r"^\s*(?:(?:std|tokio)::sync::)?Mutex\s*<\s*\(\s*\)\s*>\s*$")
CFG_TEST = re.compile(r"^\s*#\[cfg\(test\)\]")
MOD_OPEN = re.compile(r"^\s*(?:pub(?:\([^)]*\))?\s+)?mod\s+\w+\s*\{")
# A per-thread (or per-task) storage macro, in its brace or its parenthesis form.
PER_THREAD = re.compile(r"\b(?:thread_local|task_local)!\s*(?=[{(]|$)")
VIS = r"(?:pub(?:\s*\([^)]*\))?\s+)?"
DEF = re.compile(r"(?m)^[ \t]*" + VIS + r"(?P<kind>type|struct|enum|const)\s+(?P<name>[A-Za-z_]\w*)")
USE = re.compile(r"(?m)^[ \t]*" + VIS + r"use\s+(?P<tree>[^;]*);")
MOD = re.compile(r"(?m)^[ \t]*" + VIS + r"mod\s+(?P<name>[A-Za-z_]\w*)")
# A type name, plain or a path; not an associated-type binding (`Output = ...`).
TOKEN = re.compile(r"(?<![\w:])(?:::)?(?:[A-Za-z_]\w*::)*[A-Za-z_]\w*\b(?!::)(?!\s*=(?!=))")
KEYWORDS = {"dyn", "impl", "mut", "const", "fn", "for", "where", "as", "unsafe", "extern", "static", "Self"}
PRELUDE = {
    "bool", "char", "str", "u8", "u16", "u32", "u64", "u128", "usize", "i8", "i16", "i32", "i64", "i128",
    "isize", "f32", "f64", "Option", "Vec", "String", "Box", "Result", "Send", "Sync", "Sized", "Unpin",
    "Copy", "Clone", "Default", "Fn", "FnMut", "FnOnce", "Drop", "Iterator", "IntoIterator", "ToString",
    "ToOwned", "AsRef", "AsMut", "From", "Into", "PartialEq", "Eq", "PartialOrd", "Ord", "Future",
    "IntoFuture",
}
# std and tokio names taken at their word when a glob import (`use super::*`) brings them: none holds a closure.
WELL_KNOWN = {
    "AtomicBool", "AtomicU8", "AtomicU16", "AtomicU32", "AtomicU64", "AtomicUsize", "AtomicI8", "AtomicI16",
    "AtomicI32", "AtomicI64", "AtomicIsize", "HashMap", "HashSet", "BTreeMap", "BTreeSet", "VecDeque", "Path",
    "PathBuf", "Duration", "Instant", "SystemTime", "Arc", "Rc", "Weak", "Cell", "RefCell", "Notify", "Semaphore",
    "Condvar", "Once", "Value", "Pin",
}


def is_test_file(rel: Path) -> bool:
    name = rel.name
    return ("tests" in rel.parts[:-1] or name in ("tests.rs", "test.rs")
            or name.endswith(("_tests.rs", "_test.rs")))


def code_only(line: str) -> str:
    """The line without its string and char literals and its `//` comment, for brace counting."""
    line = re.sub(r'"(?:[^"\\]|\\.)*"', '""', line)
    line = re.sub(r"'(?:[^'\\]|\\.)'", "''", line)
    return line.split("//", 1)[0]


def declared_type(lines: list[str], start: int) -> str:
    """The type of the static declared at lines[start]: from its `:` to its top-level `=` or `;`."""
    text = lines[start].split(":", 1)[1]
    out = []
    depth = 0
    index = start
    while True:
        i = 0
        while i < len(text):
            ch = text[i]
            if ch == "-" and text[i + 1:i + 2] == ">":
                out.append("->")
                i += 2
                continue
            if ch in "<([":
                depth += 1
            elif ch in ">)]":
                depth -= 1
            elif ch in "=;" and depth <= 0:
                return "".join(out)
            out.append(ch)
            i += 1
        index += 1
        if index >= len(lines) or index - start > 12:
            return "".join(out)
        out.append(" ")
        text = lines[index]


def leading_block(lines: list[str], at: int) -> list[str]:
    """The comment and attribute lines directly above lines[at], nearest first."""
    block = []
    i = at - 1
    while i >= 0:
        stripped = lines[i].strip()
        if stripped.startswith(("//", "#[")):
            block.append(stripped)
            i -= 1
            continue
        break
    return block


def balanced(code: str, at: int) -> int:
    """The index just past the bracket that closes the one at code[at]."""
    depth = 0
    for i in range(at, len(code)):
        ch = code[i]
        if ch in "<([{":
            depth += 1
        elif ch in ">)]}" and code[i - 1:i] != "-":
            depth -= 1
            if depth == 0:
                return i + 1
    return len(code)


def top_level(text: str, sep: str) -> list[str]:
    """text split at each `sep` outside brackets."""
    parts, depth, start = [], 0, 0
    for i, ch in enumerate(text):
        if ch in "<([{":
            depth += 1
        elif ch in ">)]}" and text[i - 1:i] != "-":
            depth -= 1
        elif ch == sep and depth == 0:
            parts.append(text[start:i])
            start = i + 1
    parts.append(text[start:])
    return [p.strip() for p in parts if p.strip()]


def field_types(body: str, named: bool) -> list[str]:
    """The field types of a struct body (`{ a: T }` when named, `(T)` when not)."""
    out = []
    for piece in top_level(body, ","):
        piece = re.sub(r"#\[[^\]]*\]", " ", piece).strip()
        piece = re.sub(r"^" + VIS, "", piece).strip()
        if named:
            piece = re.split(r"(?<!:):(?!:)", piece, maxsplit=1)[-1]
        out.append(piece)
    return out


def variant_types(body: str) -> list[str]:
    out = []
    for piece in top_level(body, ","):
        piece = re.sub(r"#\[[^\]]*\]", " ", piece).strip()
        match = re.match(r"[A-Za-z_]\w*\s*(?P<open>[({])?", piece)
        if match and match.group("open"):
            inner = piece[match.end():piece.rfind(")" if match.group("open") == "(" else "}")]
            out += field_types(inner, match.group("open") == "{")
    return out


def params_of(code: str, at: int) -> tuple[list[tuple[str, str]], int]:
    """The generic parameters of a definition whose `<` (if any) is at or after code[at], in order:
    (name, its default type or "") each. A lifetime is left out, as expand leaves out a lifetime argument."""
    rest = code[at:]
    stripped = rest.lstrip()
    if not stripped.startswith("<"):
        return [], at
    start = at + len(rest) - len(stripped)
    end = balanced(code, start)
    params = []
    for piece in top_level(code[start + 1:end - 1], ","):
        piece = re.sub(r"^const\s+", "", piece)
        match = re.match(r"[A-Za-z_]\w*", piece)
        if match:
            default = top_level(piece, "=")
            params.append((match.group(0), default[1] if len(default) > 1 else ""))
    return params, end


def definitions(code: str) -> dict[str, tuple[str, str, list[tuple[str, str]]]]:
    """This file's type aliases, structs and enums: name -> (kind, the type text it holds, its parameters)."""
    defs = {}
    for match in DEF.finditer(code):
        params, at = params_of(code, match.end())
        kind = match.group("kind")
        if kind == "const":
            body = ""  # a value (an array length): it holds no type
        elif kind == "type":
            eq = code.find("=", at)
            semi = eq
            depth = 0
            while semi != -1 and semi < len(code):
                ch = code[semi]
                if ch in "<([{":
                    depth += 1
                elif ch in ">)]}" and code[semi - 1] != "-":
                    depth -= 1
                elif ch == ";" and depth <= 0:
                    break
                semi += 1
            body = code[eq + 1:semi] if eq != -1 else ""
        else:
            opener = re.compile(r"[{(;]").search(code, at)
            if not opener or opener.group(0) == ";":
                body = ""
            else:
                inner = code[opener.start() + 1:balanced(code, opener.start()) - 1]
                if kind == "enum":
                    body = ", ".join(variant_types(inner))
                else:
                    body = ", ".join(field_types(inner, opener.group(0) == "{"))
        defs[match.group("name")] = (kind, body, params)
    return defs


def use_tree(prefix: str, tree: str, out: dict[str, str]) -> None:
    tree = tree.strip()
    brace = tree.find("{")
    if brace != -1:
        head = prefix + tree[:brace]
        for piece in top_level(tree[brace + 1:tree.rfind("}")], ","):
            use_tree(head, piece, out)
        return
    path, _, local = (prefix + tree).partition(" as ")
    path = path.strip().strip(":")
    if path.endswith("::self"):
        path = path[:-len("::self")]
    last = path.rsplit("::", 1)[-1]
    local = local.strip() or last
    if local not in ("_", "*") and last != "*":
        out[local] = path


def imports(code: str) -> dict[str, str]:
    """This file's `use` names: local name -> the path it stands for."""
    out = {}
    for match in USE.finditer(code):
        use_tree("", " ".join(match.group("tree").split()), out)
    return out


class Names:
    """What the names in a file's static types stand for, as far as this file shows."""

    def __init__(self, lines: list[str]):
        code = "\n".join(code_only(line) for line in lines)
        self.defs = definitions(code)
        self.uses = imports(code)
        self.mods = {m.group("name") for m in MOD.finditer(code)}

    def local(self, path: str, seen: tuple[str, ...] = ()) -> bool:
        """Whether path names something of this crate (whose definition this file does not show)."""
        root = path.split("::", 1)[0]
        if root in ("crate", "super", "self") or root in self.mods:
            return True
        if root in self.uses and root not in seen and "::" in path:
            return self.local(self.uses[root], (*seen, root))
        return False

    def expand(self, text: str, unresolved: list[str], params: dict[str, tuple[str, list[str]]] | None = None,
               stack: tuple[str, ...] = ()) -> str:
        """text with each name of this file replaced by what it stands for; names it cannot see go to unresolved.

        params: the parameters of the definition text is the body of, each with the expanded argument it was
        given and the names that argument could not see (an argument is "" when none was given). A generic
        definition named with arguments is put in by one ordered pass: its arguments are bound to its parameters
        by position (each read where it is written, with the caller's parameters), then each parameter left
        without one takes its default, in declaration order, read with the parameters bound before it (`struct
        Pair<T, U = T>` named `Pair<u8>` is `Pair<u8, u8>`); then the body is read with those bindings, a
        parameter going before every other name (one named `Future` is the parameter, not the prelude's), and
        only the names left are resolved. So `type Cache<T> = Mutex<Option<Cached>>` named `Cache<fn()>` is
        `Mutex<Option<Cached>>`: an argument no parameter uses is dropped, with its unresolved names, and a used
        one is judged where it is used. A projection rooted at a parameter (`T::Hook`) keeps its argument
        (`<fn()>::Hook`) and is reported unresolved: the lint does not read trait impls."""
        params = params or {}
        text = re.sub(r'"(?:[^"\\]|\\.)*"', '""', text)
        text = re.sub(r"'\w+", "", text)
        text = re.sub(r";[^\[\]]*\]", "]", text)  # an array's length is a value

        def arguments(at: int) -> tuple[list[str], int]:
            """The generic arguments written at text[at] (after spaces), and the index past them."""
            rest = text[at:]
            stripped = rest.lstrip()
            if not stripped.startswith("<"):
                return [], at
            start = at + len(rest) - len(stripped)
            end = balanced(text, start)
            return top_level(text[start + 1:end - 1], ","), end

        def bind(name: str, own: list[tuple[str, str]], args: list[str]) -> dict[str, tuple[str, list[str]]]:
            """The parameters of definition name bound in order: the arguments given, then the defaults."""
            given: dict[str, tuple[str, list[str]]] = {}
            for index, (param, default) in enumerate(own):
                missed: list[str] = []
                if index < len(args):
                    arg = self.expand(args[index], missed, params, stack)
                elif default:
                    arg = self.expand(default, missed, dict(given), (*stack, name))
                else:
                    arg = ""
                given[param] = (arg, missed)
            return given

        def named(path: str, at: int) -> tuple[str, int]:
            """What the name path (its token ending at text[at]) stands for, and the index past what it used."""
            if path in params:
                arg, missed = params[path]
                unresolved.extend(missed)
                return (arg or path), at
            if path in KEYWORDS or path in PRELUDE:
                return path, at
            if path in self.defs:
                if path in stack:
                    return path, at
                kind, body, own = self.defs[path]
                args, end = arguments(at) if own else ([], at)
                inner = self.expand(body, unresolved, bind(path, own, args), (*stack, path))
                # An alias is its type; a struct or enum is named with its fields' types.
                return (inner if kind == "type" else f"{path}{{{inner}}}"), end
            if path in self.uses:
                full = self.uses[path]
                if self.local(full):
                    unresolved.append(path)
                    return path, at
                return full, at
            if re.fullmatch(CELL_NAME, path):
                return path, at  # a cell by its name (a glob-imported `StdMutex`): what it holds is judged
            if path not in WELL_KNOWN:
                unresolved.append(path)
            return path, at

        out = []
        pos = 0
        for match in TOKEN.finditer(text):
            if match.start() < pos:
                continue  # inside generic arguments already put in
            out.append(text[pos:match.start()])
            token = match.group(0)
            path = token.lstrip(":")
            if path.startswith("self::") and path.count("::") == 1:
                path = path[len("self::"):]
            if "::" in path:
                root, rest = path.split("::", 1)
                if not token.startswith("::") and root in params:
                    # A projection of a parameter: its argument stays in, and what it projects is unresolved.
                    arg, missed = params[root]
                    unresolved.extend(missed)
                    projected = f"<{arg}>::{rest}" if arg else path
                    unresolved.append(projected)
                    out.append(projected)
                elif self.local(path):
                    unresolved.append(path)
                    out.append(token)
                else:
                    out.append(token)
                pos = match.end()
                continue
            replaced, pos = named(path, match.end())
            out.append(token if replaced == path else replaced)
        out.append(text[pos:])
        return "".join(out)

    def resolve(self, ty: str) -> tuple[str, list[str], bool]:
        """(the type with this file's names resolved, the names it cannot see, whether one of them heads it)."""
        unresolved: list[str] = []
        expanded = self.expand(ty, unresolved)
        head = TOKEN.search(re.sub(r"'\w+", "", ty))
        head_unresolved: list[str] = []
        if head:
            self.expand(head.group(0), head_unresolved)
        return expanded, sorted(set(unresolved)), bool(head_unresolved)


def per_thread_lines(lines: list[str]) -> set[int]:
    """The indexes of the lines inside a `thread_local!`/`task_local!` invocation, brace or parenthesis form."""
    inside: set[int] = set()
    code = [code_only(line) for line in lines]
    i = 0
    while i < len(code):
        match = PER_THREAD.search(code[i])
        if not match:
            i += 1
            continue
        # Find the macro's opening bracket (its line or a later one), then its close.
        row, col = i, match.end()
        while row < len(code):
            rest = code[row][col:].lstrip()
            if rest:
                break
            row, col = row + 1, 0
        if row >= len(code) or code[row][col:].lstrip()[:1] not in "{(":
            i += 1
            continue
        col = len(code[row]) - len(code[row][col:].lstrip())
        depth = 0
        end = row
        for r in range(row, len(code)):
            text = code[r][col:] if r == row else code[r]
            for ch in text:
                if ch in "{(":
                    depth += 1
                elif ch in "})":
                    depth -= 1
            if depth <= 0:
                end = r
                break
        else:
            end = len(code) - 1
        inside.update(range(i, end + 1))
        i = end + 1
    return inside


def serializers(lines: list[str], names: Names) -> set[str]:
    found = set()
    for i, line in enumerate(lines):
        match = STATIC.match(line)
        if match and SERIALIZER.match(names.resolve(declared_type(lines, i))[0]):
            found.add(match.group("name"))
    return found


def judge_file(path: Path, rel: str) -> list[str]:
    lines = path.read_text(encoding="utf-8", errors="replace").split("\n")
    test_file = is_test_file(Path(rel))
    names: Names | None = None
    per_thread = per_thread_lines(lines)
    locks: set[str] | None = None
    found = []
    depth = 0
    # Brace depths at which a `#[cfg(test)]` module opened.
    test_mods: list[int] = []
    pending_cfg_test = False
    for i, line in enumerate(lines):
        code = code_only(line)
        match = STATIC.match(line)
        if match and i not in per_thread:
            if names is None:
                names = Names(lines)
            name = match.group("name")
            ty, unresolved, head_unresolved = names.resolve(declared_type(lines, i))
            block = leading_block(lines, i)
            gated = test_file or bool(test_mods) or any(CFG_TEST.match(b) for b in block)
            why = None
            if gated and SLOT.search(ty):
                why = "a process-wide test slot (`Mutex<Option<...>>`)"
            elif CELL.search(ty) and CLOSURE.search(ty):
                why = "a closure in a process-wide cell"
            elif name.endswith("HOOK"):
                why = "a process-wide static named as a hook"
            elif unresolved and (head_unresolved or CELL.search(ty)):
                why = (f"unresolved: its type names {', '.join(unresolved)}, which this file does not define, "
                       f"so the check cannot tell whether it holds a hook")
            if why:
                marker = next((m for m in (MARKER.search(t) for t in [line, *block]) if m), None)
                reason = marker.group("why").strip() if marker else ""
                serial = SERIALIZED.search(reason)
                if marker is None and unresolved and why.startswith("unresolved"):
                    found.append(f"{rel}:{i + 1}: {name}: {why}; spell the type out or alias it in this file, "
                                 f"or mark it `// test-hook-allow: <why it holds no hook>`")
                elif marker is None:
                    found.append(f"{rel}:{i + 1}: {name}: {why}; put it in a thread_local! behind an on_* guard, "
                                 f"or serialize it and mark it `// test-hook-allow: serialized by <Mutex<()> static>, "
                                 f"<why>`")
                elif serial:
                    if locks is None:
                        locks = serializers(lines, names)
                    if serial.group("name") not in locks:
                        found.append(f"{rel}:{i + 1}: {name}: its test-hook-allow names {serial.group('name')}, "
                                     f"which is no `static {serial.group('name')}: Mutex<()>` in this file")
                elif len(reason.split()) < 3:
                    found.append(f"{rel}:{i + 1}: {name}: its test-hook-allow gives no reason (at least three words)")
        if CFG_TEST.match(line):
            pending_cfg_test = True
        elif line.strip() and not line.strip().startswith(("//", "#[")):
            if pending_cfg_test and MOD_OPEN.match(line):
                test_mods.append(depth)
            pending_cfg_test = False
        depth += code.count("{") - code.count("}")
        while test_mods and depth <= test_mods[-1]:
            test_mods.pop()
    return found


def violations(root: Path) -> list[str]:
    found = []
    scope = root / SCOPE
    if not scope.is_dir():
        return found
    for path in sorted(scope.rglob("*.rs")):
        found += judge_file(path, path.relative_to(root).as_posix())
    return found


def main(argv: list[str]) -> int:
    root = Path(argv[1]) if len(argv) > 1 else Path(__file__).resolve().parents[2]
    found = violations(root)
    if found:
        print("process-wide test hooks: a parallel test can replace or clear another's hook (cmux#41350):")
        for line in found:
            print(line)
        return 1
    print("process-wide test hooks: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
