Fix the expiry handling in `ttlcache.py`, the LRU + TTL cache our session layer uses.

Bug report: a user's session expired, yet `if session_id in cache:` still took the "already signed in" branch, and
then `cache.get(session_id)` returned `None` and the request crashed. `get` clearly knows the session is gone; `in`
does not.

Contract:
- An entry expires when the clock reaches `set time + ttl` (the per-entry `ttl` passed to `set`, else the cache's).
  From that instant on, an expired entry is indistinguishable from a key that was never set, through every public
  read of the cache.
- The cache holds at most `maxsize` live entries. Expired entries never take a live entry's place: `set` evicts a
  live entry only when `maxsize` live entries are already present, and then it evicts the least recently used one.
- Recency: `set` and a successful `get` make a key the most recently used. `peek` and `in` never change recency.
- Keep the public API as it is.

The cache sits on the request path: on a full cache of 1,000 entries, a mix of 100,000 `set`, `get`, `in` and `len`
calls must finish in under one second.
