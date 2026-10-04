#!/usr/bin/env python3
"""Builds the three diff-perf fixture repositories (plans/cmux-next/diff-perf.md).

Each repository has two commits; the measured diff is `HEAD~1..HEAD` (the viewer's
branch session with base `HEAD~1`). Content is deterministic code-like text in
several languages so the highlighter does real work.

  medium: ~50 files, ~5k changed lines
  large:  ~2,000 files, ~200k changed lines, five files with 20k changed lines
  huge:   one ~100 MB generated file plus ~50 normal files

Usage: make-fixtures.py <out-dir> [medium|large|huge ...]
"""
import os
import random
import subprocess
import sys

LANGS = [
    ("ts", "//"), ("tsx", "//"), ("rs", "//"), ("py", "#"), ("go", "//"),
    ("swift", "//"), ("json", None), ("md", None), ("css", None), ("sh", "#"),
]

WORDS = ("value index state buffer render parse token stream window frame cache "
         "session patch hunk line file tree node layout scroll viewport worker").split()


def ident(rng):
    return rng.choice(WORDS) + rng.choice(WORDS).capitalize() + str(rng.randint(0, 99))


def code_line(rng, ext, n):
    a, b, c = ident(rng), ident(rng), ident(rng)
    k = n % 7
    if ext in ("ts", "tsx"):
        return [f"export function {a}({b}: number, {c}: string): string {{",
                f"  const {a} = {b} * {rng.randint(1, 999)} + {c}.length; // {b}",
                f"  if ({a} > {rng.randint(1, 99)}) return `{c}-${{{a}}}`;",
                f"  {b}.{c}({a}, \"{rng.choice(WORDS)}\", {rng.random():.4f});",
                f"  for (let i = 0; i < {a}.length; i++) {{ {c}[i] = i; }}",
                f"  return {a}.map((x) => x + {rng.randint(1, 9)}).join(\",\");",
                "}"][k]
    if ext == "rs":
        return [f"pub fn {a}({b}: u32, {c}: &str) -> Result<String, Error> {{",
                f"    let {a} = {b}.saturating_mul({rng.randint(1, 999)}); // {c}",
                f"    if {a} > {rng.randint(1, 99)} {{ return Ok(format!(\"{{}}-{{}}\", {c}, {a})); }}",
                f"    let {b}: Vec<u8> = {c}.bytes().filter(|x| *x != b'{rng.choice('abcdef')}').collect();",
                f"    match {a} {{ 0 => None, n => Some(n + {rng.randint(1, 9)}) }};",
                f"    self.{c}.insert({a}, {b}.len());",
                "}"][k]
    if ext == "py":
        return [f"def {a}({b}, {c}=None):",
                f"    {a} = {b} * {rng.randint(1, 999)}  # {c}",
                f"    if {a} > {rng.randint(1, 99)}:",
                f"        return f\"{{{c}}}-{{{a}}}\"",
                f"    for i in range(len({b})): {c}[i] = i",
                f"    return [x + {rng.randint(1, 9)} for x in {a}]",
                ""][k]
    if ext == "go":
        return [f"func {a}({b} int, {c} string) (string, error) {{",
                f"\t{a} := {b} * {rng.randint(1, 999)} // {c}",
                f"\tif {a} > {rng.randint(1, 99)} {{ return fmt.Sprintf(\"%s-%d\", {c}, {a}), nil }}",
                f"\tfor i := 0; i < len({c}); i++ {{ {b} += i }}",
                f"\t{b}, err := strconv.Atoi(\"{rng.randint(0, 9999)}\")",
                "\tif err != nil { return \"\", err }",
                "}"][k]
    if ext == "swift":
        return [f"func {a}(_ {b}: Int, {c}: String) -> String {{",
                f"    let {a} = {b} * {rng.randint(1, 999)} // {c}",
                f"    guard {a} > {rng.randint(1, 99)} else {{ return \"\\({c})-\\({a})\" }}",
                f"    for i in 0..<{b} {{ {c}.append(i) }}",
                f"    return {a}.map {{ $0 + {rng.randint(1, 9)} }}.description",
                f"    @State private var {b}: Bool = {rng.choice(['true', 'false'])}",
                "}"][k]
    if ext == "json":
        return f"  \"{a}\": {{ \"{b}\": {rng.randint(0, 99999)}, \"{c}\": \"{rng.choice(WORDS)}\", \"ok\": {rng.choice(['true', 'false'])} }},"
    if ext == "md":
        return [f"## {a.capitalize()} {b}", f"The `{a}` call returns **{b}** for each {c}.",
                f"- {c}: see [{a}](https://example.com/{b})", "", f"```ts\nconst {a} = {rng.randint(0, 9)};\n```",
                f"> {b} {c} {a}", f"1. {a} then {b}"][k]
    if ext == "css":
        return [f".{a} {{", f"  color: #{rng.randint(0, 0xffffff):06x};", f"  margin: {rng.randint(0, 40)}px {rng.randint(0, 40)}px;",
                f"  display: {rng.choice(['flex', 'grid', 'block'])};", f"  --{b}: calc(100% - {rng.randint(1, 99)}px);",
                f"  transition: {c} {rng.randint(1, 500)}ms ease;", "}"][k]
    return [f"{a}() {{", f"  local {b}=\"${{{c}:-{rng.randint(0, 99)}}}\"", f"  if [[ -n \"${b}\" ]]; then echo \"{c}\"; fi",
            f"  for i in $(seq 1 {rng.randint(1, 99)}); do {b}+=$i; done", f"  export {c}={rng.randint(0, 999)}",
            f"  grep -q '{a}' \"$1\" || return 1", "}"][k]


