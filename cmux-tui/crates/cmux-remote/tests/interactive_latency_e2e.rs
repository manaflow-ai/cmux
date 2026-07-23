use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::time::{Duration, Instant};

use bytes::Bytes;
use cmux_remote::connection::{ClientConnection, ClientConnectionConfig, ReconnectPolicy};
use cmux_remote::crypto::{ClientAuthMode, StaticIdentity};
use cmux_remote::daemon::{RemoteDaemon, ServerConnection, serve_direct_websocket};
use cmux_remote::identity::AuthDatabase;
use cmux_remote::provider::{ConnectRequest, DirectWebSocketProvider, TransportProvider};
use cmux_remote::session::SessionLimits;
use cmux_remote_protocol::{FrameFlags, Lane, LanePolicy, SessionId};
use sha2::{Digest, Sha256};
use tempfile::tempdir;
use tokio::sync::{Barrier, mpsc, oneshot};
use url::Url;
use zeroize::Zeroizing;

const MAXIMUM_FRAME_BYTES: usize = 65_535;
const BULK_BYTES_PER_DIRECTION: usize = 64 * 1024 * 1024;
const BULK_CHUNK_BYTES: usize = 4 * 1024;
const BULK_FRAME_COUNT: usize = BULK_BYTES_PER_DIRECTION / BULK_CHUNK_BYTES;
const ECHO_COUNT: usize = 1_024;
const MINIMUM_BULK_PROGRESS_DURING_ECHOES: usize = 128 * 1024;
const MAXIMUM_STAGNANT_ECHO_INTERVALS: usize = 128;
const CLIENT_BULK_STREAM: u64 = 41;
const SERVER_BULK_STREAM: u64 = 42;
const INTERACTIVE_STREAM: u64 = 7;
const ECHO_TIMEOUT: Duration = Duration::from_secs(5);
const TEST_TIMEOUT: Duration = Duration::from_secs(90);
const P95_BOUND: Duration = Duration::from_millis(250);
const P99_BOUND: Duration = Duration::from_secs(1);

#[derive(Debug)]
struct BulkReport {
    started: Instant,
    finished: Instant,
    bytes: usize,
}

#[derive(Debug)]
struct ReceiveReport {
    finished: Instant,
    bytes: usize,
}

