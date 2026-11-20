//! A bridged desktop chat whose app's turn failed on the account's rate limit (stub: the
//! behavior comes with the fix; this commit carries its regression test).

#[cfg(test)]
pub(super) static TEST_MIN_HOLD_MS: std::sync::atomic::AtomicU64 =
    std::sync::atomic::AtomicU64::new(0);

/// The line the app reads ahead of what the hold kept.
#[cfg(test)]
pub(super) const CONTINUE_LINE: &str = "acpmux: your last turn stopped on the account's rate limit (HTTP 429), so nothing you were sent since reached you until the limit reset. Check what that turn finished, answer the message it was working on, then each message below.";
