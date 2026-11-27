//! A restart of the dialing daemon opens again the kept circuits it held, rather than leave the
//! next call to each machine a whole new circuit.

use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant};

use async_trait::async_trait;
use bytes::Bytes;
use cmux_remote::link::FrameLink;

use super::super::{CarrierAnswer, CircuitLane, HubCarrier, Path, Tickets, Timings, mux};
use super::{Saved, read, unix_now};

/// Counts Connect asks and refuses each: a reopen that asked for one tried to open the circuit.
struct Counting {
    asked: AtomicU64,
}

#[async_trait]
impl Tickets for Counting {
    async fn register(&self) -> Result<CarrierAnswer, String> {
        Err("no register here".into())
    }

    async fn connect(&self, _peer: &str) -> Result<CarrierAnswer, String> {
        self.asked.fetch_add(1, Ordering::SeqCst);
        Err("no connect here".into())
    }

    fn shown(&self) -> String {
        "https://hub.example".into()
    }
}

/// A circuit that never answers: it stays open, which is all `saved_now` reads.
struct Quiet;

#[async_trait]
impl FrameLink for Quiet {
    fn description(&self) -> &str {
        "quiet"
    }
    fn maximum_frame_bytes(&self) -> usize {
        65_535
    }
    async fn send(&self, _: Bytes) -> Result<(), cmux_remote::link::LinkError> {
        Ok(())
    }
    async fn receive(&self) -> Result<Option<Bytes>, cmux_remote::link::LinkError> {
        std::future::pending().await
    }
    async fn close(&self) -> Result<(), cmux_remote::link::LinkError> {
        Ok(())
    }
}

fn carrier() -> (Arc<HubCarrier>, Arc<Counting>) {
    let tickets = Arc::new(Counting { asked: AtomicU64::new(0) });
    (HubCarrier::new(tickets.clone(), [7u8; 32], Timings::default()), tickets)
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_restarted_carrier_opens_the_kept_circuits_written_before_it() {
    let (before, _) = carrier();
    let (circuit, _said) = mux::start_dialer(
        Box::new(Quiet),
        before.stats.clone(),
        Arc::downgrade(&before.alive),
        Duration::from_secs(30),
        Duration::from_secs(3600),
    );
    {
        let slot = before.kept.slot("machine-b", CircuitLane::Cheap);
        let mut kept = slot.lock().await;
        kept.live = Some(circuit);
        kept.path = Some(Path::Relay);
    }
    let saved = before.saved_now();
    assert_eq!(saved.len(), 1, "{saved:?}");
    assert_eq!((saved[0].daemon.as_str(), saved[0].lane.as_str()), ("machine-b", "cheap"));
    assert_eq!(saved[0].path, "relay");

    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join(super::FILE);
    std::fs::write(&file, serde_json::to_vec(&saved).unwrap()).unwrap();
    let written = read(&file);
    assert_eq!(written, saved);

    // The restarted carrier asks for that machine's circuit at once, before any dial.
    let (after, tickets) = carrier();
    let started = Instant::now();
    assert_eq!(after.reopen_saved(&written).await, 0, "the ticket was refused");
    assert_eq!(tickets.asked.load(Ordering::SeqCst), 1);
    assert!(started.elapsed() < Duration::from_secs(5));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_circuit_that_would_have_idled_out_is_not_opened_again() {
    let (after, tickets) = carrier();
    let idle = after.timings.kept_idle.as_secs();
    let stale = Saved {
        daemon: "machine-b".into(),
        lane: "cheap".into(),
        path: "relay".into(),
        used_at: unix_now() - idle - 1,
    };
    let unknown = Saved { lane: "fast".into(), used_at: unix_now(), ..stale.clone() };
    assert_eq!(after.reopen_saved(&[stale, unknown]).await, 0);
    assert_eq!(tickets.asked.load(Ordering::SeqCst), 0);
}

#[test]
fn a_direct_path_reads_back_as_written() {
    let saved = Saved {
        daemon: "machine-b".into(),
        lane: "bulk".into(),
        path: "10.0.0.7:4243".into(),
        used_at: 0,
    };
    assert!(matches!(saved.path(), Some(Path::Direct(address)) if address.port() == 4243));
    assert_eq!(saved.lane(), Some(CircuitLane::Bulk));
    assert!(read(std::path::Path::new("/nonexistent/kept.json")).is_empty());
}
