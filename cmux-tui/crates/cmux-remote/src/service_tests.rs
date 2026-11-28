use std::time::Duration;

use super::*;

struct TestEndpoint {
    outgoing: mpsc::Sender<ReceivedFrame>,
    incoming: Mutex<mpsc::Receiver<ReceivedFrame>>,
    next_sequence: AtomicU64,
    generation: watch::Sender<u64>,
}

impl TestEndpoint {}

#[async_trait]
impl SessionEndpoint for TestEndpoint {
    async fn send_frame(
        &self,
        expected_generation: Option<u64>,
        lane: Lane,
        stream: u64,
        payload: Bytes,
        flags: FrameFlags,
    ) -> Result<u64, ServiceError> {
        let generation = *self.generation.borrow();
        if let Some(expected) = expected_generation
            && expected != generation
        {
            return Err(ServiceError::GenerationChanged { expected, actual: generation });
        }
        let sequence = self.next_sequence.fetch_add(1, Ordering::Relaxed) + 1;
        self.outgoing
            .send(ReceivedFrame { generation, lane, stream, sequence, flags, payload })
            .await
            .map_err(|_| ServiceError::Transport("test peer closed".into()))?;
        Ok(sequence)
    }

    async fn receive_frame(&self) -> Result<Option<ReceivedFrame>, ServiceError> {
        Ok(self.incoming.lock().await.recv().await)
    }

    fn subscribe_generation(&self) -> watch::Receiver<u64> {
        self.generation.subscribe()
    }

    async fn close_session(&self) -> Result<(), ServiceError> {
        Ok(())
    }
}

fn endpoint_pair() -> (Arc<TestEndpoint>, Arc<TestEndpoint>) {
    let (left_tx, left_rx) = mpsc::channel(32);
    let (right_tx, right_rx) = mpsc::channel(32);
    let (left_generation, _) = watch::channel(0);
    let (right_generation, _) = watch::channel(0);
    (
        Arc::new(TestEndpoint {
            outgoing: left_tx,
            incoming: Mutex::new(right_rx),
            next_sequence: AtomicU64::new(0),
            generation: left_generation,
        }),
        Arc::new(TestEndpoint {
            outgoing: right_tx,
            incoming: Mutex::new(left_rx),
            next_sequence: AtomicU64::new(0),
            generation: right_generation,
        }),
    )
}

