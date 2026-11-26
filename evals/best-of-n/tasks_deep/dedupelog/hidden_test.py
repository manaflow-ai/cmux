import json
import random

from dedupelog import append, compact, get, next_seq, obsolete, replay


def put(seg, seq, key, value):
    append(seg, seq, key, value)
    return seg


def tomb(seg, seq, key):
    append(seg, seq, key, deleted=True)
    return seg


def parsed(lines):
    return [json.loads(l) for l in lines]


def test_compact_keeps_newer_tombstone_from_earlier_listed_segment():
    seg9 = put([], 5, "theme", "dark")
    put(seg9, 6, "font", "mono")
    seg10 = tomb([], 9, "theme")
    out = parsed(compact([seg10, seg9]))
    assert [(r["key"], r["seq"]) for r in out] == [("font", 6)]
    kept = parsed(compact([seg10, seg9], keep_tombstones=True))
    assert [(r["key"], r["seq"], r.get("deleted")) for r in kept] == [("font", 6, None), ("theme", 9, True)]


def test_replay_and_get_ignore_segment_order():
    old = put([], 1, "a", "old")
    put(old, 2, "b", "kept")
    new = put([], 7, "a", "new")
    tomb(new, 8, "b")
    for segs in ([old, new], [new, old]):
        assert replay(segs) == {"a": "new"}
        assert get(segs, "a") == "new"
        assert get(segs, "b", "gone") == "gone"


def test_old_tombstone_does_not_delete_newer_write():
    newer = put([], 10, "k", "v2")
    older = tomb([], 4, "k")
    for segs in ([newer, older], [older, newer]):
        assert replay(segs) == {"k": "v2"}
        assert get(segs, "k") == "v2"
        assert [r["seq"] for r in parsed(compact(segs))] == [10]


def test_next_seq_is_past_the_highest_seq():
    a = put([], 20, "x", 1)
    b = put([], 3, "y", 1)
    tomb(b, 4, "y")
    assert next_seq([a, b]) == 21
    assert next_seq([b, a]) == 21
    assert next_seq([tomb([], 30, "x"), a]) == 31
    assert next_seq([]) == 1
    assert next_seq([[]]) == 1


def test_seq_tie_goes_to_later_record():
    first = put([], 5, "k", "first")
    second = put([], 5, "k", "second")
    assert get([first, second], "k") == "second"
    assert get([second, first], "k") == "first"
    assert replay([first, second]) == {"k": "second"}
    assert [r["value"] for r in parsed(compact([first, second]))] == ["second"]
    same = put(put([], 3, "z", "a"), 3, "z", "b")
    assert get([same], "z") == "b"
    assert replay([same]) == {"z": "b"}
    deleted = tomb([], 5, "k")
    assert get([first, deleted], "k") is None
    assert replay([deleted, first]) == {"k": "first"}


def test_bad_lines_are_ignored_by_every_reader():
    seg = put([], 1, "a", 1)
    seg += ["", "   ", "{not json", "[1, 2]", '{"seq": "9", "key": "a", "value": 9}',
            '{"seq": 50, "value": 1}', '{"seq": 60, "key": 7, "value": 1}', '{"seq": 2, "key": "a", "val']
    assert replay([seg]) == {"a": 1}
    assert get([seg], "a") == 1
    assert next_seq([seg]) == 2
    assert [r["seq"] for r in parsed(compact([seg]))] == [1]


def test_compaction_is_ordered_and_idempotent():
    seg = []
    put(seg, 3, "c", 3)
    put(seg, 1, "a", 1)
    put(seg, 2, "b", 2)
    once = compact([seg])
    assert [r["seq"] for r in parsed(once)] == [1, 2, 3]
    assert compact([once]) == once
    assert replay([once]) == replay([seg])


