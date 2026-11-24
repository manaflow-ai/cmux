//! Whether this machine is overloaded, for the app's dismissible warning.
//!
//! Lucas Ribeiro's Mac, 2026-11-23: load average 267-320 on 15 cores, swap 21.3 of 22.5 GB used,
//! and nothing in the app said so. [`evaluate`] is the whole decision, pure so the thresholds are
//! tested: over when the 1-minute load average is above [`LOAD_PER_CORE`] times the cores, or swap
//! used is above [`SWAP_FRACTION`] of the swap total. [`current`] reads the host at most once per
//! [`SAMPLE_EVERY`] whoever asks and however often, so the cost is constant. The webview polls
//! `_acpmux/host_overload` and only draws the numbers it gets.
//!
//! `ACPMUX_FAKE_HOST_OVERLOAD=LOAD,CORES,SWAP_PERCENT` stands in for the readings (DEV tryouts
//! and screenshots), e.g. `290,15,95`.

use serde_json::{Value, json};
use std::sync::Mutex;
use std::time::{Duration, Instant};

/// Over when the 1-minute load average exceeds this many times the cores.
pub const LOAD_PER_CORE: f64 = 5.0;
/// Over when swap used exceeds this fraction of the swap total.
pub const SWAP_FRACTION: f64 = 0.8;
/// How long a reading is reused.
pub const SAMPLE_EVERY: Duration = Duration::from_secs(15);

/// One reading and its verdict.
#[derive(Debug, Clone, PartialEq)]
pub struct Overload {
    pub load1: Option<f64>,
    pub cores: u32,
    pub swap_used: Option<u64>,
    pub swap_total: Option<u64>,
    pub load_over: bool,
    pub swap_over: bool,
}

impl Overload {
    pub fn overloaded(&self) -> bool {
        self.load_over || self.swap_over
    }

    /// Swap used as a percentage of its total; none without swap.
    pub fn swap_percent(&self) -> Option<u32> {
        let (used, total) = (self.swap_used?, self.swap_total.filter(|t| *t > 0)?);
        Some((used as f64 / total as f64 * 100.0).round() as u32)
    }

    /// The state the webview draws.
    pub fn to_json(&self) -> Value {
        json!({
            "overloaded": self.overloaded(),
            "load1": self.load1.map(|l| l.round()),
            "cores": self.cores,
            "swapPercent": self.swap_percent(),
            "swapUsedBytes": self.swap_used,
            "swapTotalBytes": self.swap_total,
            "loadOver": self.load_over,
            "swapOver": self.swap_over,
        })
    }
}

/// The verdict for one reading (module docs). Missing readings are never over.
pub fn evaluate(
    load1: Option<f64>,
    cores: u32,
    swap_used: Option<u64>,
    swap_total: Option<u64>,
) -> Overload {
    let load_over = load1.is_some_and(|l| l > f64::from(cores.max(1)) * LOAD_PER_CORE);
    let swap_over = match (swap_used, swap_total) {
        (Some(used), Some(total)) if total > 0 => used as f64 > total as f64 * SWAP_FRACTION,
        _ => false,
    };
    Overload { load1, cores, swap_used, swap_total, load_over, swap_over }
}

/// `LOAD,CORES,SWAP_PERCENT` as the fake reading's verdict.
pub fn parse_fake(text: &str) -> Option<Overload> {
    let mut parts = text.split(',').map(str::trim);
    let load: f64 = parts.next()?.parse().ok()?;
    let cores: u32 = parts.next()?.parse().ok()?;
    let pct: f64 = parts.next()?.parse().ok()?;
    let total: u64 = 24 << 30;
    Some(evaluate(Some(load), cores, Some((total as f64 * pct / 100.0) as u64), Some(total)))
}

fn read_host() -> Overload {
    if let Some(fake) = std::env::var("ACPMUX_FAKE_HOST_OVERLOAD").ok().and_then(|v| parse_fake(&v))
    {
        return fake;
    }
    let cores = std::thread::available_parallelism().map_or(1, |n| n.get() as u32);
    let load1 = crate::server::peer_status::load().map(|l| l[0]);
    let swap = crate::server::peer_status::swap();
    evaluate(load1, cores, swap.map(|s| s.0), swap.map(|s| s.1))
}

/// The host's reading, reused for [`SAMPLE_EVERY`]: a few syscalls at most once per period.
pub fn current() -> Overload {
    static CACHE: Mutex<Option<(Instant, Overload)>> = Mutex::new(None);
    let mut cache = CACHE.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    if let Some((at, v)) = cache.as_ref()
        && at.elapsed() < SAMPLE_EVERY
    {
        return v.clone();
    }
    let v = read_host();
    *cache = Some((Instant::now(), v.clone()));
    v
}

#[cfg(test)]
mod tests {
    use super::*;

    const GB: u64 = 1 << 30;

    #[test]
    fn lucas_machine_is_overloaded_on_both_counts() {
        let v = evaluate(Some(290.0), 15, Some(21_300 * (GB / 1000)), Some(22_500 * (GB / 1000)));
        assert!(v.load_over && v.swap_over && v.overloaded());
        assert_eq!(v.swap_percent(), Some(95));
        assert_eq!(v.to_json()["load1"], json!(290.0));
    }

    #[test]
    fn load_threshold_is_five_per_core_exclusive() {
        assert!(!evaluate(Some(75.0), 15, None, None).overloaded());
        assert!(evaluate(Some(75.1), 15, None, None).load_over);
        assert!(!evaluate(Some(40.0), 8, None, None).overloaded());
        assert!(evaluate(Some(41.0), 8, None, None).overloaded());
    }

    #[test]
    fn swap_threshold_is_eighty_percent_exclusive() {
        assert!(!evaluate(None, 8, Some(80), Some(100)).overloaded());
        assert!(evaluate(None, 8, Some(81), Some(100)).swap_over);
        assert!(!evaluate(None, 8, Some(5), Some(0)).overloaded(), "no swap is not full swap");
    }

    #[test]
    fn missing_readings_are_never_over() {
        assert!(!evaluate(None, 0, None, None).overloaded());
        assert_eq!(evaluate(None, 4, None, None).swap_percent(), None);
    }

    #[test]
    fn the_fake_reading_parses() {
        let v = parse_fake("290, 15, 95").unwrap();
        assert!(v.overloaded());
        assert_eq!(v.cores, 15);
        assert_eq!(v.swap_percent(), Some(95));
        assert!(parse_fake("290,15").is_none());
        assert!(!parse_fake("2,15,10").unwrap().overloaded());
    }
}
