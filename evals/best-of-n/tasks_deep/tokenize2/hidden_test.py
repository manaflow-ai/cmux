import os
import random
import subprocess
import sys
import textwrap

import tokenize2
from tokenize2 import Tokenizer, tokenize, visible_text


def joined(tokens):
    out = []
    for kind, b in tokens:
        if kind == "text" and out and out[-1][0] == "text":
            out[-1] = ("text", out[-1][1] + b)
        elif kind != "text" or b:
            out.append((kind, b))
    return out


def chunked(data, cuts):
    t = Tokenizer()
    out = []
    prev = 0
    for c in sorted(cuts) + [len(data)]:
        out += t.feed(data[prev:c])
        prev = c
    return joined(out + t.flush())


def bounded(code, limit):
    try:
        out = subprocess.run([sys.executable, "-c", "import time\n" + textwrap.dedent(code)], capture_output=True,
                             text=True, timeout=limit * 5 + 3,
                             cwd=os.path.dirname(os.path.abspath(tokenize2.__file__)))
    except subprocess.TimeoutExpired:
        raise AssertionError("too slow")
    assert out.returncode == 0, out.stderr[-400:]
    assert float(out.stdout.split()[-1]) < limit, out.stdout


def test_one_shot_rules_regressions():
    assert joined(tokenize(b"a\x1b[1;31mb\x1b]0;title\x07c\x1b]8;;u\x1b\\d\x1b(Be")) == [
        ("text", b"a"), ("csi", b"\x1b[1;31m"), ("text", b"b"), ("osc", b"\x1b]0;title\x07"), ("text", b"c"),
        ("osc", b"\x1b]8;;u\x1b\\"), ("text", b"d"), ("esc", b"\x1b(B"), ("text", b"e")]
    assert joined(tokenize(b"x\x1b[3\x18y\x1b]t\x1az\x18")) == [
        ("text", b"xyz\x18")]
    assert joined(tokenize(b"\x1b[1\n2\x7fA")) == [("text", b"\n"), ("csi", b"\x1b[12A")]
    assert joined(tokenize(b"\x1b[1\r\x1b[2J")) == [("text", b"\r"), ("csi", b"\x1b[2J")]
    assert joined(tokenize(b"\x1b[1\xc3\xa9")) == [("text", b"\xc3\xa9")]
    assert joined(tokenize(b"\x1b]0;a\x1bM")) == [("esc", b"\x1bM")]
    assert joined(tokenize(b"\x1b\x01q")) == [("text", b"\x01q")]
    assert visible_text(b"\x1b[1mbold\x1b[0m \x1b]0;t\x07ok") == b"bold ok"


def test_flush_drops_unfinished_but_keeps_controls():
    t = Tokenizer()
    out = t.feed(b"ab\x1b[1\t2")
    out += t.flush()
    assert joined(out) == [("text", b"ab\t")]
    t = Tokenizer()
    assert joined(t.feed(b"q\x1b]52;c;AAAA") + t.flush()) == [("text", b"q")]


def test_text_comes_out_without_waiting():
    t = Tokenizer()
    assert joined(t.feed(b"hello")) == [("text", b"hello")]
    assert joined(t.feed(b" there\x1b[")) == [("text", b" there")]
    assert joined(t.feed(b"2")) == []
    assert joined(t.feed(b"Jok")) == [("csi", b"\x1b[2J"), ("text", b"ok")]


def test_reported_st_split_across_reads():
    data = b"\x1b]8;;https://x.test\x1b\\link\x1b]8;;\x1b\\"
    whole = joined(tokenize(data))
    assert whole == [("osc", b"\x1b]8;;https://x.test\x1b\\"), ("text", b"link"), ("osc", b"\x1b]8;;\x1b\\")]
    for cut in range(1, len(data)):
        assert chunked(data, [cut]) == whole, cut


def test_any_chunking_gives_the_same_tokens():
    rnd = random.Random(5)
    pieces = [b"ab", b"\n", b"\x1b[", b"1;2", b"m", b"\x1b]0;", b"t", b"\x07", b"\x1b\\", b"\x1b", b"\x18", b"\x1a",
              b"(", b"B", b"\x7f", b"\xc3\xa9", b"\t", b"]", b"\\", b"J"]
    for _ in range(400):
        data = b"".join(rnd.choice(pieces) for _ in range(rnd.randint(1, 14)))
        whole = joined(tokenize(data))
        for _ in range(4):
            cuts = rnd.sample(range(1, len(data)), min(len(data) - 1, rnd.randint(1, 5))) if len(data) > 1 else []
            assert chunked(data, cuts) == whole, (data, cuts)
        assert chunked(data, list(range(1, len(data)))) == whole, data


def test_big_osc_in_small_reads_is_fast():
    bounded("""
        from tokenize2 import Tokenizer
        payload = b"\\x1b]52;c;" + b"QUJD" * (2 << 20) + b"\\x1b\\\\"
        data = b"before" + payload + b"after"
        t = Tokenizer()
        out = []
        start = time.perf_counter()
        for i in range(0, len(data), 4096):
            out += t.feed(data[i:i + 4096])
        out += t.flush()
        el = time.perf_counter() - start
        oscs = [b for k, b in out if k == "osc"]
        assert oscs == [payload], len(oscs)
        assert b"".join(b for k, b in out if k == "text") == b"beforeafter"
        print(el)
    """, 1.0)


def test_big_mixed_stream_in_small_reads_is_fast():
    bounded("""
        from tokenize2 import Tokenizer
        line = b"\\x1b[32mok\\x1b[0m compiling crate number 0042 of many\\r\\n"
        data = line * 60000
        t = Tokenizer()
        n = 0
        start = time.perf_counter()
        for i in range(0, len(data), 4096):
            n += sum(k == "csi" for k, _ in t.feed(data[i:i + 4096]))
        el = time.perf_counter() - start
        assert n == 120000, n
        print(el)
    """, 1.5)
