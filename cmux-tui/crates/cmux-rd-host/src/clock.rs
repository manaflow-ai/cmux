//! CLOCK_MONOTONIC timestamps in nanoseconds (the protocol clock).

#[cfg(not(windows))]
pub fn now_ns() -> u64 {
    let mut ts = libc::timespec { tv_sec: 0, tv_nsec: 0 };
    // SAFETY: clock_gettime writes into a valid timespec.
    unsafe { libc::clock_gettime(libc::CLOCK_MONOTONIC, &mut ts) };
    ts.tv_sec as u64 * 1_000_000_000 + ts.tv_nsec as u64
}

#[cfg(windows)]
pub fn now_ns() -> u64 {
    use std::sync::OnceLock;
    static EPOCH: OnceLock<std::time::Instant> = OnceLock::new();
    EPOCH.get_or_init(std::time::Instant::now).elapsed().as_nanos() as u64
}

/// Small xorshift PRNG (test patterns and inter-sample jitter; not cryptographic).
#[cfg(not(windows))]
pub struct Rng(u64);

#[cfg(not(windows))]
impl Rng {
    pub fn new(seed: u64) -> Self {
        Self(seed | 1)
    }

    pub fn next_u64(&mut self) -> u64 {
        let mut x = self.0;
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        self.0 = x;
        x
    }

    /// Uniform integer in [lo, hi].
    pub fn range(&mut self, lo: u64, hi: u64) -> u64 {
        lo + self.next_u64() % (hi - lo + 1)
    }
}

/// A mach absolute time `then` on the protocol clock (µs), given that the mach clock read `now`
/// ticks when the protocol clock read `now_us`; `numer`/`denom` is the mach timebase (ns per tick).
/// Signed: ScreenCaptureKit's frame display time is one such `then`, and it is usually the vsync
/// the frame will be shown at, a few ms after the frame reaches the capture callback, so it must
/// land after `now_us`, not be clamped onto it.
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
pub fn mach_to_protocol_us(now_us: u64, now: u64, then: u64, numer: u32, denom: u32) -> u64 {
    let ticks = i128::from(then) - i128::from(now);
    let offset_us = ticks * i128::from(numer) / i128::from(denom.max(1)) / 1000;
    (i128::from(now_us) + offset_us).clamp(0, i128::from(u64::MAX)) as u64
}

#[cfg(test)]
mod tests {
    use super::mach_to_protocol_us;

    /// Apple silicon's timebase: 125/3 ns a tick, so 24 ticks a µs.
    const NUMER: u32 = 125;
    const DENOM: u32 = 3;

    #[test]
    fn a_mach_time_lands_on_the_protocol_clock_on_either_side_of_now() {
        let (now_us, now) = (1_000_000, 10_000_000);
        // 3 ms ago and 3 ms ahead (a display time ScreenCaptureKit schedules for a coming vsync).
        assert_eq!(mach_to_protocol_us(now_us, now, now - 72_000, NUMER, DENOM), 997_000);
        assert_eq!(mach_to_protocol_us(now_us, now, now + 72_000, NUMER, DENOM), 1_003_000);
        assert_eq!(mach_to_protocol_us(now_us, now, now, NUMER, DENOM), now_us);
        // An identity timebase (Intel): ticks are ns.
        assert_eq!(mach_to_protocol_us(now_us, now, now + 5_000_000, 1, 1), 1_005_000);
        // Never before the protocol clock's zero.
        assert_eq!(mach_to_protocol_us(10, now, 0, 1, 1), 0);
    }
}
