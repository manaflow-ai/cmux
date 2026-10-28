#!/usr/bin/env python3
"""Static p04-input done checks at any git ref (plans/cmux-next/chrome-parity/p04-input.md, sections 5 and 6).

It reads git objects only (`git grep REF`, `git show REF:PATH`): no checkout, no build, any host. It counts DC6,
DC7 and the static machine queues of DC14, and splits each DC14 queue into allowed and unallowed hits by the
rule of the task that closes it:

  main-nonswift   allowed with `// main-hop-allow:` or `// input-hop-allow:` on the hit line or the 3 lines
                  above it (tasks 080-082; guardrails.py rule main-hop).
  pointer         allowed when the handler body posts to a frame coalescer (`.post(event`, a coalescer, a
                  PointerFrameHover) or says `// input-coalesce: native` (tasks 031-038, 088, 089).
  observation     a `withObservationTracking` whose next 4 lines start a `Task {` (tasks 026-029).
  global-state    NSEvent.modifierFlags / mouseLocation / pressedMouseButtons in a func that takes an NSEvent and
                  without `// global-input-allow:` (task 095).
  cursor-rects    every `func resetCursorRects` is unallowed (task 090 replaces them with cursorUpdate).

A hit on a comment line is not code and is not counted.

Usage:
  input-queues.py REF [REF ...]           one Markdown row per check, one column per REF
  input-queues.py REF --list QUEUE        the unallowed hits of QUEUE at REF (file:line)
  input-queues.py --self-test
"""
from __future__ import annotations

import argparse
import re
import subprocess
import sys
from dataclasses import dataclass, field
from typing import Callable

SOURCES = "Packages/macOS/CmuxNext/Sources"
COMMENT = re.compile(r"^\s*//")
NONSWIFT = (r"DispatchQueue\.main\.(async|asyncAfter|sync)|CFRunLoopPerformBlock|performSelector\(onMainThread|"
            r"RunLoop\.main\.perform|queue: *(\.main|OperationQueue\.main)|DispatchSource\.make.*queue: \.main")
POINTER = r"override (public |open |package )?func (mouseMoved|mouseDragged|rightMouseDragged|otherMouseDragged)\("
HOP_ALLOW = re.compile(r"(main|input)-hop-allow:")
COALESCED = re.compile(r"\.post\(event\b|[Cc]oalesc|PointerFrameHover|input-coalesce: native")
NATIVE = re.compile(r"input-coalesce: native")
TASK_HOP = re.compile(r"\bTask\s*\{")
FUNC = re.compile(r"\bfunc\s+\w+")
EVENT_PARAMETER = re.compile(r"\bNSEvent\b(?!\.)")
GLOBAL_ALLOW = re.compile(r"global-input-allow:")


@dataclass
class Hit:
    path: str
    line: int  # 1-based
    text: str


@dataclass
class Check:
    name: str
    pattern: str
    excludes: tuple[str, ...] = ()
    root: str = SOURCES
    # (hit, lines of its file) -> True when the hit counts against the check; None counts every code hit.
    unallowed: Callable[[Hit, list[str]], bool] | None = None
    pass_text: str = "0"
    seen: dict[str, int] = field(default_factory=dict)


def hop_unallowed(hit: Hit, lines: list[str]) -> bool:
    window = lines[max(0, hit.line - 4):hit.line]
    return not any(HOP_ALLOW.search(line) for line in window)


def function_body(lines: list[str], index: int, limit: int = 60) -> list[str]:
    """The lines of the func declared at INDEX (0-based) up to its closing brace, at most LIMIT lines."""
    depth, opened, body = 0, False, []
    for line in lines[index:index + limit]:
        body.append(line)
        depth += line.count("{") - line.count("}")
        opened = opened or "{" in line
        if opened and depth <= 0:
            break
    return body


def pointer_unallowed(hit: Hit, lines: list[str]) -> bool:
    if any(NATIVE.search(line) for line in lines[max(0, hit.line - 3):hit.line - 1]):
        return False
    return not any(COALESCED.search(line) for line in function_body(lines, hit.line - 1))


