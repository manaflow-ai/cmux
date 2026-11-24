from cursorpage import iterate, paginate
from pytest_shim import raises


def rec(ts, i):
    return {"ts": ts, "id": i}


def ids(page):
    return [r["id"] for r in page.items]


def walk_forward(records, limit):
    out, cursor = [], None
    for _ in range(100):
        page = paginate(records, limit, after=cursor)
        out += ids(page)
        if page.next_cursor is None:
            return out
        cursor = page.next_cursor
    raise AssertionError("did not end")


def test_ties_are_not_skipped_forward():
    records = [rec(5, i) for i in range(40, 0, -1)] + [rec(9, 100)]
    assert walk_forward(records, 10) == list(range(1, 41)) + [100]


def test_ties_ordered_by_id_regardless_of_input_order():
    records = [rec(1, 3), rec(1, 1), rec(0, 9), rec(1, 2)]
    assert ids(paginate(records, 10)) == [9, 1, 2, 3]


def test_ties_are_not_skipped_backward():
    records = [rec(5, i) for i in range(1, 11)]
    page = paginate(records, 3, after=paginate(records, 6).next_cursor)
    assert ids(page) == [7, 8, 9]
    back = paginate(records, 3, before=page.prev_cursor)
    assert ids(back) == [4, 5, 6]
    back2 = paginate(records, 4, before=back.prev_cursor)
    assert ids(back2) == [1, 2, 3]
    assert back2.prev_cursor is None
    assert back2.next_cursor is not None


def test_no_next_cursor_when_page_ends_exactly_at_the_end():
    records = [rec(i, i) for i in range(6)]
    p1 = paginate(records, 3)
    assert p1.next_cursor is not None
    p2 = paginate(records, 3, after=p1.next_cursor)
    assert ids(p2) == [3, 4, 5]
    assert p2.next_cursor is None
    assert p2.prev_cursor is not None
    assert paginate(records, 6).next_cursor is None


def test_cursor_survives_deleting_its_record():
    records = [rec(i // 2, i) for i in range(8)]  # ts 0,0,1,1,2,2,3,3
    p1 = paginate(records, 3)
    assert ids(p1) == [0, 1, 2]
    records = [r for r in records if r["id"] != 2]
    p2 = paginate(records, 3, after=p1.next_cursor)
    assert ids(p2) == [3, 4, 5]


def test_insert_into_a_tie_behind_the_cursor_is_not_shown_again():
    records = [rec(5, 10), rec(5, 20), rec(5, 30), rec(5, 40)]
    p1 = paginate(records, 2)
    assert ids(p1) == [10, 20]
    records.append(rec(5, 15))  # sorts before the cursor
    records.append(rec(5, 25))  # sorts after it
    p2 = paginate(records, 10, after=p1.next_cursor)
    assert ids(p2) == [25, 30, 40]
    assert p2.prev_cursor is not None


def test_prev_cursor_is_none_when_nothing_is_before():
    records = [rec(i, i) for i in range(5)]
    p1 = paginate(records, 2)
    assert p1.prev_cursor is None
    remaining = [r for r in records if r["id"] >= 2]
    p2 = paginate(remaining, 2, after=p1.next_cursor)
    assert ids(p2) == [2, 3]
    assert p2.prev_cursor is None
    assert p2.next_cursor is not None


def test_before_page_next_cursor_when_tail_deleted():
    records = [rec(i, i) for i in range(6)]
    p = paginate(records, 6)
    last_page = paginate(records, 2, after=paginate(records, 4).next_cursor)
    assert ids(last_page) == [4, 5]
    shrunk = [r for r in records if r["id"] < 4]
    back = paginate(shrunk, 2, before=last_page.prev_cursor)
    assert ids(back) == [2, 3]
    assert back.next_cursor is None
    assert back.prev_cursor is not None
    assert p.next_cursor is None


def test_iterate_visits_everything_once_without_an_extra_fetch():
    records = [rec(i % 3, i) for i in range(9)]
    calls = []

    def fetch(cursor):
        calls.append(cursor)
        return records

    got = [r["id"] for r in iterate(fetch, 3)]
    assert sorted(got) == list(range(9))
    assert len(got) == 9
    assert len(calls) == 3


def test_argument_checks():
    raises(ValueError, paginate, [], 0)
    first = paginate([rec(1, 1), rec(2, 2)], 1)
    raises(ValueError, paginate, [], 1, first.next_cursor, first.next_cursor)
    raises(ValueError, paginate, [], 1, "!!not-a-cursor!!")
    empty = paginate([], 5)
    assert empty.items == [] and empty.next_cursor is None and empty.prev_cursor is None
