#!/usr/bin/env python3
"""A seeded, realistic typist for TYPING UNDER LOAD (Lawrence P0, 2026-11-02): the key plan only, no keys sent.

    typist.py plan --seed 7 --seconds 120 [--out plan.json]
    typist.py self-test

The plan is a list of events {i, t, kind, key, mods, text?, expect} with `t` the planned send time in seconds from
the start. Kinds: `char` (a printable key), `backspace`, `left`, `right`, `ctrl_c`, `paste` (Cmd-V of a clipboard text
the step sets first), `return`. The pace is a person's: words at 60-120 wpm (5 characters a word), faster inside a
word (bursts) than between words, a typo now and then that is fixed with Backspace, an arrow-key edit, a Ctrl-C about
every 25 s and a paste about every 35 s. `expect` is what the echo recorder (echo.py) must print for that event, so
the round checks the order and that no key is lost or doubled.
Python 3.9 standard library only (it also runs on the mini).
"""
import argparse
import json
import random
import sys

WORDS = ("git status make test cargo build ls cd src grep error todo vim main open file push pull merge diff log run "
         "echo cat head tail sort uniq find xargs curl json yaml python node bun swift zig rust docker kube deploy "
         "build fleet cmux pane split close tab window commit branch rebase stash fetch reset patch").split()


def plan(seed=7, seconds=120.0, wpm=(60, 120)):
    rng = random.Random(seed * 7919 + 13)
    out, t = [], 0.4
    next_ctrl_c, next_paste = rng.uniform(18, 30), rng.uniform(28, 40)
    line_len = 0

    def add(kind, key, mods=(), text=None, expect=None, gap=0.0):
        nonlocal t
        t += gap
        out.append({"i": len(out), "t": round(t, 4), "kind": kind, "key": key, "mods": list(mods),
                    **({"text": text} if text is not None else {}), "expect": expect})

    while t < seconds:
        speed = rng.uniform(*wpm)
        per_char = 60.0 / (speed * 5)
        word = rng.choice(WORDS)
        for k, ch in enumerate(word):
            burst = per_char * rng.uniform(0.45, 0.9)  # inside a word: faster
            if rng.random() < 0.04:  # a typo, then Backspace
                wrong = rng.choice("qwertyuiopasdfghjklzxcvbnm")
                add("char", wrong, expect=wrong, gap=burst)
                add("backspace", "delete", expect="\b", gap=rng.uniform(0.12, 0.3))
                line_len += 0
            add("char", ch, expect=ch, gap=burst)
            line_len += 1
        if rng.random() < 0.06 and line_len > 3:  # an arrow-key edit: left, type, right
            add("left", "left", expect="<L>", gap=rng.uniform(0.15, 0.35))
            add("char", "x", expect="x", gap=rng.uniform(0.1, 0.25))
            add("right", "right", expect="<R>", gap=rng.uniform(0.1, 0.25))
            line_len += 1
        add("char", " ", expect=" ", gap=per_char * rng.uniform(1.0, 2.2))  # between words: slower
        line_len += 1
        if t > next_ctrl_c:
            add("ctrl_c", "c", ["control"], expect="^C", gap=rng.uniform(0.3, 0.6))
            next_ctrl_c = t + rng.uniform(20, 30)
            line_len = 0
        elif t > next_paste:
            text = " ".join(rng.choice(WORDS) for _ in range(rng.randint(3, 8)))
            add("paste", "v", ["cmd"], text=text, expect=text, gap=rng.uniform(0.4, 0.8))
            next_paste = t + rng.uniform(30, 40)
            line_len += len(text)
        elif line_len > 70:
            add("return", "return", expect="\n", gap=rng.uniform(0.3, 0.6))
            line_len = 0
    return out


def self_test():
    a, b = plan(7, 120), plan(7, 120)
    assert a == b, "the plan is not seeded"
    kinds = {e["kind"] for e in a}
    assert {"char", "backspace", "ctrl_c", "paste", "return"} <= kinds, kinds
    gaps = [b["t"] - a_["t"] for a_, b in zip(a, a[1:])]
    assert min(gaps) > 0.02, min(gaps)
    chars = sum(1 for e in a if e["kind"] == "char")
    wpm = chars / 5 / (a[-1]["t"] / 60)
    assert 50 <= wpm <= 140, wpm
    print(f"self-test OK: {len(a)} events, {chars} chars, {wpm:.0f} wpm, min gap {min(gaps) * 1000:.0f} ms, kinds {sorted(kinds)}")


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("plan")
    p.add_argument("--seed", type=int, default=7)
    p.add_argument("--seconds", type=float, default=120)
    p.add_argument("--out")
    sub.add_parser("self-test")
    a = ap.parse_args()
    if a.cmd == "self-test":
        self_test()
        return 0
    text = json.dumps(plan(a.seed, a.seconds), indent=0)
    if a.out:
        open(a.out, "w").write(text)
    else:
        print(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
