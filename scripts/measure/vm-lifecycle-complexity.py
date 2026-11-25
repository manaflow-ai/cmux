#!/usr/bin/env python3
"""Compare VM lifecycle decisions at two commits with one Rust syntax parser.

Install tree-sitter==0.25.2 and tree-sitter-rust==0.24.0 into an isolated
Python environment. Run from the repository root with BASE HEAD arguments.
Counts are source decision counts, not expanded-macro cyclomatic complexity:
1 + if/for/while/loop + extra match arms + &&/|| + error propagation (?).
Closures count with their enclosing function; macro bodies are not expanded.
Every row includes its boundaries, component counts and opaque macro count.
"""
import argparse
from collections import Counter
import json
import subprocess
from importlib.metadata import version

from tree_sitter import Language, Parser
import tree_sitter_rust

FILES = {
    "cmux-tui/crates/cmux-tui/src/cli/cloud_start_chat/internal/link_wait.rs":
        ("observe", "ask", "connect", "identify", "attach", "follow"),
    "workers/cmux-vm/cli/crates/cmux-vm/src/run.rs":
        ("run", "create", "wait_running", "work", "finish", "parse_vm_state", "pause_kept", "provisioning_vm"),
    "cmux-tui/crates/cmux-tui/src/cli/cloud_start_chat.rs":
        ("run_once", "steps", "await_created", "new_machine", "start_stage"),
}


def walk(node):
    yield node
    for child in node.named_children:
        yield from walk(child)


def measure(parser, ref, path, names):
    source = subprocess.check_output(["git", "show", f"{ref}:{path}"])
    root = parser.parse(source).root_node
    for fn in walk(root):
        if fn.type != "function_item":
            continue
        name = fn.child_by_field_name("name").text.decode()
        if name not in names:
            continue
        if fn.has_error:
            raise ValueError(f"parser error in {ref}:{path}:{name}")
        counts = Counter()
        for node in walk(fn.child_by_field_name("body")):
            if node.type in ("if_expression", "for_expression", "while_expression",
                             "loop_expression", "try_expression"):
                counts[node.type] += 1
            elif node.type == "binary_expression":
                operator = node.child_by_field_name("operator")
                if operator and operator.text in (b"&&", b"||"):
                    counts["short_circuit"] += 1
            elif node.type == "match_block":
                counts["extra_match_arms"] += max(0, sum(
                    child.type == "match_arm" for child in node.named_children) - 1)
            elif node.type == "macro_invocation":
                counts["opaque_macros"] += 1
        opaque = counts.pop("opaque_macros", 0)
        yield dict(ref=ref, path=path, function=name,
                   first_line=fn.start_point.row + 1, last_line=fn.end_point.row + 1,
                   decisions=1 + sum(counts.values()), components=dict(counts),
                   opaque_macros=opaque)


def main():
    args = argparse.ArgumentParser(description=__doc__)
    args.add_argument("base")
    args.add_argument("head")
    args = args.parse_args()
    versions = {name: version(name) for name in ("tree-sitter", "tree-sitter-rust")}
    if versions != {"tree-sitter": "0.25.2", "tree-sitter-rust": "0.24.0"}:
        raise ValueError(f"use the pinned parser versions, got {versions}")
    parser = Parser(Language(tree_sitter_rust.language()))
    refs = [subprocess.check_output(["git", "rev-parse", ref], text=True).strip()
            for ref in (args.base, args.head)]
    rows = [row for ref in refs for path, names in FILES.items()
            for row in measure(parser, ref, path, names)]
    for ref in refs:
        for path, names in FILES.items():
            required = names[:1] if path.endswith("link_wait.rs") else (
                names[:5] if path.endswith("/run.rs") else names)
            found = {row["function"] for row in rows if row["ref"] == ref and row["path"] == path}
            if set(required) - found:
                raise ValueError(f"missing functions in {ref}:{path}: {set(required) - found}")
    print(json.dumps(dict(parser=versions, definition=__doc__, base=refs[0], head=refs[1],
                          rows=rows), indent=2))


if __name__ == "__main__":
    main()
