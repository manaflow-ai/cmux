import random

from promptmark import ShellMarks, MARK, KEYBOARD_RESET as K, PROMPT_RESET as P

A, C, D = MARK + b"A\x07", MARK + b"C\x07", MARK + b"D;0\x07"


def run(chunks):
    m = ShellMarks()
    return b"".join(m.feed(c) for c in chunks) + m.flush()


def test_whole_chunks():
    assert run([A + b"$ ls\r\n" + C + b"out" + D + A]) == P + A + b"$ ls\r\n" + C + b"out" + K + D + P + A
    assert run([b"plain text"]) == b"plain text"
    assert run([D]) == D
    assert run([C + A]) == C + A
    assert run([MARK + b"B\x07"]) == MARK + b"B\x07"


def test_split_prompt_mark():
    # ed21d9f61e3: the mark arrives split across two reads.
    assert run([b"x\x1b]13", b"3;A\x07"]) == b"x" + P + A
    assert run([b"x\x1b", b"]133;A\x07"]) == b"x" + P + A
    assert run([b"x" + MARK, b"A\x07"]) == b"x" + P + A


def test_split_finish_mark():
    assert run([C + b"out\x1b]1", b"33;D;0\x07"]) == C + b"out" + K + D


def test_holds_only_a_mark_prefix():
    m = ShellMarks()
    assert m.feed(b"ab\x1b]1") == b"ab"
    assert m.flush() == b"\x1b]1"
    m = ShellMarks()
    assert m.feed(b"ab\x1bX") == b"ab\x1bX"
    assert m.feed(b"]133;") == b"]133;"
    assert m.feed(b"\x1b[0m") == b"\x1b[0m"
    assert m.flush() == b""
    m = ShellMarks()
    assert m.feed(b"\x1b") == b""
    assert m.feed(b"x") == b"\x1bx"


def test_every_split_matches_unsplit():
    rng = random.Random(7)
    stream = b"".join(rng.choice([A, C, D, b"text", b"\x1b[0m", b"\x1b]0;t\x07", b"\x1b", b"]133;"]) for _ in range(40))
    whole = run([stream])
    for i in range(len(stream) + 1):
        assert run([stream[:i], stream[i:]]) == whole, i
    for _ in range(200):
        cuts = sorted(rng.sample(range(len(stream) + 1), 6))
        parts = [stream[a:b] for a, b in zip([0] + cuts, cuts + [len(stream)])]
        assert run(parts) == whole
    assert run([bytes([b]) for b in stream]) == whole
