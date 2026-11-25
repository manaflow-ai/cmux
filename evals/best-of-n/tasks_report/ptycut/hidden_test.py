# Ported from cmux-tui/crates/cmux-pty/src/input_queue.rs tests (cmux f7f9702ce84), plus spec edge cases.
from ptycut import cut, CAPACITY

R = b"\x1b[<65;30;7M"  # one SGR wheel report, 11 bytes


def test_whole_sequences_up_to_the_last_that_starts_in_the_room():
    reports = R * 3
    assert cut(reports, 12) == 11
    assert cut(reports, 23) == 22
    assert cut(reports, 11) == 11  # the ESC at index `room` counts
    assert cut(reports, 21) == 11


def test_a_sequence_that_does_not_fit_waits():
    assert cut(R, 1) is None
    assert cut(R, 5) is None
    assert cut(R, 0) is None
    assert cut(R + b"tail", 10) is None


def test_text_fills_the_room_never_ending_after_an_escape():
    assert cut(b"abcdef", 4) == 4
    assert cut(b"abc\x1b[A", 4) == 3
    assert cut(b"a\x1b", 1) == 1
    assert cut(b"abcdef", 0) is None


def test_fits_is_written_whole():
    assert cut(R, 11) == 11
    assert cut(b"", 0) == 0
    assert cut(b"abc", 100) == 3


def test_a_sequence_longer_than_the_queue_is_cut_where_it_must_be():
    long = b"\x1b]" + b"x" * (CAPACITY + 10)
    assert cut(long, 100) == 100
    assert cut(long, 1) is None  # would end right after its ESC
    assert cut(long, 0) is None
    assert cut(b"\x1b]xxxxxx", 3, capacity=4) == 3
    assert cut(b"\x1b]xx", 3, capacity=4) is None
    # A long first sequence with a later ESC inside the room still cuts before that ESC.
    assert cut(b"\x1b]" + b"x" * 20 + b"\x1b\\more", 25, capacity=8) == 22


def test_esc_at_index_zero_is_not_a_cut():
    assert cut(b"\x1b" + b"x" * 30, 10, capacity=8) == 10
    assert cut(b"\x1b[A\x1b[B", 2) is None
    assert cut(b"\x1b[A\x1b[B", 3) == 3
    assert cut(b"\x1b[A\x1b[B", 5) == 3


def test_never_ends_after_an_esc_randomized():
    import random
    rnd = random.Random(5)
    for _ in range(2000):
        buf = bytes(rnd.choice(b"ab\x1b[") for _ in range(rnd.randint(1, 40)))
        if b"\x1b\x1b" in buf:
            continue
        room = rnd.randint(0, len(buf))
        n = cut(buf, room, capacity=rnd.randint(1, 20))
        if n is None:
            continue
        assert 0 <= n <= max(room, 0) or (n == len(buf) and len(buf) <= room)
        if n < len(buf):
            assert n == 0 or buf[n - 1] != 0x1B