#[tokio::test]
async fn bulk_reserve_keeps_tunnel_control_and_interactive_available() {
    const KIB: usize = 1024;
    const TOTAL_BUDGET: usize = 8 * KIB;
    const BULK_CEILING: usize = 5 * KIB;
    const BULK_TUNNEL_CEILING: usize = 6 * KIB;
    const NON_INTERACTIVE_CEILING: usize = 7 * KIB;

    // The scaled 5/6/7/8 KiB limits model 20/24/28/32 MiB in production,
    // preserving a non-borrowable tier for each higher-priority lane.
    assert_eq!(BULK_TUNNEL_CEILING - BULK_CEILING, KIB);
    assert_eq!(NON_INTERACTIVE_CEILING - BULK_TUNNEL_CEILING, KIB);
    assert_eq!(TOTAL_BUDGET - NON_INTERACTIVE_CEILING, KIB);

    let (client_endpoint, daemon_endpoint) = endpoint_pair();
    let client = ServiceMultiplexer::new_with_incoming_budget(
        client_endpoint,
        EndpointRole::Client,
        TOTAL_BUDGET,
    );
    let bulk = client.open(Service::MuxControl, BTreeMap::new()).await.unwrap();
    let additional_bulk = client.open(Service::MuxControl, BTreeMap::new()).await.unwrap();
    let tunnel = client.open(Service::TcpTunnel, BTreeMap::new()).await.unwrap();
    let control = client.open(Service::MuxControl, BTreeMap::new()).await.unwrap();
    let interactive = client.open(Service::MuxControl, BTreeMap::new()).await.unwrap();

    for _ in 0..BULK_CEILING / KIB {
        daemon_endpoint
            .send_frame(
                None,
                Lane::Bulk,
                bulk.id(),
                Bytes::from(vec![b'b'; KIB]),
                FrameFlags::empty(),
            )
            .await
            .unwrap();
    }
    daemon_endpoint
        .send_frame(
            None,
            Lane::Bulk,
            additional_bulk.id(),
            Bytes::from_static(b"bulk-overflow"),
            FrameFlags::empty(),
        )
        .await
        .unwrap();
    daemon_endpoint
        .send_frame(
            None,
            Lane::Tunnel,
            tunnel.id(),
            Bytes::from_static(b"tunnel-marker"),
            FrameFlags::empty(),
        )
        .await
        .unwrap();
    daemon_endpoint
        .send_frame(
            None,
            Lane::Control,
            control.id(),
            Bytes::from_static(b"control-marker"),
            FrameFlags::empty(),
        )
        .await
        .unwrap();
    daemon_endpoint
        .send_frame(
            None,
            Lane::Interactive,
            interactive.id(),
            Bytes::from_static(b"interactive-marker"),
            FrameFlags::empty(),
        )
        .await
        .unwrap();

    let interactive_result = tokio::time::timeout(Duration::from_secs(1), interactive.receive())
        .await
        .expect("reader stalled before applying the Bulk reserve policy");
    assert_eq!(
        bulk.receiver.lock().await.chunks.len(),
        BULK_CEILING / KIB,
        "the admitted Bulk backlog must remain undrained"
    );
    assert_eq!(bulk.failure.borrow().clone(), None, "the admitted Bulk stream was reset");
    let additional_bulk_result = additional_bulk.receive().await;
    let tunnel_result = tunnel.receive().await;
    let control_result = control.receive().await;

    let additional_bulk_was_reset = matches!(
        &additional_bulk_result,
        Err(ServiceError::Reset(message)) if message.contains("byte budget")
    );
    let tunnel_was_delivered = matches!(
        &tunnel_result,
        Ok(Some(chunk))
            if chunk.lane == Lane::Tunnel
                && chunk.payload == b"tunnel-marker".as_slice()
    );
    let control_was_delivered = matches!(
        &control_result,
        Ok(Some(chunk))
            if chunk.lane == Lane::Control
                && chunk.payload == b"control-marker".as_slice()
    );
    let interactive_was_delivered = matches!(
        &interactive_result,
        Ok(Some(chunk))
            if chunk.lane == Lane::Interactive
                && chunk.payload == b"interactive-marker".as_slice()
    );
    assert!(
        additional_bulk_was_reset
            && tunnel_was_delivered
            && control_was_delivered
            && interactive_was_delivered,
        "Bulk reserve violation: additional_bulk={additional_bulk_result:?}, \
             tunnel={tunnel_result:?}, control={control_result:?}, \
             interactive={interactive_result:?}"
    );
}

#[test]
fn bulky_streams_default_off_the_interactive_lane() {
    // Process event replays and computer-use screenshots never queue ahead of
    // keystrokes; the tombstone of a closed process stream guards the lane its
    // frames really use.
    assert_eq!(default_lane(Service::ProcessStream), Lane::Bulk);
    assert_eq!(default_lane(Service::ComputerUse), Lane::Control);
    assert_eq!(default_lane(Service::MuxControl), Lane::Interactive);
    assert_eq!(default_lane(Service::TerminalBytes), Lane::Interactive);
    assert_eq!(default_lane(Service::WorkspaceRpc), Lane::Control);
    assert_eq!(legal_tombstone_lane_mask(Service::ProcessStream), lane_bit(Lane::Bulk));
}

/// An endpoint whose sends wait until `resumed_at` (a carrier failing over,
/// or a wedged peer), saying meanwhile whether it is recovering its carrier.
struct StalledEndpoint {
    resumed_at: tokio::time::Instant,
    recovering: bool,
    resets: AtomicU64,
    closed: AtomicBool,
    generation: watch::Sender<u64>,
}