def make_lines(rng, ext, count):
    return [code_line(rng, ext, i) for i in range(count)]


def mutate(rng, lines, ext, changes):
    """Replaces, inserts and deletes lines at `changes` scattered spots."""
    out = list(lines)
    for _ in range(changes):
        if not out:
            out.append(code_line(rng, ext, 0))
            continue
        at = rng.randrange(len(out))
        op = rng.random()
        if op < 0.5:
            out[at] = code_line(rng, ext, at + 3)
        elif op < 0.8:
            out[at:at] = [code_line(rng, ext, at + j) for j in range(rng.randint(1, 4))]
        else:
            del out[at:at + rng.randint(1, 3)]
    return out


def write(path, lines):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as handle:
        handle.write("\n".join(lines) + "\n")


def git(repo, *args):
    subprocess.run(["git", "-C", repo, *args], check=True, stdout=subprocess.DEVNULL)


def init(repo):
    if os.path.exists(repo):
        subprocess.run(["rm", "-rf", repo], check=True)
    os.makedirs(repo)
    git(repo, "init", "-q", "-b", "main")
    git(repo, "config", "user.email", "perf@example.com")
    git(repo, "config", "user.name", "perf")
    git(repo, "config", "commit.gpgsign", "false")


def commit(repo, message):
    git(repo, "add", "-A")
    git(repo, "commit", "-q", "-m", message)


def normal_files(rng, prefix, count, base_lines, changes):
    """`count` files: 70% modified, 20% added, 10% deleted. Returns (base, head) dicts."""
    base, head = {}, {}
    for i in range(count):
        ext, _ = LANGS[i % len(LANGS)]
        path = f"{prefix}/m{i // 100:02d}/{ident(rng)}_{i}.{ext}"
        roll = i % 10
        lines = make_lines(rng, ext, base_lines)
        if roll < 7:
            base[path] = lines
            head[path] = mutate(rng, lines, ext, changes)
        elif roll < 9:
            head[path] = make_lines(rng, ext, max(1, changes * 2))
        else:
            base[path] = lines
    return base, head


def build(repo, base, head, huge_head=None):
    init(repo)
    for path, lines in base.items():
        write(os.path.join(repo, path), lines)
    commit(repo, "base")
    for path in base:
        if path not in head:
            os.remove(os.path.join(repo, path))
    for path, lines in head.items():
        write(os.path.join(repo, path), lines)
    if huge_head:
        huge_head(repo)
    commit(repo, "head")


def medium(out):
    rng = random.Random(1)
    base, head = normal_files(rng, "src", 50, 400, 30)
    build(os.path.join(out, "medium"), base, head)


def large(out):
    rng = random.Random(2)
    base, head = normal_files(rng, "pkg", 1995, 160, 24)
    # Five 20k-changed-line files: three added, two rewritten in place.
    for i, ext in enumerate(["ts", "rs", "py"]):
        head[f"big/added_{i}.{ext}"] = make_lines(rng, ext, 20000)
    for i, ext in enumerate(["go", "swift"]):
        lines = make_lines(rng, ext, 20000)
        base[f"big/rewritten_{i}.{ext}"] = lines
        head[f"big/rewritten_{i}.{ext}"] = mutate(rng, lines, ext, 9000)
    build(os.path.join(out, "large"), base, head)


def huge(out):
    rng = random.Random(3)
    base, head = normal_files(rng, "app", 50, 400, 30)

    def generated(repo):
        # ~100 MB of minified-style JSON-ish JS, written in chunks, all added lines.
        path = os.path.join(repo, "dist/generated/bundle.js")
        os.makedirs(os.path.dirname(path), exist_ok=True)
        target = 100 * 1024 * 1024
        written = 0
        with open(path, "w") as handle:
            n = 0
            while written < target:
                row = (f"export const t{n} = {{ id: {n}, name: \"{ident(rng)}\", value: {rng.random():.6f}, "
                       f"tags: [\"{rng.choice(WORDS)}\", \"{rng.choice(WORDS)}\"], ok: {rng.choice(['true', 'false'])} }};\n")
                handle.write(row)
                written += len(row)
                n += 1
    build(os.path.join(out, "huge"), base, head, generated)


def main():
    out = sys.argv[1]
    names = sys.argv[2:] or ["medium", "large", "huge"]
    for name in names:
        {"medium": medium, "large": large, "huge": huge}[name](out)
        repo = os.path.join(out, name)
        stat = subprocess.run(["git", "-C", repo, "diff", "--shortstat", "HEAD~1", "HEAD"],
                              check=True, capture_output=True, text=True).stdout.strip()
        print(f"{name}: {stat}")


if __name__ == "__main__":
    main()
