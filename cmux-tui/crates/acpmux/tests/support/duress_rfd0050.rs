//! The `rfd0050` leg: RFD 0050 rule 7's drill (cmuxterm-hq docs/rfd/0050-aliveness-under-duress.md).
//!
//! Rule 7, verbatim: "A drill runs `acpmux ls`, `send`, `daemon status` and the app's remote tmux
//! reads with the machine held at 90% CPU and RAM and the broker shimmed to answer in 100 s, and
//! reports p50 and p99 per command." This leg is that machine:
//!
//! - CPU: busy loops on 90% of the cores (rounded up), and the share of the window the host's
//!   CPUs were actually busy (`/proc/stat`) recorded beside it as `cpuBusyPct`;
//! - RAM: a hog sized so the host's used memory (`MemTotal - MemAvailable`) reaches 90% of
//!   `MemTotal`, never past `MemAvailable` less [`RAM_HEADROOM`] so another job on the host keeps
//!   room; `memUsedPct` at the window's start and end says what was reached;
//! - the broker: the mesh hub stub answers every request after [`BROKER_SECS`], and the send
//!   relay's listing (`sendRelay.lsArgv`, which plain `acpmux ls` runs) sleeps as long first.
//!
//! Its rows: `ls`, `send` (to a local session), `send-far` (to `HOST/NAME` on a machine no peer
//! is configured for, so the daemon posts it to the 100 s broker) and `status`
//! (`acpmux daemon status`), each through the CLI and the socket. The app's remote tmux rows are
//! not here: the Swift `RemoteTmuxViewConnection` is classic only (frozen) and absent on NEXT.
use super::*;

pub(super) const LEG: &str = "rfd0050";
/// How long the shimmed broker takes to answer.
pub(super) const BROKER_SECS: u64 = 100;
/// The share of CPU and RAM the leg holds.
const HOLD_PCT: u64 = 90;
/// The window at least: long enough that answers held [`BROKER_SECS`] come back inside it.
pub(super) const WINDOW_MIN: Duration = Duration::from_secs(BROKER_SECS + 40);
/// What the RAM hog leaves of `MemAvailable` whatever the target.
const RAM_HEADROOM: u64 = 512 << 20;

pub(super) fn cpu_loops(cores: usize) -> usize {
    (cores * HOLD_PCT as usize).div_ceil(100).max(1)
}

fn meminfo(key: &str) -> Option<u64> {
    let text = std::fs::read_to_string("/proc/meminfo").ok()?;
    let line = text.lines().find(|l| l.starts_with(key) && l[key.len()..].starts_with(':'))?;
    Some(line.split_whitespace().nth(1)?.parse::<u64>().ok()? * 1024)
}

/// Used memory as a percent of `MemTotal`.
pub(super) fn mem_used_pct() -> Option<f64> {
    let (total, avail) = (meminfo("MemTotal")?, meminfo("MemAvailable")?);
    Some(total.saturating_sub(avail) as f64 * 100.0 / total.max(1) as f64)
}

/// The hog's bytes: up to [`HOLD_PCT`] of `MemTotal` used, within `MemAvailable` less headroom.
pub(super) fn hog_bytes() -> Option<u64> {
    let (total, avail) = (meminfo("MemTotal")?, meminfo("MemAvailable")?);
    let used = total.saturating_sub(avail);
    let want = (total / 100 * HOLD_PCT).saturating_sub(used);
    Some(want.min(avail.saturating_sub(RAM_HEADROOM)))
}

/// Holds `bytes` resident: touched a page at a time, then touched again every 2 s.
pub(super) fn hog_script(bytes: u64) -> String {
    format!(
        "exec python3 -c 'import time\nchunks=[]\nleft={bytes}\nwhile left>0:\n n=min(left,64<<20)\n \
         b=bytearray(n)\n b[::4096]=b\"\\x01\"*len(range(0,n,4096))\n chunks.append(b)\n left-=n\n\
         while True:\n time.sleep(2)\n for b in chunks:\n  b[::4096]=b\"\\x02\"*len(range(0,len(b),4096))\n'"
    )
}

/// `(busy, total)` jiffies of all CPUs from `/proc/stat`.
pub(super) fn cpu_jiffies() -> Option<(u64, u64)> {
    let text = std::fs::read_to_string("/proc/stat").ok()?;
    let v: Vec<u64> =
        text.lines().next()?.split_whitespace().skip(1).filter_map(|x| x.parse().ok()).collect();
    let total: u64 = v.iter().take(8).sum();
    let idle = v.get(3).copied().unwrap_or(0) + v.get(4).copied().unwrap_or(0);
    Some((total - idle, total))
}

/// Busy percent between two [`cpu_jiffies`] readings.
pub(super) fn busy_pct(a: Option<(u64, u64)>, b: Option<(u64, u64)>) -> Option<f64> {
    let ((b0, t0), (b1, t1)) = (a?, b?);
    (t1 > t0).then(|| (b1 - b0) as f64 * 100.0 / (t1 - t0) as f64)
}

/// The relay listing stub: answers an empty listing after [`BROKER_SECS`].
pub(super) fn relay_ls_body() -> String {
    format!("#!/bin/sh\nsleep {BROKER_SECS}\necho '{{\"sessions\":[]}}'\n")
}

#[cfg(test)]
#[path = "duress_rfd0050_tests.rs"]
mod tests;
