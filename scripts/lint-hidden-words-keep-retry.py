#!/usr/bin/env python3
"""Keep the test that a long outage still shows Retry when the connection words are hidden.

Leo, 2026-11-27: "Hidden-error changes keep Retry tested. When connection text is hidden, a test
still checks that a long outage shows Retry or Reconnect.." (skills/cmux-ios/SKILL.md, "Quiet-state
rules keep the way out"; #61760 found the terminal menu's Reconnect dead for every reattach after the
words went, and no test noticed).

Fails when:
  * the test file is gone, or one of its checks (the hidden-words test, `offersRetry`, the stalled stage)
    is gone from it;
  * a `TerminalConnectionState` case is not listed in the test's `downStates` (except `attached`);
  * the stalled panel no longer draws `RetryButton` behind `offersRetry`.

`--self-test` runs the checks against built-in examples.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
KIT = "cmux-next-ios/CmuxMobileKit"
TEST = f"{KIT}/Tests/CmuxMobileTerminalTests/HiddenWordsKeepRetryTests.swift"
STATE = f"{KIT}/Sources/CmuxMobileTerminal/Session/TerminalSession.swift"
PANEL = f"{KIT}/Sources/CmuxMobileTerminal/Screen/TerminalConnectingView.swift"

TEST_NEEDS = (
    "func aLongOutageShowsRetryWithItsWordsHidden",
    "func everyDownStateShowsRetryPastTheBound",
    "TerminalLoadStalledPanel.offersRetry(state)",
    "== .stalled",
    "static let downStates",
)


def state_cases(source: str) -> list[str]:
    m = re.search(r"public enum TerminalConnectionState\b[^{]*\{(.*?)\n\}", source, re.S)
    if not m:
        return []
    return re.findall(r"^\s*case\s+(\w+)", m.group(1), re.M)


def problems(test: str | None, state: str | None, panel: str | None) -> list[str]:
    out: list[str] = []
    if test is None:
        return [f"{TEST} is gone: a long outage with hidden words must keep a Retry test"]
    out += [f"{TEST}: lost `{need}`" for need in TEST_NEEDS if need not in test]
    if state is None:
        out.append(f"{STATE} is gone: move this lint with TerminalConnectionState")
    else:
        cases = state_cases(state)
        if not cases:
            out.append(f"{STATE}: TerminalConnectionState not found")
        listed = test.split("static let downStates", 1)[-1].split("= [", 1)[-1].split("]", 1)[0]
        out += [f"{TEST}: downStates does not list `.{c}`" for c in cases
                if c != "attached" and f".{c}(" not in listed]
    if panel is None or not re.search(r"if Self\.offersRetry\(state\)\s*\{\s*RetryButton\(", panel):
        out.append(f"{PANEL}: TerminalLoadStalledPanel must draw RetryButton behind offersRetry(state)")
    return out


def read(rel: str) -> str | None:
    p = REPO_ROOT / rel
    return p.read_text() if p.exists() else None


def self_test() -> int:
    state = "public enum TerminalConnectionState: Equatable {\n    case connecting(mac: String?)\n    case gone\n    case attached\n}\n"
    good = "\n".join(TEST_NEEDS) + "\nstatic let downStates: [State] = [.connecting(mac: nil), .gone(]\n"
    panel = "if Self.offersRetry(state) {\n RetryButton(action: retry)"
    assert problems(good, state, panel) == [], problems(good, state, panel)
    assert problems(None, state, panel)
    assert any(".gone" in p for p in problems(good.replace(".gone(", ""), state, panel))
    assert problems(good.replace("func everyDownStateShowsRetryPastTheBound", ""), state, panel)
    assert problems(good, state, "RetryButton(action: retry)")
    print("lint-hidden-words-keep-retry: self-test ok")
    return 0


def main(argv: list[str]) -> int:
    if "--self-test" in argv:
        return self_test()
    found = problems(read(TEST), read(STATE), read(PANEL))
    for p in found:
        print(f"::error::{p}")
    if found:
        print("Leo, 2026-11-27: \"Hidden-error changes keep Retry tested.\" Restore the test or move it with the code.")
        return 1
    print("lint-hidden-words-keep-retry: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
