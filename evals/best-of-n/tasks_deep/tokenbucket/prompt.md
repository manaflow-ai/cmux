Fix `TokenBucket` in `tokenbucket.py`, the rate limiter in front of our outbound API client.

Bug report: our job runner drains a bucket, then asks `wait_time()` how long to sleep before the next request. Ten
seconds later (the bucket refills at 1 token/s) `wait_time()` still says 1.0, while `try_acquire()` succeeds at once.
So the runner keeps sleeping when it could be sending.

Contract:
- A bucket starts full. Tokens accrue continuously at `rate` per second of clock time, but the bucket never holds
  more than `burst` tokens: time the bucket spends full earns nothing toward later.
- Every public read answers for the clock at the moment of the call. `wait_time(cost)` is exactly how long from now
  until `try_acquire(cost)` would succeed if nothing else happened in between (0.0 when it would succeed now).
- A cost above `burst` can never be granted: `try_acquire` returns `False`, `wait_time` returns `math.inf` and
  `acquire` raises `ValueError`.
- `refund` gives tokens back, but never raises the bucket above `burst`.
- Keep the public API as it is.

The clock is the host's monotonic clock in production but a wall clock in some deployments, where NTP can step it
backwards. A backwards step must never create tokens or leave the bucket stuck: the bucket keeps what it had and
accrues from the new reading onward.
