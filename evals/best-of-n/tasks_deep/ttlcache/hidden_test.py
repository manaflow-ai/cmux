from ttlcache import TTLCache


class Clock:
    def __init__(self, t=1000.0):
        self.t = t

    def __call__(self):
        return self.t


def make(maxsize=3, ttl=10):
    c = Clock()
    return c, TTLCache(maxsize, ttl, clock=c)


def test_in_is_false_once_expired():
    clock, cache = make()
    cache.set("s", 1)
    clock.t += 9.999
    assert "s" in cache
    clock.t += 0.001
    assert "s" not in cache
    assert cache.get("s") is None


def test_len_counts_only_live_entries():
    clock, cache = make()
    cache.set("a", 1)
    cache.set("b", 2, ttl=30)
    assert len(cache) == 2
    clock.t += 10
    assert len(cache) == 1
    clock.t += 20
    assert len(cache) == 0


def test_items_and_keys_skip_expired():
    clock, cache = make()
    cache.set("a", 1, ttl=5)
    cache.set("b", 2)
    cache.set("c", 3, ttl=5)
    clock.t += 5
    assert cache.items() == [("b", 2)]
    assert cache.keys() == ["b"]


def test_peek_returns_default_for_expired():
    clock, cache = make()
    cache.set("a", "v", ttl=2)
    assert cache.peek("a") == "v"
    clock.t += 2
    assert cache.peek("a") is None
    assert cache.peek("a", "dflt") == "dflt"


def test_expired_entries_make_room_before_live_ones_are_evicted():
    clock, cache = make(maxsize=2)
    cache.set("keep", 1, ttl=100)
    cache.set("short", 2, ttl=1)
    clock.t += 1
    cache.set("new", 3)
    assert cache.get("keep") == 1
    assert cache.get("new") == 3
    assert len(cache) == 2


def test_lru_eviction_when_all_live():
    clock, cache = make(maxsize=2)
    cache.set("a", 1)
    cache.set("b", 2)
    assert cache.get("a") == 1  # b is now least recently used
    cache.set("c", 3)
    assert "b" not in cache
    assert cache.get("a") == 1 and cache.get("c") == 3


def test_peek_and_in_do_not_touch_recency():
    clock, cache = make(maxsize=2)
    cache.set("a", 1)
    cache.set("b", 2)
    assert cache.peek("a") == 1
    assert "a" in cache
    cache.set("c", 3)
    assert cache.get("a") is None
    assert cache.get("b") == 2


def test_set_existing_key_refreshes_ttl_and_does_not_evict():
    clock, cache = make(maxsize=2)
    cache.set("a", 1)
    cache.set("b", 2)
    clock.t += 8
    cache.set("a", 10)
    assert len(cache) == 2
    clock.t += 5
    assert cache.get("a") == 10
    assert "b" not in cache


def test_items_order_is_lru_first():
    clock, cache = make(maxsize=3)
    cache.set("a", 1)
    cache.set("b", 2)
    cache.set("c", 3)
    cache.get("a")
    assert cache.keys() == ["b", "c", "a"]


def test_stats_size_counts_live():
    clock, cache = make()
    cache.set("a", 1, ttl=1)
    cache.get("a")
    clock.t += 1
    cache.get("a")
    st = cache.stats()
    assert st["hits"] == 1 and st["misses"] == 1
    assert st["size"] == 0


def test_fast_on_a_full_cache():
    import time as _t
    clock, cache = make(maxsize=1000, ttl=5)
    for i in range(1000):
        cache.set(i, i, ttl=1000)
    start = _t.perf_counter()
    n = 0
    for i in range(25000):
        clock.t += 0.001
        cache.set(1000 + i, i, ttl=3 + (i % 7))
        cache.get(i % 3000)
        n += (i in cache)
        n += len(cache)
    assert _t.perf_counter() - start < 1.5
    assert len(cache) <= 1000


def test_random_ops_match_a_model():
    import random
    rng = random.Random(7)
    for trial in range(60):
        maxsize = rng.randint(1, 5)
        clock, cache = make(maxsize=maxsize, ttl=4)
        model = {}  # key -> [value, expires_at, last_used]
        tick = [0]

        def live():
            return {k: v for k, v in model.items() if clock.t < v[1]}

        def touch(k):
            tick[0] += 1
            model[k][2] = tick[0]

        for step in range(80):
            clock.t += rng.choice((0, 0, 0.5, 1, 3))
            op = rng.choice(("set", "set", "get", "peek", "in", "len", "items", "delete"))
            k = rng.choice("abcdefg")
            where = (trial, step, op, k)
            if op == "set":
                ttl = rng.choice((None, 1, 2, 10))
                cur = live()
                if k not in cur and len(cur) >= maxsize:
                    victim = min(cur, key=lambda x: cur[x][2])
                    del model[victim]
                model[k] = [step, clock.t + (4 if ttl is None else ttl), 0]
                touch(k)
                cache.set(k, step, ttl=ttl)
            elif op == "get":
                cur = live()
                want = cur[k][0] if k in cur else None
                assert cache.get(k) == want, where
                if k in cur:
                    touch(k)
            elif op == "peek":
                cur = live()
                assert cache.peek(k, "-") == (cur[k][0] if k in cur else "-"), where
            elif op == "in":
                assert (k in cache) == (k in live()), where
            elif op == "len":
                assert len(cache) == len(live()), where
            elif op == "items":
                cur = live()
                want = [(x, cur[x][0]) for x in sorted(cur, key=lambda x: cur[x][2])]
                assert cache.items() == want, where
            else:
                assert cache.delete(k) == (k in live()), where
                model.pop(k, None)
