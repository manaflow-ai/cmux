//! A peer link that dropped for silence on a kept circuit (the pair matrix's 5G/LTE `handoff`
//! cell over the relay) leaves that circuit open by its own keepalive (two 30 s periods). Its
//! redial used to OPEN on it, wait [`mux::ANSWER_SUSPECT`] (3 s) for an answer, and only then
//! dial the fresh circuit (about 0.4 s). `HubCarrier::close_kept_silent_for` closes a circuit
//! the dropped link proved dead, so the redial dials the fresh one at once.

use super::*;

/// Every Connect ask is refused at once: a fresh circuit's dial ends at its ticket, so the
/// test times only what the redial spent before it asked for one.
struct NoConnect {
    asked: AtomicU64,
}

#[async_trait]
impl Tickets for NoConnect {
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

/// A circuit whose far end is gone: sends go nowhere, nothing ever comes back.
struct Gone;

#[async_trait]
impl FrameLink for Gone {
    fn description(&self) -> &str {
        "gone"
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

/// A kept dialer circuit to `daemon` on `lane` that last heard a record `ago`.
async fn kept(
    carrier: &HubCarrier,
    daemon: &str,
    lane: CircuitLane,
    ago: Duration,
) -> Arc<mux::Mux> {
    let (circuit, _said) = mux::start_dialer(
        Box::new(Gone),
        carrier.stats.clone(),
        Arc::downgrade(&carrier.alive),
        Duration::from_secs(30),
        Duration::from_secs(300),
    );
    circuit.heard_at(Instant::now().checked_sub(ago).unwrap_or_else(Instant::now));
    carrier.kept.slot(daemon, lane).lock().await.live = Some(circuit.clone());
    circuit
}

/// The link heard nothing for its 6 s silence budget and neither did the cheap circuit it rode:
/// the redial asks for a fresh circuit at once, not after `ANSWER_SUSPECT` on the dead one. The
/// bulk circuit heard a record 1 s ago (another stream's bytes): it is alive and stays.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_redial_after_a_silent_link_drop_does_not_wait_on_the_dead_kept_circuit() {
    let tickets = Arc::new(NoConnect { asked: AtomicU64::new(0) });
    let carrier = HubCarrier::new(tickets.clone(), [7u8; 32], Timings::default());
    let daemon = "machine-b";
    let dead = kept(&carrier, daemon, CircuitLane::Cheap, Duration::from_secs(7)).await;
    let alive = kept(&carrier, daemon, CircuitLane::Bulk, Duration::from_secs(1)).await;

    // What `Peer::connect_once` does when its hub link drops after 6 s of silence.
    let closed = carrier.close_kept_silent_for(daemon, Duration::from_secs(6)).await;

    let started = Instant::now();
    let mut report = DialReport::default();
    let redial = carrier
        .kept_open(
            daemon,
            CircuitLane::Cheap,
            hello_record(CircuitService::Acpmux),
            &mut report,
            Path::Relay,
        )
        .await;
    let took = started.elapsed();
    assert!(
        took < mux::ANSWER_SUSPECT,
        "the redial waited {took:?} on a kept circuit its dropped link proved dead"
    );
    assert!(matches!(redial, KeptOpen::Failed(_)), "the redial asked for a fresh circuit");
    assert_eq!(tickets.asked.load(Ordering::SeqCst), 1, "one fresh circuit asked for");
    assert_eq!(closed, 1);
    assert!(dead.is_closed());
    assert!(!alive.is_closed(), "a circuit that heard a record in the window is alive");

    // Silence shorter than `ANSWER_SUSPECT` proves no more than an OPEN would: nothing closes.
    let quiet = kept(&carrier, daemon, CircuitLane::Cheap, Duration::from_secs(2)).await;
    assert_eq!(carrier.close_kept_silent_for(daemon, Duration::from_secs(2)).await, 0);
    assert!(!quiet.is_closed());
}
