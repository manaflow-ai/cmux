//! The trace clock: the clock every cmux process stamps records with, so traces from the app, the
//! daemon, the holder and the hosts merge with no guessed offset.
//!
//! - macOS: `CLOCK_UPTIME_RAW` in ns, the clock of `mach_absolute_time`, Chromium's `TimeTicks`
//!   (`base/time/time_mac.mm`) and the app's signposts. A commpage read, no kernel entry.
//! - Linux: `CLOCK_MONOTONIC` (a vDSO read).
//! - Windows: the performance counter (QPC), as Chromium's `TimeTicks` on Windows
//!   (`base/time/time_win.cc`).
//!
//! The header of each ring names its domain ([`ClockDomain`]), so a decoder never mixes two.

/// The clock a ring's `t_ns` values come from (header byte 21).
#[repr(u8)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ClockDomain {
    /// macOS `CLOCK_UPTIME_RAW`.
    UptimeRaw = 1,
    /// Linux and other unix `CLOCK_MONOTONIC`.
    Monotonic = 2,
    /// Windows `QueryPerformanceCounter`, in ns.
    Qpc = 3,
}

impl ClockDomain {
    /// The domain [`now_ns`] reads on this platform.
    pub const CURRENT: ClockDomain = if cfg!(target_os = "macos") {
        ClockDomain::UptimeRaw
    } else if cfg!(windows) {
        ClockDomain::Qpc
    } else {
        ClockDomain::Monotonic
    };

    /// The domain stored as `raw`, if it is one.
    pub fn from_raw(raw: u8) -> Option<ClockDomain> {
        match raw {
            1 => Some(ClockDomain::UptimeRaw),
            2 => Some(ClockDomain::Monotonic),
            3 => Some(ClockDomain::Qpc),
            _ => None,
        }
    }
}

/// Now on the trace clock, in ns. No allocation, lock or kernel entry on macOS and Linux.
#[cfg(target_os = "macos")]
#[inline]
pub fn now_ns() -> u64 {
    // Declared here as in cmux-flow-trace and cmux-tui-platform: one clock id, no libc version question.
    const CLOCK_UPTIME_RAW: u32 = 8;
    unsafe extern "C" {
        fn clock_gettime_nsec_np(clock: u32) -> u64;
    }
    // SAFETY: CLOCK_UPTIME_RAW is a valid clock id; the call has no other preconditions.
    unsafe { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }
}

/// Now on the trace clock, in ns. No allocation, lock or kernel entry on macOS and Linux.
#[cfg(all(unix, not(target_os = "macos")))]
#[inline]
pub fn now_ns() -> u64 {
    let mut now = libc::timespec { tv_sec: 0, tv_nsec: 0 };
    // SAFETY: `now` is a valid out pointer for the call.
    unsafe { libc::clock_gettime(libc::CLOCK_MONOTONIC, &mut now) };
    (now.tv_sec as u64).saturating_mul(1_000_000_000).saturating_add(now.tv_nsec as u64)
}

/// Now on the trace clock, in ns: the performance counter, with its frequency read once.
#[cfg(windows)]
#[inline]
pub fn now_ns() -> u64 {
    use std::sync::atomic::{AtomicU64, Ordering};
    unsafe extern "system" {
        fn QueryPerformanceCounter(count: *mut i64) -> i32;
        fn QueryPerformanceFrequency(frequency: *mut i64) -> i32;
    }
    static FREQUENCY: AtomicU64 = AtomicU64::new(0);
    let mut frequency = FREQUENCY.load(Ordering::Relaxed);
    if frequency == 0 {
        let mut read = 0i64;
        // SAFETY: a valid out pointer; the call cannot fail on Windows XP and later.
        unsafe { QueryPerformanceFrequency(&mut read) };
        frequency = read.unsigned_abs().max(1);
        FREQUENCY.store(frequency, Ordering::Relaxed);
    }
    let mut count = 0i64;
    // SAFETY: a valid out pointer; the call cannot fail on Windows XP and later.
    unsafe { QueryPerformanceCounter(&mut count) };
    let ns = u128::from(count.unsigned_abs()) * 1_000_000_000 / u128::from(frequency);
    u64::try_from(ns).unwrap_or(u64::MAX)
}

/// The id of the current boot (macOS `kern.bootsessionuuid`, Linux `/proc/sys/kernel/random/boot_id`),
/// as 16 bytes; zeros when the platform has none. Two rings compare `t_ns` only within one boot.
/// It reads a sysctl or a file: call it off any hot path (the ring-open thread does).
pub fn boot_session() -> [u8; 16] {
    boot_session_text().as_deref().and_then(parse_uuid).unwrap_or([0; 16])
}

#[cfg(target_os = "macos")]
fn boot_session_text() -> Option<String> {
    let mut buffer = [0u8; 64];
    let mut len = buffer.len();
    // SAFETY: the name is NUL-terminated, `buffer` holds `len` bytes, and no new value is set.
    let status = unsafe {
        libc::sysctlbyname(
            c"kern.bootsessionuuid".as_ptr(),
            buffer.as_mut_ptr().cast(),
            &mut len,
            std::ptr::null_mut(),
            0,
        )
    };
    if status != 0 {
        return None;
    }
    let text = &buffer[..len.min(buffer.len())];
    let end = text.iter().position(|&byte| byte == 0).unwrap_or(text.len());
    std::str::from_utf8(&text[..end]).ok().map(str::to_owned)
}

#[cfg(target_os = "linux")]
fn boot_session_text() -> Option<String> {
    std::fs::read_to_string("/proc/sys/kernel/random/boot_id").ok()
}

#[cfg(not(any(target_os = "macos", target_os = "linux")))]
fn boot_session_text() -> Option<String> {
    None
}

/// The 16 bytes of a textual UUID (`8-4-4-4-12` hex, any case, surrounding space ignored).
pub(crate) fn parse_uuid(text: &str) -> Option<[u8; 16]> {
    let mut out = [0u8; 16];
    let mut digits = text.trim().bytes().filter(|&byte| byte != b'-');
    for byte in &mut out {
        let high = (digits.next()? as char).to_digit(16)?;
        let low = (digits.next()? as char).to_digit(16)?;
        *byte = (high << 4 | low) as u8;
    }
    digits.next().is_none().then_some(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_clock_moves_forward() {
        let first = now_ns();
        let second = now_ns();
        assert!(first > 0 && second >= first);
    }

    #[test]
    fn a_uuid_parses_to_its_bytes() {
        let bytes = parse_uuid("0011223344-55-6677-8899-AABBCCDDEEFF\n").expect("parses");
        assert_eq!(bytes[0], 0x00);
        assert_eq!(bytes[5], 0x55);
        assert_eq!(bytes[15], 0xff);
        assert_eq!(parse_uuid("00112233"), None);
        assert_eq!(parse_uuid("zz112233-4455-6677-8899-aabbccddeeff"), None);
        assert_eq!(parse_uuid("00112233-4455-6677-8899-aabbccddeeff00"), None);
    }

    #[test]
    fn the_current_domain_matches_the_platform() {
        assert_eq!(ClockDomain::from_raw(ClockDomain::CURRENT as u8), Some(ClockDomain::CURRENT));
        assert_eq!(ClockDomain::from_raw(0), None);
    }
}
