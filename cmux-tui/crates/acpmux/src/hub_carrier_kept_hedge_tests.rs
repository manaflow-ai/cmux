//! A dial on a kept circuit that hears nothing opens a fresh one beside it after `KEPT_HEDGE`,
//! not after `ANSWER_SUSPECT`; one that hears anything (it is only slow) opens none.

use super::hedge::KEPT_HEDGE;
use super::*;

/// Counts Connect asks and refuses them: a fresh circuit's dial ends at its ticket.
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

/// A kept dialer circuit to `daemon` that heard its last keepalive 1 s ago: open, by every
/// measure the carrier had before the dial.
async fn kept(carrier: &HubCarrier, daemon: &str) -> Arc<mux::Mux> {
    let (circuit, _said) = mux::start_dialer(
        Box::new(Gone),
        carrier.stats.clone(),
        Arc::downgrade(&carrier.alive),
        Duration::from_secs(30),
        Duration::from_secs(300),
    );
    circuit.heard_at(Instant::now() - Duration::from_secs(1));
    carrier.kept.slot(daemon, CircuitLane::Cheap).lock().await.live = Some(circuit.clone());
    circuit
}

fn timings() -> Timings {
    Timings { handshake: Duration::from_secs(4), ..Timings::default() }
}

/// The dead circuit's dial asks for a fresh circuit at `KEPT_HEDGE`, well before the old wait
/// (`ANSWER_SUSPECT`) gave up on it, and only once: no second fresh dial when both fail.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_dial_on_a_silent_kept_circuit_opens_a_fresh_one_at_the_hedge() {
    let tickets = Arc::new(NoConnect { asked: AtomicU64::new(0) });
    let carrier = Arc::new(HubCarrier::new(tickets.clone(), [7u8; 32], timings()));
    let daemon = "machine-b";
    let dead = kept(&carrier, daemon).await;

    let dial = {
        let carrier = carrier.clone();
        tokio::spawn(async move {
            let mut report = DialReport::default();
            carrier
                .kept_open(
                    daemon,
                    CircuitLane::Cheap,
                    hello_record(CircuitService::Acpmux),
                    &[],
                    &mut report,
                    Path::Relay,
                )
                .await
        })
    };
    tokio::time::sleep(KEPT_HEDGE + Duration::from_millis(300)).await;
    assert_eq!(
        tickets.asked.load(Ordering::SeqCst),
        1,
        "a fresh circuit was asked for {:?} into the dial, before ANSWER_SUSPECT ({:?})",
        KEPT_HEDGE + Duration::from_millis(300),
        mux::ANSWER_SUSPECT
    );
    let answer = dial.await.expect("the dial ran");
    assert!(matches!(answer, KeptOpen::Failed(_)), "neither circuit opened: the dial failed");
    assert_eq!(tickets.asked.load(Ordering::SeqCst), 1, "one fresh circuit, not one per try");
    assert!(dead.is_closed());
}

/// A circuit that hears a record inside the hedge (the PONG behind the OPEN) is alive, only slow
/// to answer: no fresh circuit opens, and the dial takes the old circuit's answer.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_kept_circuit_that_hears_anything_opens_no_fresh_one() {
    let tickets = Arc::new(NoConnect { asked: AtomicU64::new(0) });
    let carrier = HubCarrier::new(tickets.clone(), [7u8; 32], timings());
    let daemon = "machine-b";
    let slow = kept(&carrier, daemon).await;
    let pong = {
        let slow = slow.clone();
        tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(100)).await;
            slow.heard_at(Instant::now());
        })
    };

    let mut report = DialReport::default();
    let answer = carrier
        .kept_open(
            daemon,
            CircuitLane::Cheap,
            hello_record(CircuitService::Acpmux),
            &[],
            &mut report,
            Path::Relay,
        )
        .await;
    pong.await.expect("the pong ran");
    assert_eq!(tickets.asked.load(Ordering::SeqCst), 0, "no fresh circuit beside a live one");
    assert!(
        matches!(&answer, KeptOpen::Refused(r) if r.reason == "service.bad_answer"),
        "the live circuit's own answer (here: none in time) is the dial's"
    );
    assert!(!slow.is_closed(), "a live circuit stays kept");
}

/// A silent direct circuit gives the dial back to the relay at the hedge (the dial's caller then
/// takes the relay's kept circuit), not after a fresh direct handshake's whole 2 s.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_silent_direct_circuit_falls_back_to_the_relay_at_the_hedge() {
    let tickets = Arc::new(NoConnect { asked: AtomicU64::new(0) });
    let carrier = HubCarrier::new(tickets.clone(), [7u8; 32], timings());
    let daemon = "machine-b";
    let (dead, _said) = mux::start_dialer(
        Box::new(Gone),
        carrier.stats.clone(),
        Arc::downgrade(&carrier.alive),
        Duration::from_secs(30),
        Duration::from_secs(300),
    );
    dead.heard_at(Instant::now() - Duration::from_secs(1));
    carrier.direct.kept.slot(daemon, CircuitLane::Cheap).lock().await.live = Some(dead.clone());

    let started = Instant::now();
    let mut report = DialReport::default();
    let answer = carrier
        .kept_open(
            daemon,
            CircuitLane::Cheap,
            hello_record(CircuitService::Acpmux),
            &[],
            &mut report,
            Path::Direct("10.0.0.2:47791".parse().unwrap()),
        )
        .await;
    let took = started.elapsed();
    assert!(took < KEPT_HEDGE + Duration::from_millis(400), "gave the dial back in {took:?}");
    assert!(matches!(answer, KeptOpen::Failed(_)), "the caller goes to the relay");
    assert_eq!(tickets.asked.load(Ordering::SeqCst), 0, "no fresh direct or relay dial here");
    assert!(dead.is_closed());
}
