//! The pool's idle exit on the injected clock, and the process helpers it
//! and the RSS cap use.

use super::policy::Pool;
use crate::agent_host::HostRecord;
use crate::clock::Clock;
use std::future::Future;
use std::sync::{Arc, Mutex as StdMutex};
use tokio::sync::Notify;

/// `killpg` on the harness group of a pooled host (park and resume).
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

/// End idle entries at their deadline. Waits only on `clock`, the pool's
/// wake signal and `stopped`, so an idle pool costs no CPU; returns when
/// `stopped` resolves or `clock` reports the owner gone (None).
pub(crate) async fn run_reaper<T>(
    pool: &StdMutex<Pool<T>>,
    wake: &Notify,
    stopped: impl Future<Output = ()>,
    mut clock: impl FnMut() -> Option<Arc<dyn Clock>>,
    mut expired: impl FnMut(Vec<T>),
) {
    tokio::pin!(stopped);
    loop {
        let Some(clock) = clock() else { return };
        let next = super::lock(pool).next_deadline();
        let woke = async {
            match next {
                Some(at) => {
                    tokio::select! {
                        _ = clock.sleep_until(at) => {}
                        _ = wake.notified() => {}
                    }
                }
                None => wake.notified().await,
            }
        };
        tokio::select! {
            _ = &mut stopped => return,
            _ = woke => {}
        }
        let out = super::lock(pool).expire(clock.now());
        if !out.is_empty() {
            expired(out);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::super::policy::{Origin, PoolKey, Role};
    use super::*;
    use crate::clock::ManualClock;
    use std::time::Duration;
    use tokio::sync::{mpsc, oneshot};

    fn key(h: &str) -> PoolKey {
        PoolKey {
            origin: Origin::Local,
            cwd: "/w".into(),
            harness: h.into(),
            preset: None,
            args: vec![],
            system_prompt_sha256: None,
            auth: "a".into(),
            account: None,
        }
    }

    /// Lets every task that can run, run.
    async fn settle() {
        for _ in 0..20 {
            tokio::task::yield_now().await;
        }
    }

    #[tokio::test]
    async fn an_idle_entry_exits_on_the_fake_clock_and_a_hint_moves_its_deadline() {
        let pool = Arc::new(StdMutex::new(Pool::<&'static str>::new(Duration::from_secs(600))));
        let wake = Arc::new(Notify::new());
        let clock = ManualClock::new();
        let (stop_tx, stop_rx) = oneshot::channel::<()>();
        let (out_tx, mut out_rx) = mpsc::unbounded_channel();
        {
            let mut p = pool.lock().unwrap();
            let g = p.want(Role::Hinted, key("codex"), Duration::ZERO).start.unwrap();
            assert!(p.complete(&key("codex"), g, "codex#1", Duration::ZERO).is_none());
        }
        let (pool2, wake2, clock2) = (pool.clone(), wake.clone(), clock.clone());
        let reaper = tokio::spawn(async move {
            run_reaper(
                &pool2,
                &wake2,
                async {
                    let _ = stop_rx.await;
                },
                || Some(clock2.clone() as Arc<dyn Clock>),
                |v| v.into_iter().for_each(|t| out_tx.send(t).unwrap()),
            )
            .await;
        });
        settle().await;
        clock.advance(Duration::from_secs(599));
        settle().await;
        assert!(out_rx.try_recv().is_err(), "not idle long enough");
        // A hint at 599 s moves the deadline to 1199 s.
        pool.lock().unwrap().want(Role::Hinted, key("codex"), Duration::from_secs(599));
        wake.notify_one();
        settle().await;
        clock.advance(Duration::from_secs(1));
        settle().await;
        assert!(out_rx.try_recv().is_err(), "the hint pushed the deadline");
        clock.advance(Duration::from_secs(599));
        settle().await;
        assert_eq!(out_rx.try_recv().ok(), Some("codex#1"));
        assert!(pool.lock().unwrap().is_empty());
        // The reaper stops when told to (hub.shutdown or stop_pool).
        stop_tx.send(()).unwrap();
        tokio::time::timeout(Duration::from_secs(5), reaper).await.unwrap().unwrap();
    }

    #[test]
    fn tree_rss_counts_this_process() {
        assert!(tree_rss_bytes(std::process::id()) > 0);
    }
}