def observation_unallowed(hit: Hit, lines: list[str]) -> bool:
    after = lines[hit.line - 1:hit.line + 4]
    return any(TASK_HOP.search(line) and not COMMENT.match(line) for line in after)


def global_state_unallowed(hit: Hit, lines: list[str]) -> bool:
    if any(GLOBAL_ALLOW.search(line) for line in lines[max(0, hit.line - 4):hit.line]):
        return False
    signature = next((lines[i] for i in range(hit.line - 1, -1, -1) if FUNC.search(lines[i])), "")
    return EVENT_PARAMETER.search(signature) is not None


CHECKS = [
    Check("DC6 NSEvent monitors outside CmuxNextInput", r"NSEvent\.add(Local|Global)MonitorForEvents",
          excludes=(f"{SOURCES}/CmuxNextInput/",)),
    Check("DC6 inputObserver in CmuxNextApp", r"inputObserver", root=f"{SOURCES}/CmuxNextApp"),
    Check("DC7 NSApp.currentEvent reads", r"NSApp(lication\.shared)?\.currentEvent",
          excludes=(f"{SOURCES}/CmuxNextInput/", "InputDispatchContext.swift", "current-event: target-action")),
    Check("DC7 nextEvent(matching tracking loops", r"nextEvent\(matching"),
    Check("DC14 MQ-main-nonswift unallowed", NONSWIFT, unallowed=hop_unallowed),
    Check("DC14 MQ-pointer-per-event without a coalescer", POINTER, unallowed=pointer_unallowed),
    Check("DC14 MQ-observation-hop", r"withObservationTracking", unallowed=observation_unallowed),
    Check("DC14 MQ-global-input-state inside NSEvent handlers",
          r"NSEvent\.(modifierFlags|mouseLocation|pressedMouseButtons)", unallowed=global_state_unallowed),
    Check("DC14 MQ-cursor-rects", r"func resetCursorRects"),
    Check("MQ-daemon-input-qos pthread_set_qos_class_self_np (spawn sites with a QoS)",
          r"pthread_set_qos_class_self_np", root="cmux-tui/crates", pass_text="runtime: DC9 taskinfo"),
]


def git(*args: str) -> str:
    done = subprocess.run(["git", *args], capture_output=True, text=True)
    if done.returncode not in (0, 1):  # git grep exits 1 for no match
        raise SystemExit(f"git {' '.join(args)}: {done.stderr.strip()}")
    return done.stdout


def grep(ref: str, pattern: str, root: str) -> list[Hit]:
    hits = []
    for row in git("grep", "-n", "-P", pattern, ref, "--", root).splitlines():
        _, path, number, text = row.split(":", 3)
        hits.append(Hit(path, int(number), text))
    return hits


class Files:
    def __init__(self, ref: str):
        self.ref, self.cache = ref, {}

    def __call__(self, path: str) -> list[str]:
        if path not in self.cache:
            self.cache[path] = git("show", f"{self.ref}:{path}").splitlines()
        return self.cache[path]


def evaluate(check: Check, hits: list[Hit], files: Callable[[str], list[str]]) -> tuple[int, list[Hit]]:
    """(code hits, the hits that count against CHECK)."""
    code = [h for h in hits if not COMMENT.match(h.text)
            and not any(x in h.path or x in h.text for x in check.excludes)]
    if check.unallowed is None:
        return len(code), code
    return len(code), [h for h in code if check.unallowed(h, files(h.path))]


def table(refs: list[str]) -> str:
    rows = ["| Check | Pass | " + " | ".join(f"`{r[:11]}` hits / counted" for r in refs) + " |",
            "|---|---|" + "---|" * len(refs)]
    for check in CHECKS:
        cells = []
        for ref in refs:
            code, counted = evaluate(check, grep(ref, check.pattern, check.root), Files(ref))
            cells.append(f"{code} / {len(counted)}")
        rows.append(f"| {check.name} | {check.pass_text} | " + " | ".join(cells) + " |")
    return "\n".join(rows)


