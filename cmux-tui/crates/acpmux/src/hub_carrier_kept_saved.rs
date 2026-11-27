//! Kept circuits that outlive a restart of this daemon (Leo, 2026-11-25: "small, chatty calls
//! stay on whichever machine holds the files, batched over one always-open connection, never a
//! new connection per call").
//!
//! A kept circuit lived only in the carrier's memory, so every restart of the dialing daemon (an
//! update lands one every few minutes on a busy day) emptied them all, and the next call to each
//! machine paid a whole new circuit again: ticket, relay, peer join, Noise and the `mux` hello,
//! 0.6 s at the median against a kept stream's 0.08 s. [`HubCarrier::keep_reopening`] already opens
//! again a kept circuit that ended under a live carrier; this does the same across this daemon's
//! own restart. Every few seconds the carrier writes down which machines it keeps a circuit to
//! (machine, lane, path, last stream) in the state dir, and a carrier that starts opens each one
//! again in the background, so the first call after a restart rides a circuit already open.
//! A circuit that would have idled out (`kept_idle`) by now is not opened again.

use std::sync::Arc;
use std::sync::atomic::Ordering;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};

use super::{CircuitLane, HubCarrier, Path, mux};

/// The file in the daemon's state dir.
pub(crate) const FILE: &str = "hub-kept-circuits.json";
/// How often the carrier looks for a change in its kept circuits to write down.
const SAVE_SCAN: Duration = Duration::from_secs(5);
/// The longest a written last-stream time goes stale while the set itself does not change.
const SAVE_AGAIN: Duration = Duration::from_secs(60);

/// One kept circuit, as written down.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct Saved {
    pub(crate) daemon: String,
    /// `cheap` or `bulk`.
    pub(crate) lane: String,
    /// `relay`, `punched`, or the direct path's `address:port`.
    pub(crate) path: String,
    /// Unix seconds of the circuit's last stream.
    pub(crate) used_at: u64,
}

impl Saved {
    fn key(&self) -> (&str, &str, &str) {
        (&self.daemon, &self.lane, &self.path)
    }

    fn lane(&self) -> Option<CircuitLane> {
        match self.lane.as_str() {
            "cheap" => Some(CircuitLane::Cheap),
            "bulk" => Some(CircuitLane::Bulk),
            _ => None,
        }
    }

    fn path(&self) -> Option<Path> {
        match self.path.as_str() {
            "relay" => Some(Path::Relay),
            "punched" => Some(Path::Punched),
            address => address.parse().ok().map(Path::Direct),
        }
    }
}

fn lane_name(lane: CircuitLane) -> &'static str {
    match lane {
        CircuitLane::Cheap => "cheap",
        CircuitLane::Bulk => "bulk",
    }
}

fn path_name(path: Path) -> String {
    match path {
        Path::Relay => "relay".into(),
        Path::Punched => "punched".into(),
        Path::Iroh => "iroh".into(),
        Path::Direct(address) => address.to_string(),
    }
}

fn unix_now() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |since| since.as_secs())
}

/// Open again the circuits `home` kept before this daemon started, then write down the
/// carrier's kept circuits as they change, until the carrier ends.
pub(crate) fn keep_across_restarts(carrier: &Arc<HubCarrier>, home: &std::path::Path) {
    let file = home.join(FILE);
    let carrier = Arc::downgrade(carrier);
    mux::spawn_reopening(async move {
        let before = read(&file);
        {
            let Some(carrier) = carrier.upgrade() else { return };
            let opened = carrier.reopen_saved(&before).await;
            if !before.is_empty() {
                tracing::info!(
                    opened,
                    of = before.len(),
                    "hub carrier: opened the kept circuits from before this restart"
                );
            }
        }
        let mut written: Option<(Vec<Saved>, Instant)> = None;
        loop {
            tokio::time::sleep(SAVE_SCAN).await;
            let Some(carrier) = carrier.upgrade() else { return };
            let now = carrier.saved_now();
            let same = written.as_ref().is_some_and(|(then, at)| {
                at.elapsed() < SAVE_AGAIN
                    && then.iter().map(Saved::key).eq(now.iter().map(Saved::key))
            });
            if same {
                continue;
            }
            match serde_json::to_vec(&now) {
                Ok(bytes) => crate::config::write_atomic_later(&file, bytes),
                Err(e) => tracing::debug!("hub carrier: kept circuits not written: {e}"),
            }
            written = Some((now, Instant::now()));
        }
    });
}

