//! The pool's idle exit on the injected clock, and the process helpers it
//! and the RSS cap use.

use super::policy::Pool;
use crate::agent_host::HostRecord;
use crate::clock::Clock;
use std::future::Future;
use std::sync::{Arc, Mutex as StdMutex};
use std::time::Duration;
use tokio::sync::Notify;

/// `killpg` on the harness group of a pooled host (park and resume).
#[cfg(unix)]
pub(super) fn signal_harness(record: &HostRecord, signal: i32) {
    if let Some(pid) = record.harness_pid.and_then(|p| i32::try_from(p).ok()) {
        // SAFETY: the harness leads its own process group under its host.
        unsafe { libc::killpg(pid, signal) };
    }
}

/// Resident memory of `root` and every descendant, in bytes (one `ps`).
pub fn tree_rss_bytes(root: u32) -> u64 {
    let Ok(out) = std::process::Command::new("ps").args(["-A", "-o", "pid=,ppid=,rss="]).output()
    else {
        return 0;
    };
    let rows: Vec<(u32, u32, u64)> = String::from_utf8_lossy(&out.stdout)
        .lines()
        .filter_map(|l| {
            let mut f = l.split_whitespace().map(|x| x.parse::<u64>().ok());
            Some((f.next()?? as u32, f.next()?? as u32, f.next()??))
        })
        .collect();
    let mut tree = vec![root];
    let mut i = 0;
    while i < tree.len() {
        let parent = tree[i];
        tree.extend(rows.iter().filter(|r| r.1 == parent && r.0 != parent).map(|r| r.0));
        i += 1;
    }
    rows.iter().filter(|r| tree.contains(&r.0)).map(|r| r.2 * 1024).sum()
}

/// End idle entries at their deadline, and call `on_tick` every `tick`
/// (the RSS re-check). Waits only on `clock`, the pool's wake signal and
/// `stopped`, so an idle pool costs no CPU; returns when the pool is empty
/// (no timer runs for an empty pool), when `stopped` resolves, or when
/// `clock` reports the owner gone (None).
pub(crate) async fn run_reaper<T>(
    pool: &StdMutex<Pool<T>>,
    wake: &Notify,
    stopped: impl Future<Output = ()>,
    mut clock: impl FnMut() -> Option<Arc<dyn Clock>>,
    mut expired: impl FnMut(Vec<T>),
    tick: Duration,
    mut on_tick: impl FnMut(),
) {
    tokio::pin!(stopped);
    let mut next_tick: Option<Duration> = None;
    loop {
        if super::lock(pool).is_empty() {
            return;
        }
        let Some(clock) = clock() else { return };
        let tick_at = *next_tick.get_or_insert_with(|| clock.now() + tick);
        let next = super::lock(pool).next_deadline().map_or(tick_at, |d| d.min(tick_at));
        let woke = async {
            tokio::select! {
                _ = clock.sleep_until(next) => {}
                _ = wake.notified() => {}
            }
        };
        tokio::select! {
            _ = &mut stopped => return,
            _ = woke => {}
        }
        let now = clock.now();
        let out = super::lock(pool).expire(now);
        if !out.is_empty() {
            expired(out);
        }
        if now >= tick_at {
            on_tick();
            next_tick = Some(now + tick);
        }
    }
}
