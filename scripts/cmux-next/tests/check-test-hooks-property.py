#!/usr/bin/env python3
"""Property of check-test-hooks.py (#41418 review): on generated alias chains, what the base check refuses,
the head check refuses too.

Usage: check-test-hooks-property.py HEAD_CHECK BASE_CHECK [--seed N] [--count N] [--samples N]

Each chain is one file: a few generic type aliases and structs, each naming the next, with one to three
parameters (some named as prelude names, `Future`, `Iterator`, `Default`, `String`), defaults that name an
earlier parameter, parameters projected (`T::Hook`, `<T as Callback>::Hook`), and leaves that are closures,
fn pointers, an alias of one, or plain types; then one static naming the chain's first link, in a cell or not,
under `#[cfg(test)]` or not. Every parameter is used by its definition's body: an argument no parameter uses
is dropped on purpose (#41383 F1), so base's refusal of one is a false positive the property leaves out. For
the same reason a default holds no closure leaf (base reads a closure in a default as a closure alias even
when an argument replaces it).

A base refusal that only says `unresolved` (base could not resolve the type, so it refuses rather than guess)
does not bind the head: the head reports `unresolved` itself when it cannot resolve a type, so a head pass there
means it resolved the type and found no hook. Every other base refusal is a hook base found, and the head must
refuse that chain too.

Deterministic: one seed, one sequence of chains. Prints how many chains it generated, how many each check
refused, a sample of those only the head refuses (fine: it resolves what base reads as text), how many base
refused only as unresolved that the head resolved and passed, and every chain where base found a hook and the
head passes. Exit 1 if there is one.
"""
from __future__ import annotations

import argparse
import importlib.util
import random
import re
import sys
import tempfile
from pathlib import Path

REL = "cmux-tui/crates/acpmux/src/chain.rs"
CLOSURES = ["fn()", "fn(bool)", "Box<dyn Fn()>", "Box<dyn FnMut(&str) + Send>", "Arc<dyn Fn(u8) + Send + Sync>",
            "Leaf"]
PLAIN = ["u8", "String", "Cached", "Vec<u8>", "(u8, bool)"]
NAMES = ["T", "U", "V", "W", "Future", "Iterator", "Default", "String"]
WRAPS = ["Mutex<Option<{}>>", "Vec<{}>", "Arc<{}>", "Option<{}>", "std::sync::OnceLock<{}>", "({}, u8)", "Box<{}>",
         "RwLock<Option<{}>>"]
STATIC_WRAPS = ["{}", "std::sync::OnceLock<{}>", "Mutex<Option<{}>>", "LazyLock<Mutex<Vec<{}>>>", "Vec<{}>",
                "OnceLock<Mutex<{}>>"]
PRELUDE_TEXT = """struct Cached { at: u64 }
type Leaf = fn(u8);
trait Callback { type Hook; }
"""


# A finding line of check-test-hooks.py whose reason is that the type could not be resolved.
UNRESOLVED = re.compile(r": unresolved: ")