/// The circuits written to `file`; none when it is missing or unreadable.
pub(crate) fn read(file: &std::path::Path) -> Vec<Saved> {
    std::fs::read(file)
        .ok()
        .and_then(|bytes| serde_json::from_slice(&bytes).ok())
        .unwrap_or_default()
}

impl HubCarrier {
    /// Every kept circuit open now that has not idled out, sorted so an unchanged set compares
    /// equal.
    pub(crate) fn saved_now(&self) -> Vec<Saved> {
        let now = unix_now();
        let mut saved: Vec<Saved> = self
            .kept
            .kept_now()
            .into_iter()
            .chain(self.direct.kept.kept_now())
            .filter(|(_, _, _, quiet)| *quiet < self.timings.kept_idle)
            .map(|(daemon, lane, path, quiet)| Saved {
                daemon,
                lane: lane_name(lane).into(),
                path: path_name(path),
                used_at: now.saturating_sub(quiet.as_secs()),
            })
            .collect();
        saved.sort_by(|a, b| a.key().cmp(&b.key()));
        saved
    }

    /// Open again, all at once, each of `saved` that would not have idled out by now; the
    /// number that opened.
    pub(crate) async fn reopen_saved(&self, saved: &[Saved]) -> usize {
        let now = unix_now();
        let idle = self.timings.kept_idle.as_secs();
        let opens = saved
            .iter()
            .filter(|one| now.saturating_sub(one.used_at) < idle)
            .filter_map(|one| Some(self.open_saved(&one.daemon, one.lane()?, one.path()?)));
        futures::future::join_all(opens).await.into_iter().filter(|opened| *opened).count()
    }

    /// One kept circuit from before the restart, in its slot as a dial would leave it. A dial
    /// to the machine meanwhile waits on this open rather than racing it; a slot a dial already
    /// filled is left alone.
    async fn open_saved(&self, daemon: &str, lane: CircuitLane, path: Path) -> bool {
        let slot = match path {
            Path::Relay => self.kept.slot(daemon, lane),
            Path::Direct(_) | Path::Punched => self.direct.kept.slot(daemon, lane),
            Path::Iroh => self.iroh.kept.slot(daemon, lane),
        };
        let mut kept = slot.lock().await;
        if kept.live.as_ref().is_some_and(|mux| !mux.is_closed()) {
            return false;
        }
        let why = match self.open_kept(daemon, lane, path).await {
            Ok((mux, said, _)) => match tokio::time::timeout(self.timings.handshake, said).await {
                Ok(Ok(Ok(()))) => {
                    self.stats.kept_circuits.fetch_add(1, Ordering::Relaxed);
                    kept.live = Some(mux);
                    kept.path = Some(path);
                    kept.reopen_at = None;
                    kept.reopen_wait = Duration::ZERO;
                    return true;
                }
                Ok(Ok(Err(refusal))) => {
                    mux.close().await;
                    kept.no_mux_until = Some(Instant::now() + mux::NO_MUX_ASK_AGAIN);
                    refusal.to_string()
                }
                Ok(Err(_)) | Err(_) => {
                    mux.close().await;
                    mux.ended().unwrap_or_else(|| "no answer to the `mux` hello".into())
                }
            },
            Err(e) => e,
        };
        tracing::debug!(
            daemon,
            ?path,
            "hub carrier: a kept circuit from before did not open: {why}"
        );
        false
    }
}

#[cfg(test)]
#[path = "hub_carrier_kept_saved_tests.rs"]
mod tests;
