//! A dialer keeps a slot per machine it dialed (`mux::KeptCircuits`). A slot whose circuit closed
//! for good (idled out) used to stay, its closed circuit and that circuit's link with it, for
//! every machine ever dialed: a daemon that brokers for short-lived VMs dials every one ever made. Each
//! reopen pass now drops the slots that hold nothing, so the map is the machines with something
//! kept, however many came and went.

use super::*;
use std::sync::Weak;

struct NoConnect;

#[async_trait]
impl Tickets for NoConnect {
    async fn register(&self) -> Result<CarrierAnswer, String> {
        Err("no register here".into())
    }

    async fn connect(&self, _peer: &str) -> Result<CarrierAnswer, String> {
        Err("no connect here".into())
    }

    fn shown(&self) -> String {
        "https://hub.example".into()
    }
}

/// A circuit that never answers and ends its `receive` when closed, as a real link does (the
/// circuit's reader holds the circuit until then).
#[derive(Default)]
struct Quiet {
    closed: tokio::sync::Notify,
    done: std::sync::atomic::AtomicBool,
}

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
        let closed = self.closed.notified();
        if !self.done.load(std::sync::atomic::Ordering::SeqCst) {
            closed.await;
        }
        Ok(None)
    }
    async fn close(&self) -> Result<(), cmux_remote::link::LinkError> {
        self.done.store(true, std::sync::atomic::Ordering::SeqCst);
        self.closed.notify_waiters();
        Ok(())
    }
}

/// A kept circuit to `daemon` in the carrier's relay slot, its keepalive every `every`. `idle`
/// zero: it idles out (closed for good, never reopened) at its first keepalive tick. `Quiet`
/// never answers a PING, so a circuit meant to stay needs an `every` longer than the test.
async fn keep(
    carrier: &Arc<HubCarrier>,
    daemon: &str,
    every: Duration,
    idle: Duration,
) -> Arc<mux::Mux> {
    let (circuit, _said) = mux::start_dialer(
        Box::new(Quiet::default()),
        carrier.stats.clone(),
        Arc::downgrade(&carrier.alive),
        every,
        idle,
    );
    let slot = carrier.kept.slot(daemon, CircuitLane::Cheap);
    let mut kept = slot.lock().await;
    kept.live = Some(circuit.clone());
    kept.path = Some(Path::Relay);
    circuit
}

async fn closed(circuits: &[Arc<mux::Mux>]) {
    let until = Instant::now() + Duration::from_secs(10);
    while circuits.iter().any(|c| !c.is_closed()) {
        assert!(Instant::now() < until, "idle circuits did not close");
        tokio::time::sleep(Duration::from_millis(5)).await;
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn slots_stay_bounded_by_the_machines_kept_over_a_long_run_of_machines_that_went() {
    let carrier = HubCarrier::new(Arc::new(NoConnect), [7u8; 32], Timings::default());
    // One machine whose circuit is live all along, as a busy peer's is.
    let live = keep(&carrier, "steady", Duration::from_secs(3600), Duration::from_secs(3600)).await;
    const ROUNDS: usize = 200;
    const PER_ROUND: usize = 50;
    let mut gone: Vec<Weak<mux::Mux>> = Vec::new();
    let mut most = 0;
    for round in 0..ROUNDS {
        // A round of lane machines dialed once each, then left: their circuits idle out.
        let mut circuits = Vec::with_capacity(PER_ROUND);
        for n in 0..PER_ROUND {
            circuits.push(
                keep(
                    &carrier,
                    &format!("lane-{round}-{n}"),
                    Duration::from_millis(5),
                    Duration::ZERO,
                )
                .await,
            );
        }
        closed(&circuits).await;
        gone.extend(circuits.iter().map(Arc::downgrade));
        drop(circuits);
        most = most.max(carrier.kept.slots());
        carrier.reopen_closed().await;
        // Only the live machine is left: none of the rounds' slots outlive their pass.
        assert_eq!(carrier.kept.slots(), 1, "round {round}");
    }
    // Before a pass the map held at most one round and the live machine, never all of them.
    assert_eq!(most, PER_ROUND + 1);
    assert!(!live.is_closed());
    assert!(carrier.kept.live_on("steady", CircuitLane::Cheap).is_some());
    // The closed circuits themselves are freed, not only their slots.
    let until = Instant::now() + Duration::from_secs(10);
    while gone.iter().any(|w| w.upgrade().is_some()) {
        assert!(Instant::now() < until, "closed circuits are still held");
        tokio::time::sleep(Duration::from_millis(5)).await;
    }
    assert_eq!(gone.len(), ROUNDS * PER_ROUND);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_slot_with_something_to_keep_stays() {
    let carrier = HubCarrier::new(Arc::new(NoConnect), [7u8; 32], Timings::default());
    let later = Instant::now() + Duration::from_secs(600);
    // Refused acpmux streams a while: the next dial must still go plain.
    carrier.kept.slot("old-build", CircuitLane::Cheap).lock().await.no_acpmux_until = Some(later);
    // Keeps no circuits a while.
    carrier.kept.slot("no-mux", CircuitLane::Cheap).lock().await.no_mux_until = Some(later);
    // Held (`hub_carrier_hold.rs`).
    carrier.kept.slot("held", CircuitLane::Cheap).lock().await.held = true;
    // A dial holds the slot now.
    let dialing = carrier.kept.slot("dialing", CircuitLane::Cheap);
    // A refusal that ran out, and an empty slot: nothing to keep.
    let past = Instant::now() - Duration::from_secs(1);
    carrier.kept.slot("ran-out", CircuitLane::Cheap).lock().await.no_acpmux_until = Some(past);
    carrier.kept.slot("empty", CircuitLane::Bulk);
    assert_eq!(carrier.kept.slots(), 6);
    assert_eq!(carrier.kept.prune(), 2);
    assert_eq!(carrier.kept.slots(), 4);
    drop(dialing);
    assert_eq!(carrier.kept.prune(), 1);
    assert_eq!(carrier.kept.slots(), 3);
}