#[async_trait]
impl SessionEndpoint for StalledEndpoint {
    async fn send_frame(
        &self,
        _expected_generation: Option<u64>,
        _lane: Lane,
        _stream: u64,
        _payload: Bytes,
        flags: FrameFlags,
    ) -> Result<u64, ServiceError> {
        tokio::time::sleep_until(self.resumed_at).await;
        if flags.contains(FrameFlags::RESET) {
            self.resets.fetch_add(1, Ordering::Relaxed);
        }
        Ok(1)
    }

    async fn receive_frame(&self) -> Result<Option<ReceivedFrame>, ServiceError> {
        std::future::pending().await
    }

    fn subscribe_generation(&self) -> watch::Receiver<u64> {
        self.generation.subscribe()
    }

    async fn close_session(&self) -> Result<(), ServiceError> {
        self.closed.store(true, Ordering::Release);
        Ok(())
    }

    fn carrier_recovering(&self) -> bool {
        self.recovering && tokio::time::Instant::now() < self.resumed_at
    }
}

fn stalled(after: Duration, recovering: bool) -> Arc<StalledEndpoint> {
    Arc::new(StalledEndpoint {
        resumed_at: tokio::time::Instant::now() + after,
        recovering,
        resets: AtomicU64::new(0),
        closed: AtomicBool::new(false),
        generation: watch::channel(0).0,
    })
}

#[tokio::test(start_paused = true)]
async fn a_stream_dropped_while_the_carrier_fails_over_resets_after_the_resume_and_keeps_the_session()
 {
    // The relay was killed and the session is resuming onto ssh, 9 s of
    // authorization and ssh dial: the dropped stream's RESET waits for it.
    // It closed the session 2 s in, so the resume ended with "connection is
    // closed" and no route line (the carrier ssh failover drill, 11-27).
    let endpoint = stalled(Duration::from_secs(9), true);
    let started = tokio::time::Instant::now();
    send_reset_or_close_session(
        endpoint.clone(),
        None,
        Lane::Interactive,
        1,
        None,
        &AtomicBool::new(false),
        TERMINAL_RESET_DEADLINE,
    )
    .await;
    assert_eq!(endpoint.resets.load(Ordering::Relaxed), 1, "the RESET went on the resumed carrier");
    assert!(!endpoint.closed.load(Ordering::Acquire), "the resuming session was closed");
    assert_eq!(started.elapsed(), Duration::from_secs(9));
}

#[tokio::test(start_paused = true)]
async fn a_reset_a_wedged_peer_never_takes_still_closes_the_session_at_its_deadline() {
    let endpoint = stalled(Duration::from_secs(9), false);
    let started = tokio::time::Instant::now();
    send_reset_or_close_session(
        endpoint.clone(),
        None,
        Lane::Interactive,
        1,
        None,
        &AtomicBool::new(false),
        TERMINAL_RESET_DEADLINE,
    )
    .await;
    assert!(endpoint.closed.load(Ordering::Acquire));
    assert_eq!(endpoint.resets.load(Ordering::Relaxed), 0);
    assert_eq!(started.elapsed(), TERMINAL_RESET_DEADLINE);
}

#[tokio::test(start_paused = true)]
async fn a_recovery_that_never_resumes_closes_the_session_at_the_recovery_bound() {
    let endpoint = stalled(Duration::from_secs(600), true);
    let started = tokio::time::Instant::now();
    send_reset_or_close_session(
        endpoint.clone(),
        None,
        Lane::Interactive,
        1,
        None,
        &AtomicBool::new(false),
        TERMINAL_RESET_DEADLINE,
    )
    .await;
    assert!(endpoint.closed.load(Ordering::Acquire));
    assert_eq!(started.elapsed(), TERMINAL_RESET_RECOVERY_DEADLINE);
}
