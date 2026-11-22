//! Wall-clock conversion in the machine's local zone or UTC.
//!
//! Local time goes through the C library (`localtime_r`, `mktime`; the CRT's
//! `_localtime64_s`, `_mktime64` on Windows), so daylight saving follows the
//! OS's own zone database. Named IANA zones run
//! on cmux Cloud (SchedulerDO); a local runner keeps to the zone the Mac is
//! in, as Claude Code Desktop does.

use std::sync::Once;

/// The zone a schedule is evaluated in on this machine.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Zone {
    /// The machine's zone (`/etc/localtime`, or `TZ`).
    Local,
    /// Coordinated Universal Time.
    Utc,
}

/// A wall-clock minute.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Civil {
    pub year: i32,
    /// 1 to 12.
    pub month: u32,
    /// 1 to 31.
    pub day: u32,
    /// 0 to 23.
    pub hour: u32,
    /// 0 to 59.
    pub minute: u32,
    /// 0 (Sunday) to 6.
    pub weekday: u32,
}

impl Civil {
    /// Same wall-clock minute (weekday aside).
    pub fn same_minute(&self, other: &Civil) -> bool {
        (self.year, self.month, self.day, self.hour, self.minute)
            == (other.year, other.month, other.day, other.hour, other.minute)
    }
}

#[cfg(unix)]
unsafe extern "C" {
    fn tzset();
}

// The CRT's 64-bit `mktime` and `timegm` (libc declares neither for Windows).
#[cfg(windows)]
unsafe extern "C" {
    #[link_name = "_mktime64"]
    fn mktime64(tm: *mut libc::tm) -> i64;
    #[link_name = "_mkgmtime64"]
    fn mkgmtime64(tm: *mut libc::tm) -> i64;
}

static TZSET: Once = Once::new();

/// Read the zone settings (`TZ`, the system zone) once, before the first
/// local conversion.
fn tzset_once() {
    // SAFETY: tzset takes no arguments; `Once` runs it a single time.
    #[cfg(unix)]
    TZSET.call_once(|| unsafe { tzset() });
    // SAFETY: as above (libc links it to the CRT's `_tzset`).
    #[cfg(windows)]
    TZSET.call_once(|| unsafe { libc::tzset() });
}

/// `t` broken down in `zone` (both calls only write into `tm`).
#[cfg(unix)]
fn break_down(zone: Zone, t: i64, tm: &mut libc::tm) {
    let time = t as libc::time_t;
    match zone {
        Zone::Local => {
            tzset_once();
            // SAFETY: `time` and `tm` are valid for the call.
            unsafe { libc::localtime_r(&time, tm) };
        }
        // SAFETY: as above.
        Zone::Utc => unsafe {
            libc::gmtime_r(&time, tm);
        },
    }
}

/// `t` broken down in `zone` (both calls only write into `tm`).
#[cfg(windows)]
fn break_down(zone: Zone, t: i64, tm: &mut libc::tm) {
    let time = t as libc::time_t;
    match zone {
        Zone::Local => {
            tzset_once();
            // SAFETY: `time` and `tm` are valid for the call.
            unsafe { libc::localtime_s(tm, &time) };
        }
        // SAFETY: as above.
        Zone::Utc => unsafe {
            libc::gmtime_s(tm, &time);
        },
    }
}

/// Seconds since the epoch of `tm` in `zone`; out-of-range fields carry over.
#[cfg(unix)]
fn seconds_of(zone: Zone, tm: &mut libc::tm) -> i64 {
    match zone {
        Zone::Local => {
            tzset_once();
            // SAFETY: `tm` is valid; mktime normalizes it in place.
            (unsafe { libc::mktime(tm) }) as i64
        }
        // SAFETY: as above.
        Zone::Utc => (unsafe { libc::timegm(tm) }) as i64,
    }
}

/// Seconds since the epoch of `tm` in `zone`; out-of-range fields carry over.
#[cfg(windows)]
fn seconds_of(zone: Zone, tm: &mut libc::tm) -> i64 {
    match zone {
        Zone::Local => {
            tzset_once();
            // SAFETY: `tm` is valid; _mktime64 normalizes it in place.
            unsafe { mktime64(tm) }
        }
        // SAFETY: as above.
        Zone::Utc => unsafe { mkgmtime64(tm) },
    }
}

impl Zone {
    /// `local` (also empty) or `UTC`; any other name is refused with the reason.
    pub fn parse(name: &str) -> Result<Zone, String> {
        match name.trim() {
            "" | "local" | "Local" => Ok(Zone::Local),
            "UTC" | "utc" | "Etc/UTC" | "Z" => Ok(Zone::Utc),
            other => Err(format!(
                "time zone \"{other}\": a schedule on this machine runs in its local zone or UTC; named zones run on cmux Cloud"
            )),
        }
    }

    /// The stored name.
    pub fn name(self) -> &'static str {
        match self {
            Zone::Local => "local",
            Zone::Utc => "UTC",
        }
    }

    /// The wall-clock minute at `t` (seconds since the epoch).
    pub fn civil(self, t: i64) -> Civil {
        // SAFETY: `tm` is plain data; all zeros is a valid value.
        let mut tm: libc::tm = unsafe { std::mem::zeroed() };
        break_down(self, t, &mut tm);
        Civil {
            year: tm.tm_year + 1900,
            month: (tm.tm_mon + 1) as u32,
            day: tm.tm_mday as u32,
            hour: tm.tm_hour as u32,
            minute: tm.tm_min as u32,
            weekday: tm.tm_wday as u32,
        }
    }

    /// Seconds since the epoch of a wall-clock time. Out-of-range fields
    /// carry over (month 13 is January of the next year, day 32 the 1st or
    /// 2nd of the next month). A local time inside a spring-forward gap
    /// lands after the gap.
    pub fn timestamp(self, year: i32, month: i64, day: i64, hour: i64, minute: i64) -> i64 {
        // SAFETY: as above.
        let mut tm: libc::tm = unsafe { std::mem::zeroed() };
        tm.tm_year = year - 1900;
        tm.tm_mon = (month - 1) as libc::c_int;
        tm.tm_mday = day as libc::c_int;
        tm.tm_hour = hour as libc::c_int;
        tm.tm_min = minute as libc::c_int;
        tm.tm_sec = 0;
        tm.tm_isdst = -1;
        seconds_of(self, &mut tm)
    }
}
