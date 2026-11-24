Fix the retry scheduling in `backoff.py`.

Bug report: the object store answered 429 with `Retry-After: 120`. Our client retried after a few seconds (and never
later than 30 s, our `max_delay`), got 429 again, and burned through its attempts. When a server tells us when to
come back, we have to listen.

Contract for `RetryPolicy.next_delay(failures, elapsed, retry_after=None)` (and so for `call_with_retries`):
- `max_attempts` is the total number of times the callable may be called, the first call included.
- Without a server hint, the delay after the n-th failure is the nominal delay `min(max_delay, base * factor**(n-1))`;
  with `jitter` it is `rng() * nominal` instead, so it always lies in `[0, nominal)` (one `rng()` draw per delay).
- A server's `retry_after` replaces that delay with exactly `retry_after` seconds: no jitter, no `max_delay` cap.
  A `retry_after` of zero or less (clock skew between us and the server) means retry at once: a delay of 0.0.
- With a `deadline`, no attempt may start more than `deadline` seconds after the first one started. A computed delay
  that would cross the deadline is shortened to end exactly at it; when no time remains, or a server's `retry_after`
  would cross the deadline, give up (`None`).
- Keep the public API as it is.
