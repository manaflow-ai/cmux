#!/usr/bin/env python3
"""Every sleep in scripts/ and tests/, sorted into waits, polls and sleeps whose duration is the point.

Leo, 2026-11-22: "surely we can think of better fixes than random timing which can shift. always think of better
here. always pursue excellence." A fixed sleep that stands in for "until X happened" passes on a quiet machine and
fails on a busy one. This report finds them; it is not a CI gate.

Kinds:
  wait   a sleep outside any loop, with no reason: a fixed wait for something to happen. Rewrite it to wait on
         the thing itself (a state or event the code can read, under a deadline).
  poll   a sleep inside a while/for loop: the loop re-checks a condition (a deadline-bounded poll, a retry backoff).
  ok     a sleep outside a loop whose duration is the point (a recording window, a simulated slow child, an
         mtime tick, rate pacing), said on the line or in the comment block right above it:
         `# sleep-ok: <why the duration itself is wanted>`.

Python: time.sleep / asyncio.sleep / a bare sleep() call, by AST (sleeps inside strings and fixtures' source text
are not calls and are not counted). Shell: each `sleep N` command; inside while/until/for ... done is a poll.

  python3 scripts/sleep-waits.py            # counts
  python3 scripts/sleep-waits.py --list     # every wait, path:line and argument
  python3 scripts/sleep-waits.py --json     # every sleep with its kind
"""
import ast, json, pathlib, re, sys

args = [a for a in sys.argv[1:] if not a.startswith("--")]
root = pathlib.Path(args[0] if args else ".")
dirs = ["scripts", "tests"]
SKIP = ("/node_modules/", "/.build/", "/vendor/", "/__pycache__/")


def py_sleeps(path, text):
    try:
        tree = ast.parse(text)
    except SyntaxError:
        return []
    out = []

    def is_sleep(call):
        f = call.func
        if isinstance(f, ast.Attribute) and f.attr == "sleep" and isinstance(f.value, ast.Name) and f.value.id in ("time", "asyncio", "_time", "trio", "anyio"):
            return True
        if isinstance(f, ast.Name) and f.id == "sleep":
            return True
        return False

    def visit(node, in_loop):
        for child in ast.iter_child_nodes(node):
            loop = in_loop
            if isinstance(child, (ast.While, ast.For, ast.AsyncFor)):
                loop = True
            elif isinstance(child, (ast.FunctionDef, ast.AsyncFunctionDef, ast.Lambda)):
                loop = False
            elif isinstance(child, (ast.ListComp, ast.GeneratorExp)):
                loop = True
            if isinstance(child, ast.Call) and is_sleep(child):
                arg = ast.unparse(child.args[0]) if child.args else ""
                out.append((child.lineno, "poll" if in_loop else "bare", arg))
            visit(child, loop)

    visit(tree, False)
    return out


SH_SLEEP = re.compile(r"(^\s*|[;&|({]\s*|\bthen\s+|\bdo\s+|\belse\s+|&&\s*|\|\|\s*)sleep\s+([0-9.]+[smh]?|\"?\$\{?\w+\}?\"?)")
OPEN = re.compile(r"^\s*(while|until|for)\b|;\s*do\s*$|\bdo\s*$")


def sh_sleeps(path, text):
    out = []
    depth = 0
    heredoc = None
    for i, line in enumerate(text.splitlines(), 1):
        s = line.strip()
        if heredoc:
            if s == heredoc:
                heredoc = None
            continue
        m = re.search(r"<<-?\s*['\"]?(\w+)['\"]?", line)
        if s.startswith("#"):
            continue
        opens = len(re.findall(r"(?:^|[;\s])do(?:\s|$)", line))
        closes = len(re.findall(r"(?:^|[;\s])done(?:\s|$|[;|)&>])", line))
        sm = SH_SLEEP.search(line)
        if sm:
            # a one-line loop `while ...; do sleep 1; done` counts as poll
            inline_loop = opens > 0
            out.append((i, "poll" if depth > 0 or inline_loop else "bare", sm.group(2)))
        depth += opens - closes
        depth = max(depth, 0)
        if m and not re.search(r"<<<", line):
            heredoc = m.group(1)
    return out


rows = []
MARK = "sleep-ok:"


def marked(lines, lineno):
    """The sleep's line, or the comment block right above it, says why its duration is wanted."""
    if MARK in lines[lineno - 1]:
        return True
    i = lineno - 2
    while i >= 0 and lines[i].strip().startswith("#"):
        if MARK in lines[i]:
            return True
        i -= 1
    return False


for d in dirs:
    base = root / d
    if not base.exists():
        continue
    for p in sorted(base.rglob("*")):
        sp = str(p)
        if not p.is_file() or any(x in sp for x in SKIP):
            continue
        rel = str(p.relative_to(root))
        if p.suffix == ".py":
            text = p.read_text(errors="replace")
            hits = py_sleeps(p, text)
        elif p.suffix in (".sh", ".bash") or (p.suffix == "" and p.read_bytes()[:40].startswith(b"#!") and b"sh" in p.read_bytes()[:40]):
            text = p.read_text(errors="replace")
            hits = sh_sleeps(p, text)
        else:
            continue
        test = rel.startswith("tests/") or "/tests/" in rel or pathlib.Path(rel).name.startswith("test_")
        lines = text.splitlines()
        for line, kind, arg in hits:
            if kind == "bare":
                kind = "ok" if marked(lines, line) else "wait"
            rows.append({"path": rel, "line": line, "kind": kind, "arg": arg, "test": test})

counts = {}
for r in rows:
    k = ("test" if r["test"] else "tool", r["kind"])
    counts[k] = counts.get(k, 0) + 1
if "--json" in sys.argv:
    print(json.dumps(rows, indent=1))
elif "--list" in sys.argv:
    for r in rows:
        if r["kind"] == "wait":
            print(f"{r['path']}:{r['line']}\tsleep {r['arg']}")
else:
    for (a, b), n in sorted(counts.items()):
        print(f"{a:5} {b:5} {n}")
    waits = [r for r in rows if r["kind"] == "wait"]
    print(f"sleep waits: {len(waits)} in {len({r['path'] for r in waits})} files")