def self_test() -> int:
    failures = []

    def expect(name: str, got, want) -> None:
        if got != want:
            failures.append(f"{name}: got {got!r}, want {want!r}")

    src = [
        "    override func mouseDragged(with event: NSEvent) {",
        "        frameDrag.post(event)",
        "    }",
        "    override func mouseMoved(with event: NSEvent) {",
        "        update(event.locationInWindow)",
        "    }",
        "    // input-coalesce: native (forwards to the next responder)",
        "    override func otherMouseDragged(with event: NSEvent) { super.otherMouseDragged(with: event) }",
    ]
    expect("pointer posts", pointer_unallowed(Hit("a", 1, src[0]), src), False)
    expect("pointer direct", pointer_unallowed(Hit("a", 4, src[3]), src), True)
    expect("pointer native", pointer_unallowed(Hit("a", 8, src[7]), src), False)
    hop = ["        // main-hop-allow: menu tracking needs the next turn", "        DispatchQueue.main.async {",
           "        x()", "        y()", "        z()", "        DispatchQueue.main.async { y() }"]
    expect("hop allowed", hop_unallowed(Hit("a", 2, hop[1]), hop), False)
    expect("hop bare", hop_unallowed(Hit("a", 6, hop[5]), hop), True)
    obs = ["withObservationTracking {", "  read()", "} onChange: {", "  Task { @MainActor in apply() }", "}",
           "withObservationTracking { read() } onChange: { apply() }", "", "", "", "", ""]
    expect("observation hop", observation_unallowed(Hit("a", 1, obs[0]), obs), True)
    expect("observation inline", observation_unallowed(Hit("a", 6, obs[5]), obs), False)
    state = ["override func mouseDown(with event: NSEvent) {", "  let m = NSEvent.modifierFlags", "}",
             "func refresh() {", "  let p = NSEvent.mouseLocation", "}",
             "func track(_ event: NSEvent) {", "  // global-input-allow: the drag outlives the event",
             "  let b = NSEvent.pressedMouseButtons", "}"]
    expect("state in handler", global_state_unallowed(Hit("a", 2, state[1]), state), True)
    expect("state outside", global_state_unallowed(Hit("a", 5, state[4]), state), False)
    expect("state allowed", global_state_unallowed(Hit("a", 9, state[8]), state), False)
    monitor = next(c for c in CHECKS if c.name.startswith("DC6 NSEvent"))
    hits = [Hit(f"{SOURCES}/CmuxNextInput/InputEventTap.swift", 3, "NSEvent.addLocalMonitorForEvents"),
            Hit(f"{SOURCES}/CmuxNextApp/A.swift", 9, "    /// NSEvent.addLocalMonitorForEvents"),
            Hit(f"{SOURCES}/CmuxNextApp/A.swift", 12, "    NSEvent.addLocalMonitorForEvents(matching: .keyDown)")]
    expect("monitor excludes the tap and comments", evaluate(monitor, hits, lambda _: [])[0], 1)
    for line in failures:
        print(f"FAIL {line}")
    print(f"input-queues self-test: {'ok' if not failures else f'{len(failures)} failing'}")
    return 1 if failures else 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("refs", nargs="*")
    parser.add_argument("--list", metavar="QUEUE", help="print the counted hits of the check whose name has QUEUE")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        return self_test()
    if not args.refs:
        parser.error("name at least one ref")
    if args.list:
        check = next((c for c in CHECKS if args.list in c.name), None)
        if check is None:
            parser.error(f"no check named like {args.list!r}")
        ref = args.refs[0]
        _, counted = evaluate(check, grep(ref, check.pattern, check.root), Files(ref))
        for hit in counted:
            print(f"{hit.path}:{hit.line}")
        return 0
    print(table(args.refs))
    return 0


if __name__ == "__main__":
    sys.exit(main())