#[derive(Debug)]
struct LatencyMetrics {
    p50: Duration,
    p95: Duration,
    p99: Duration,
    max: Duration,
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn interactive_echo_stays_responsive_during_bidirectional_bulk_transfer() {
    tokio::time::timeout(TEST_TIMEOUT, async {
        let state = tempdir().unwrap();
        let auth = AuthDatabase::load_or_create(state.path(), "latency-e2e", false).unwrap();
        let (daemon, mut accepted) = RemoteDaemon::new(auth.clone(), SessionLimits::default());
        let server = serve_direct_websocket(
            daemon,
            "127.0.0.1:0".parse().unwrap(),
            MAXIMUM_FRAME_BYTES,
            false,
        )
        .await
        .unwrap();
        let endpoint = Url::parse(&format!("ws://{}/v1/link", server.local_addr())).unwrap();
        let invitation = auth.create_invitation(Duration::from_secs(60), Vec::new()).await.unwrap();
        let invitation_secret = invitation.secret_bytes().unwrap();
        let approver = tokio::spawn({
            let auth = auth.clone();
            async move {
                let pending = auth.wait_for_pending(Duration::from_secs(5)).await.unwrap();
                auth.approve(&pending[0].invitation_id).await.unwrap();
            }
        });
        let session = SessionId([0x6c; 16]);
        let group = DirectWebSocketProvider::new(MAXIMUM_FRAME_BYTES)
            .connect(ConnectRequest {
                endpoint,
                session,
                // This deliberately exercises the most contended topology:
                // Interactive and Bulk share one ordered carrier.
                lane_policy: LanePolicy::Single,
                routing: Default::default(),
            })
            .await
            .unwrap();
        let client = ClientConnection::connect(
            group,
            ClientConnectionConfig {
                identity: StaticIdentity::generate().unwrap(),
                expected_daemon: Some(auth.identity().public_key()),
                auth: ClientAuthMode::Invitation {
                    id: invitation.id,
                    secret: Zeroizing::new(invitation_secret),
                },
                device_name: "latency-e2e-client".into(),
                session,
                lane_policy: LanePolicy::Single,
                limits: SessionLimits::default(),
                reconnect: ReconnectPolicy::default(),
            },
        )
        .await
        .unwrap();
        approver.await.unwrap();
        let daemon_client =
            tokio::time::timeout(Duration::from_secs(5), accepted.recv()).await.unwrap().unwrap();
        assert_eq!(client.snapshot().await.physical_link_count, 1);
        assert_eq!(daemon_client.snapshot().await.physical_link_count, 1);

        // Compute reference digests outside the measured overlap window. The
        // receivers hash bytes with optimized dependency code instead of doing
        // 128 MiB of debug-build byte assertions on async worker threads.
        let expected_client_bulk = expected_bulk_digest(0x39);
        let expected_server_bulk = expected_bulk_digest(0xa7);
        let start = Arc::new(Barrier::new(3));
        let client_bulk_progress = Arc::new(AtomicUsize::new(0));
        let server_bulk_progress = Arc::new(AtomicUsize::new(0));
        let client_bulk_received = Arc::new(AtomicUsize::new(0));
        let server_bulk_received = Arc::new(AtomicUsize::new(0));
        let client_bulk_finished = Arc::new(AtomicBool::new(false));
        let server_bulk_finished = Arc::new(AtomicBool::new(false));
        let (client_bulk_started_tx, client_bulk_started_rx) = oneshot::channel();
        let (server_bulk_started_tx, server_bulk_started_rx) = oneshot::channel();
        let (echo_tx, mut echo_rx) = mpsc::channel(1);

        let server_receive = tokio::spawn(run_server_receiver(
            daemon_client.clone(),
            expected_client_bulk,
            client_bulk_received.clone(),
        ));
        let client_receive = tokio::spawn(run_client_receiver(
            client.clone(),
            echo_tx,
            expected_server_bulk,
            server_bulk_received.clone(),
        ));

        let client_bulk = tokio::spawn(send_client_bulk(
            client.clone(),
            start.clone(),
            client_bulk_progress.clone(),
            client_bulk_finished.clone(),
            client_bulk_started_tx,
        ));
        let server_bulk = tokio::spawn(send_server_bulk(
            daemon_client,
            start.clone(),
            server_bulk_progress.clone(),
            server_bulk_finished.clone(),
            server_bulk_started_tx,
        ));

        start.wait().await;
        client_bulk_started_rx.await.unwrap();
        server_bulk_started_rx.await.unwrap();

        let mut latencies = Vec::with_capacity(ECHO_COUNT);
        let mut issued_at = Vec::with_capacity(ECHO_COUNT);
        let mut client_sent_window =
            BulkProgressWindow::new(client_bulk_progress.load(Ordering::Acquire));
        let mut server_sent_window =
            BulkProgressWindow::new(server_bulk_progress.load(Ordering::Acquire));
        let mut client_received_window =
            BulkProgressWindow::new(client_bulk_received.load(Ordering::Acquire));
        let mut server_received_window =
            BulkProgressWindow::new(server_bulk_received.load(Ordering::Acquire));
        for index in 0..ECHO_COUNT {
            assert!(
                !client_bulk.is_finished(),
                "client-to-daemon Bulk task stopped before echo {index} was issued"
            );
            assert!(
                !server_bulk.is_finished(),
                "daemon-to-client Bulk task stopped before echo {index} was issued"
            );
            assert_bulk_still_active(
                "client-to-daemon",
                &client_bulk_progress,
                &client_bulk_finished,
                index,
            );
            assert_bulk_still_active(
                "daemon-to-client",
                &server_bulk_progress,
                &server_bulk_finished,
                index,
            );

            let payload = echo_payload(index);
            let issued = Instant::now();
            issued_at.push(issued);
            client
                .send(Lane::Interactive, INTERACTIVE_STREAM, payload.clone(), FrameFlags::empty())
                .await
                .unwrap();
            let echoed = tokio::time::timeout(ECHO_TIMEOUT, echo_rx.recv())
                .await
                .expect("Interactive echo exceeded the finite fairness bound")
                .expect("Interactive echo receiver stopped");
            let elapsed = issued.elapsed();
            assert_eq!(echoed, payload, "Interactive echo {index} was corrupted");
            latencies.push(elapsed);

            client_sent_window.observe(client_bulk_progress.load(Ordering::Acquire));
            server_sent_window.observe(server_bulk_progress.load(Ordering::Acquire));
            client_received_window.observe(client_bulk_received.load(Ordering::Acquire));
            server_received_window.observe(server_bulk_received.load(Ordering::Acquire));
        }

        client_sent_window.assert_progress("client-to-daemon sender");
        server_sent_window.assert_progress("daemon-to-client sender");
        client_received_window.assert_progress("client-to-daemon receiver");
        server_received_window.assert_progress("daemon-to-client receiver");

        let client_bulk = client_bulk.await.unwrap();
        let server_bulk = server_bulk.await.unwrap();
        let server_receive = server_receive.await.unwrap();
        let client_receive = client_receive.await.unwrap();

        assert_eq!(client_bulk.bytes, BULK_BYTES_PER_DIRECTION);
        assert_eq!(server_bulk.bytes, BULK_BYTES_PER_DIRECTION);
        assert_eq!(server_receive.bytes, BULK_BYTES_PER_DIRECTION);
        assert_eq!(client_receive.bytes, BULK_BYTES_PER_DIRECTION);
        assert_eq!(client_bulk_progress.load(Ordering::Acquire), BULK_BYTES_PER_DIRECTION);
        assert_eq!(server_bulk_progress.load(Ordering::Acquire), BULK_BYTES_PER_DIRECTION);
        assert_eq!(client_bulk_received.load(Ordering::Acquire), BULK_BYTES_PER_DIRECTION);
        assert_eq!(server_bulk_received.load(Ordering::Acquire), BULK_BYTES_PER_DIRECTION);

        let overlap_start = client_bulk.started.max(server_bulk.started);
        let overlap_end = client_bulk.finished.min(server_bulk.finished);
        let overlapping_echoes = issued_at
            .iter()
            .filter(|issued| **issued >= overlap_start && **issued < overlap_end)
            .count();
        assert_eq!(
            overlapping_echoes, ECHO_COUNT,
            "all Interactive echoes must be issued while both fixed 64 MiB transfers are active"
        );

        let metrics = latency_metrics(latencies);
        assert!(
            metrics.p95 < P95_BOUND,
            "Interactive p95 {:?} exceeded conservative {:?} bound",
            metrics.p95,
            P95_BOUND,
        );
        assert!(
            metrics.p99 < P99_BOUND,
            "Interactive p99 {:?} exceeded conservative {:?} bound",
            metrics.p99,
            P99_BOUND,
        );
        assert!(
            metrics.max < ECHO_TIMEOUT,
            "Interactive max {:?} exceeded finite {:?} bound",
            metrics.max,
            ECHO_TIMEOUT,
        );

        let transfer_started = client_bulk.started.min(server_bulk.started);
        let transfer_finished = server_receive.finished.max(client_receive.finished);
        let transfer_duration = transfer_finished.duration_since(transfer_started);
        let aggregate_mib = (client_bulk.bytes + server_bulk.bytes) as f64 / (1024.0 * 1024.0);
        let aggregate_mib_per_second = aggregate_mib / transfer_duration.as_secs_f64();
        eprintln!(
            "interactive-under-bulk: echoes={ECHO_COUNT} bulk_each_mib={} \
             p50={:?} p95={:?} p99={:?} max={:?} transfer={:?} aggregate_mib_s={:.1} \
             sent_during_echoes_mib={:.2}/{:.2} received_during_echoes_mib={:.2}/{:.2} \
             max_stagnant_intervals={}/{}/{}/{}",
            BULK_BYTES_PER_DIRECTION / (1024 * 1024),
            metrics.p50,
            metrics.p95,
            metrics.p99,
            metrics.max,
            transfer_duration,
            aggregate_mib_per_second,
            client_sent_window.progress() as f64 / (1024.0 * 1024.0),
            server_sent_window.progress() as f64 / (1024.0 * 1024.0),
            client_received_window.progress() as f64 / (1024.0 * 1024.0),
            server_received_window.progress() as f64 / (1024.0 * 1024.0),
            client_sent_window.maximum_stagnant_intervals,
            server_sent_window.maximum_stagnant_intervals,
            client_received_window.maximum_stagnant_intervals,
            server_received_window.maximum_stagnant_intervals,
        );

        client.close().await.unwrap();
        server.shutdown().await.unwrap();
    })
    .await
    .expect("Interactive-under-bulk E2E exceeded its wall-clock safety timeout");
}

async fn send_client_bulk(
    client: Arc<ClientConnection>,
    start: Arc<Barrier>,
    progress: Arc<AtomicUsize>,
    finished: Arc<AtomicBool>,
    started_tx: oneshot::Sender<()>,
) -> BulkReport {
    start.wait().await;
    let started = Instant::now();
    let mut started_tx = Some(started_tx);
    for index in 0..BULK_FRAME_COUNT {
        client
            .send(Lane::Bulk, CLIENT_BULK_STREAM, bulk_payload(0x39, index), FrameFlags::empty())
            .await
            .unwrap();
        progress.store((index + 1) * BULK_CHUNK_BYTES, Ordering::Release);
        if let Some(started_tx) = started_tx.take() {
            let _ = started_tx.send(());
        }
    }
    let finished_at = Instant::now();
    finished.store(true, Ordering::Release);
    BulkReport { started, finished: finished_at, bytes: BULK_BYTES_PER_DIRECTION }
}

async fn send_server_bulk(
    daemon: Arc<ServerConnection>,
    start: Arc<Barrier>,
    progress: Arc<AtomicUsize>,
    finished: Arc<AtomicBool>,
    started_tx: oneshot::Sender<()>,
) -> BulkReport {
    start.wait().await;
    let started = Instant::now();
    let mut started_tx = Some(started_tx);
    for index in 0..BULK_FRAME_COUNT {
        daemon
            .send(Lane::Bulk, SERVER_BULK_STREAM, bulk_payload(0xa7, index), FrameFlags::empty())
            .await
            .unwrap();
        progress.store((index + 1) * BULK_CHUNK_BYTES, Ordering::Release);
        if let Some(started_tx) = started_tx.take() {
            let _ = started_tx.send(());
        }
    }
    let finished_at = Instant::now();
    finished.store(true, Ordering::Release);
    BulkReport { started, finished: finished_at, bytes: BULK_BYTES_PER_DIRECTION }
}

async fn run_server_receiver(
    daemon: Arc<ServerConnection>,
    expected_digest: [u8; 32],
    progress: Arc<AtomicUsize>,
) -> ReceiveReport {
    let mut bulk_index = 0;
    let mut echo_count = 0;
    let mut bulk_digest = Sha256::new();
    while bulk_index < BULK_FRAME_COUNT || echo_count < ECHO_COUNT {
        let frame = daemon.receive().await.unwrap().expect("client connection closed early");
        match (frame.lane, frame.stream) {
            (Lane::Bulk, CLIENT_BULK_STREAM) => {
                assert_bulk_frame_header(&frame.payload, bulk_index);
                bulk_digest.update(&frame.payload);
                bulk_index += 1;
                progress.store(bulk_index * BULK_CHUNK_BYTES, Ordering::Release);
            }
            (Lane::Interactive, INTERACTIVE_STREAM) => {
                assert_eq!(frame.payload, echo_payload(echo_count));
                daemon
                    .send(Lane::Interactive, INTERACTIVE_STREAM, frame.payload, FrameFlags::empty())
                    .await
                    .unwrap();
                echo_count += 1;
            }
            (lane, stream) => panic!("unexpected client frame on {lane}/{stream}"),
        }
    }
    assert_eq!(bulk_index * BULK_CHUNK_BYTES, BULK_BYTES_PER_DIRECTION);
    assert_eq!(echo_count, ECHO_COUNT);
    let actual_digest: [u8; 32] = bulk_digest.finalize().into();
    assert_eq!(actual_digest, expected_digest, "client-to-daemon Bulk digest changed");
    ReceiveReport { finished: Instant::now(), bytes: bulk_index * BULK_CHUNK_BYTES }
}

async fn run_client_receiver(
    client: Arc<ClientConnection>,
    echo_tx: mpsc::Sender<Bytes>,
    expected_digest: [u8; 32],
    progress: Arc<AtomicUsize>,
) -> ReceiveReport {
    let mut bulk_index = 0;
    let mut echo_count = 0;
    let mut bulk_digest = Sha256::new();
    while bulk_index < BULK_FRAME_COUNT || echo_count < ECHO_COUNT {
        let frame = client.receive().await.unwrap().expect("daemon connection closed early");
        match (frame.lane, frame.stream) {
            (Lane::Bulk, SERVER_BULK_STREAM) => {
                assert_bulk_frame_header(&frame.payload, bulk_index);
                bulk_digest.update(&frame.payload);
                bulk_index += 1;
                progress.store(bulk_index * BULK_CHUNK_BYTES, Ordering::Release);
            }
            (Lane::Interactive, INTERACTIVE_STREAM) => {
                echo_tx.send(frame.payload).await.expect("Interactive echo consumer stopped");
                echo_count += 1;
            }
            (lane, stream) => panic!("unexpected daemon frame on {lane}/{stream}"),
        }
    }
    assert_eq!(bulk_index * BULK_CHUNK_BYTES, BULK_BYTES_PER_DIRECTION);
    assert_eq!(echo_count, ECHO_COUNT);
    let actual_digest: [u8; 32] = bulk_digest.finalize().into();
    assert_eq!(actual_digest, expected_digest, "daemon-to-client Bulk digest changed");
    ReceiveReport { finished: Instant::now(), bytes: bulk_index * BULK_CHUNK_BYTES }
}

fn assert_bulk_still_active(
    direction: &str,
    progress: &AtomicUsize,
    finished: &AtomicBool,
    echo_index: usize,
) {
    let bytes = progress.load(Ordering::Acquire);
    assert!(bytes > 0, "{direction} Bulk had not started before echo {echo_index}");
    assert!(
        bytes < BULK_BYTES_PER_DIRECTION,
        "{direction} Bulk finished before echo {echo_index} was issued"
    );
    assert!(
        !finished.load(Ordering::Acquire),
        "{direction} Bulk task finished before echo {echo_index} was issued"
    );
}

struct BulkProgressWindow {
    start: usize,
    previous: usize,
    stagnant_intervals: usize,
    maximum_stagnant_intervals: usize,
}

impl BulkProgressWindow {
    fn new(start: usize) -> Self {
        Self { start, previous: start, stagnant_intervals: 0, maximum_stagnant_intervals: 0 }
    }