def _model(segments):
    recs = []
    pos = 0
    for seg in segments:
        for line in seg:
            r = json.loads(line)
            recs.append((r["seq"], pos, r))
            pos += 1
    state = {}
    for _, _, r in sorted(recs, key=lambda t: (t[0], t[1])):
        if r.get("deleted"):
            state.pop(r["key"], None)
        else:
            state[r["key"]] = r["value"]
    return state


def test_random_logs_match_the_model():
    rng = random.Random(1234)
    for trial in range(200):
        seq = 0
        segments = [[] for _ in range(rng.randint(1, 5))]
        for _ in range(rng.randint(0, 30)):
            seq += rng.choice((0, 1, 1, 1, 2))
            seg = rng.choice(segments)
            key = rng.choice("abcde")
            if rng.random() < 0.3:
                tomb(seg, seq, key)
            else:
                put(seg, seq, key, rng.randint(0, 99))
        rng.shuffle(segments)
        want = _model(segments)
        assert replay(segments) == want, trial
        for key in "abcde":
            assert get(segments, key, "-") == want.get(key, "-"), (trial, key)
        assert replay([compact(segments)]) == want, trial
        kept = parsed(compact(segments, keep_tombstones=True))
        assert sorted(r["key"] for r in kept) == sorted({json.loads(l)["key"] for s in segments for l in s})
        top = max([json.loads(l)["seq"] for s in segments for l in s], default=0)
        assert next_seq(segments) == top + 1


def test_only_boolean_true_deleted_is_a_tombstone():
    seg = put([], 1, "a", "keep")
    seg.append('{"seq": 2, "key": "a", "deleted": 1, "value": "one"}')
    seg.append('{"seq": 3, "key": "b", "deleted": false, "value": "bee"}')
    seg.append('{"seq": 4, "key": "c", "value": "see"}')
    seg.append('{"seq": 5, "key": "c", "deleted": "yes", "value": "sea"}')
    assert replay([seg]) == {"a": "one", "b": "bee", "c": "sea"}
    assert get([seg], "a") == "one"
    assert [r["key"] for r in parsed(compact([seg]))] == ["a", "b", "c"]


def test_compaction_keeps_extra_fields():
    seg = ['{"seq": 1, "key": "k", "value": 1, "ts": "2026-01-01", "by": "w1"}',
           '{"seq": 2, "key": "k", "value": 2, "ts": "2026-01-02", "by": "w2"}']
    out = parsed(compact([seg]))
    assert out == [{"seq": 2, "key": "k", "value": 2, "ts": "2026-01-02", "by": "w2"}]


def test_obsolete_segments_ignore_listing_order():
    seg9 = put([], 5, "theme", "dark")
    seg10 = tomb([], 9, "theme")
    junk = ["", "{torn"]
    assert obsolete([seg10, seg9]) == [1]
    assert obsolete([seg9, seg10]) == [0]
    mixed = put(put([], 1, "a", 1), 2, "b", 2)
    newer_a = put([], 7, "a", 3)
    assert obsolete([newer_a, mixed, junk]) == [2]
    assert obsolete([put([], 4, "z", 1), put([], 4, "z", 2)]) == [0]
    assert obsolete([]) == []


def test_random_obsolete_matches_the_model():
    rng = random.Random(77)
    for trial in range(200):
        seq = 0
        segments = [[] for _ in range(rng.randint(1, 5))]
        for _ in range(rng.randint(0, 20)):
            seq += rng.choice((0, 1, 1, 2))
            seg = rng.choice(segments)
            key = rng.choice("abcd")
            if rng.random() < 0.3:
                tomb(seg, seq, key)
            else:
                put(seg, seq, key, rng.randint(0, 9))
        rng.shuffle(segments)
        best = {}
        for i, s in enumerate(segments):
            for line in s:
                r = json.loads(line)
                if r["key"] not in best or r["seq"] >= best[r["key"]][0]:
                    best[r["key"]] = (r["seq"], i)
        needed = {i for _, i in best.values()}
        assert obsolete(segments) == [i for i in range(len(segments)) if i not in needed], trial