def load(path: str, name: str):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class Chain:
    def __init__(self, rng: random.Random):
        self.rng = rng

    def wrap(self, text: str, chance: float = 0.5) -> str:
        return self.rng.choice(WRAPS).format(text) if self.rng.random() < chance else text

    def leaf(self) -> str:
        return self.wrap(self.rng.choice(CLOSURES if self.rng.random() < 0.5 else PLAIN), 0.3)

    def params(self) -> list[tuple[str, str]]:
        """(name, default) each; a default names an earlier parameter or a plain type, never a closure."""
        names = self.rng.sample(NAMES, self.rng.randint(1, 3))
        out: list[tuple[str, str]] = []
        defaulted = False
        for index, name in enumerate(names):
            if index > 0 and (defaulted or self.rng.random() < 0.5):
                defaulted = True
                earlier = [n for n, _ in out]
                default = (self.wrap(self.rng.choice(earlier), 0.4) if self.rng.random() < 0.75
                           else self.rng.choice(PLAIN))
                out.append((name, default))
            else:
                out.append((name, ""))
        return out

    def use(self, param: str, projected: bool) -> str:
        if projected and self.rng.random() < 0.6:
            return self.rng.choice([f"{param}::Hook", f"<{param} as Callback>::Hook"])
        return self.wrap(param)

    def arguments(self, params: list[tuple[str, str]], source) -> list[str]:
        """Arguments for params: every one without a default, then a random number of the defaulted ones."""
        required = sum(1 for _, default in params if not default)
        count = required + self.rng.randint(0, len(params) - required)
        return [source() for _ in range(count)]

    def generate(self) -> str:
        depth = self.rng.randint(1, 4)
        levels = [(f"L{i}", self.params(), self.rng.random() < 0.3) for i in range(depth)]
        projected_of = {name: {p for p, _ in params if self.rng.random() < 0.3} for name, params, _ in levels}
        lines = [PRELUDE_TEXT.rstrip("\n")]
        for i, (name, params, is_struct) in enumerate(levels):
            own = [p for p, _ in params]
            projected = projected_of[name]
            used: set[str] = set()
            pieces: list[str] = []
            if i + 1 < len(levels):
                next_name, next_params, _ = levels[i + 1]

                def source() -> str:
                    if self.rng.random() < 0.7:
                        param = self.rng.choice(own)
                        used.add(param)
                        return self.use(param, param in projected)
                    return self.leaf()

                args = self.arguments(next_params, source)
                pieces.append(f"{next_name}<{', '.join(args)}>" if args else next_name)
            for param in own:
                if param not in used or self.rng.random() < 0.3:
                    pieces.append(self.use(param, param in projected))
                    used.add(param)
            if self.rng.random() < 0.2:
                pieces.append(self.leaf())
            self.rng.shuffle(pieces)
            generics = ", ".join(
                f"{p}{': Callback' if p in projected else ''}{f' = {d}' if d else ''}" for p, d in params)
            if is_struct:
                fields = ", ".join(f"f{k}: {piece}" for k, piece in enumerate(pieces))
                lines.append(f"struct {name}<{generics}> {{ {fields} }}")
            else:
                body = pieces[0] if len(pieces) == 1 else f"({', '.join(pieces)})"
                lines.append(f"type {name}<{generics}> = {self.wrap(body, 0.6)};")
        first, first_params, _ = levels[0]
        args = self.arguments(first_params, self.leaf)
        ty = self.rng.choice(STATIC_WRAPS).format(f"{first}<{', '.join(args)}>" if args else first)
        if self.rng.random() < 0.3:
            lines.append("#[cfg(test)]")
        lines.append(f"static CHAIN: {ty} = todo();")
        return "\n".join(lines) + "\n"


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("head")
    parser.add_argument("base")
    parser.add_argument("--seed", type=int, default=41418)
    parser.add_argument("--count", type=int, default=4000)
    parser.add_argument("--samples", type=int, default=5)
    opts = parser.parse_args(argv[1:])
    head = load(opts.head, "head_check")
    base = load(opts.base, "base_check")
    rng = random.Random(opts.seed)
    counts = {"base": 0, "head": 0, "both": 0}
    head_only: list[str] = []
    missed: list[tuple[str, list[str]]] = []
    resolved = 0
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "chain.rs"
        for _ in range(opts.count):
            text = Chain(rng).generate()
            path.write_text(text, encoding="utf-8")
            base_found = base.judge_file(path, REL)
            head_found = head.judge_file(path, REL)
            counts["base"] += bool(base_found)
            counts["head"] += bool(head_found)
            counts["both"] += bool(base_found) and bool(head_found)
            base_hooks = [line for line in base_found if not UNRESOLVED.search(line)]
            if base_hooks and not head_found:
                missed.append((text, base_hooks))
            elif base_found and not head_found:
                resolved += 1
            elif head_found and not base_found:
                head_only.append(text)
    print(f"property: {opts.count} chains (seed {opts.seed}): base refused {counts['base']}, "
          f"head refused {counts['head']}, both {counts['both']}, head only {len(head_only)}, "
          f"base only as unresolved, head resolved and passed {resolved}, base found a hook and head passed "
          f"{len(missed)}")
    for text in head_only[:opts.samples]:
        print("head refuses, base passes:\n" + "".join(f"    {line}\n" for line in text.splitlines()[3:]), end="")
    for text, found in missed:
        print("BASE REFUSES, HEAD PASSES:\n" + "".join(f"    {line}\n" for line in text.splitlines()[3:])
              + "".join(f"    base: {line}\n" for line in found), end="")
    if missed:
        print(f"property: FAIL: {len(missed)} chains where base found a hook and head passes")
        return 1
    print("property: ok, every hook base finds the head refuses too")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