    fn observe(&mut self, current: usize) {
        assert!(
            current >= self.previous,
            "Bulk progress moved backwards from {} to {current} bytes",
            self.previous,
        );
        if current == self.previous {
            self.stagnant_intervals += 1;
        } else {
            self.stagnant_intervals = 0;
        }
        self.maximum_stagnant_intervals =
            self.maximum_stagnant_intervals.max(self.stagnant_intervals);
        self.previous = current;
    }

    fn progress(&self) -> usize {
        self.previous.saturating_sub(self.start)
    }

    fn assert_progress(&self, path: &str) {
        let progress = self.progress();
        assert!(
            progress >= MINIMUM_BULK_PROGRESS_DURING_ECHOES,
            "{path} Bulk advanced only {progress} bytes during the Interactive echo window"
        );
        assert!(
            self.maximum_stagnant_intervals <= MAXIMUM_STAGNANT_ECHO_INTERVALS,
            "{path} Bulk made no progress for {} consecutive echo intervals",
            self.maximum_stagnant_intervals,
        );
    }
}

fn bulk_payload(seed: u8, index: usize) -> Bytes {
    let mut payload = vec![0_u8; BULK_CHUNK_BYTES];
    payload[..8].copy_from_slice(&(index as u64).to_be_bytes());
    for (offset, byte) in payload[8..].iter_mut().enumerate() {
        *byte = seed
            .wrapping_add((index as u8).wrapping_mul(17))
            .wrapping_add((offset as u8).wrapping_mul(31));
    }
    Bytes::from(payload)
}

fn assert_bulk_frame_header(payload: &Bytes, expected_index: usize) {
    assert_eq!(payload.len(), BULK_CHUNK_BYTES);
    let mut encoded_index = [0_u8; 8];
    encoded_index.copy_from_slice(&payload[..8]);
    assert_eq!(u64::from_be_bytes(encoded_index), expected_index as u64);
}

fn expected_bulk_digest(seed: u8) -> [u8; 32] {
    let mut digest = Sha256::new();
    for index in 0..BULK_FRAME_COUNT {
        digest.update(bulk_payload(seed, index));
    }
    digest.finalize().into()
}

fn echo_payload(index: usize) -> Bytes {
    let mut payload = [0_u8; 16];
    payload[..8].copy_from_slice(b"keyecho:");
    payload[8..].copy_from_slice(&(index as u64).to_be_bytes());
    Bytes::copy_from_slice(&payload)
}

fn latency_metrics(mut samples: Vec<Duration>) -> LatencyMetrics {
    assert_eq!(samples.len(), ECHO_COUNT);
    samples.sort_unstable();
    LatencyMetrics {
        p50: percentile(&samples, 50),
        p95: percentile(&samples, 95),
        p99: percentile(&samples, 99),
        max: *samples.last().unwrap(),
    }
}

fn percentile(sorted: &[Duration], percentile: usize) -> Duration {
    let rank = (sorted.len() * percentile).div_ceil(100);
    sorted[rank.saturating_sub(1)]
}
