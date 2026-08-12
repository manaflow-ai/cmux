use std::sync::Arc;
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
use tokio::sync::{mpsc, watch};
use url::Url;
use zeroize::Zeroizing;

const MAXIMUM_FRAME_BYTES: usize = 65_535;
const BULK_CHUNK_BYTES: usize = 4 * 1024;
// Keep this regression strictly sequential so every sample models one
// keystroke round trip. The black-box transport proof harness separately
// requires 1,000 markers overlapping a 64 MiB transfer.
const CLIENT_BULK_STREAM: u64 = 41;
const SERVER_BULK_STREAM: u64 = 42;
const INTERACTIVE_STREAM: u64 = 7;
const ECHO_TIMEOUT: Duration = Duration::from_secs(5);
const TEST_TIMEOUT: Duration = Duration::from_secs(90);
const P95_BOUND: Duration = Duration::from_millis(250);
const P99_BOUND: Duration = Duration::from_secs(1);

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct Workload {
    bulk_bytes_per_direction: usize,
    echo_count: usize,
    enforce_latency_bounds: bool,
}

const DEFAULT_WORKLOAD: Workload = Workload {
    bulk_bytes_per_direction: 64 * 1024 * 1024,
    echo_count: 256,
    enforce_latency_bounds: true,
};
// Memory instrumentation observes the same transport lifecycle at much higher
// per-event cost. Reduce only event volume, while retaining both directions,
// receiver fences, payload digests, and the unchanged final watchdog.
const MEMORY_INSTRUMENTED_WORKLOAD: Workload = Workload {
    bulk_bytes_per_direction: 4 * 1024 * 1024,
    echo_count: 32,
    enforce_latency_bounds: false,
};

impl Workload {
    fn from_environment() -> Self {
        match std::env::var("CMUX_TEST_MEMORY_INSTRUMENTATION") {
            Err(std::env::VarError::NotPresent) => DEFAULT_WORKLOAD,
            Ok(value) if value == "1" => MEMORY_INSTRUMENTED_WORKLOAD,
            Ok(value) => panic!("CMUX_TEST_MEMORY_INSTRUMENTATION must be 1, got {value:?}"),
            Err(error) => panic!("CMUX_TEST_MEMORY_INSTRUMENTATION is not Unicode: {error}"),
        }
    }

    fn bulk_frame_count(self) -> usize {
        assert_eq!(self.bulk_bytes_per_direction % BULK_CHUNK_BYTES, 0);
        self.bulk_bytes_per_direction / BULK_CHUNK_BYTES
    }

    fn bulk_frames_per_echo(self) -> usize {
        let bulk_frame_count = self.bulk_frame_count();
        assert_eq!(bulk_frame_count % self.echo_count, 0);
        bulk_frame_count / self.echo_count
    }

    fn receiver_fence_frames_per_echo(self) -> usize {
        let bulk_frames_per_echo = self.bulk_frames_per_echo();
        assert!(bulk_frames_per_echo > 1);
        bulk_frames_per_echo / 2
    }
}

#[derive(Debug)]
struct BulkReport {
    started: Instant,
    bytes: usize,
}

#[derive(Debug)]
struct ReceiveReport {
    started: Instant,
    bulk_finished: Instant,
    finished: Instant,
    bytes: usize,
    digest: [u8; 32],
}

#[derive(Debug)]
struct LatencyMetrics {
    p50: Duration,
    p95: Duration,
    p99: Duration,
    max: Duration,
}

#[derive(Debug)]
struct EchoFenceReport {
    responses: usize,
    daemon_received_client_bulk: usize,
    client_received_daemon_bulk: usize,
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn interactive_echo_stays_responsive_during_bidirectional_bulk_transfer() {
    tokio::time::timeout(TEST_TIMEOUT, async {
        let workload = Workload::from_environment();
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
        // per-byte assertions on async worker threads.
        let expected_client_bulk = expected_bulk_digest(workload, 0x39);
        let expected_server_bulk = expected_bulk_digest(workload, 0xa7);
        // A query releases exactly one fixed Bulk epoch in each direction. The
        // responder waits for both remote receivers to observe half that epoch
        // before replying. Every measured RTT therefore causally contains new
        // receiver-observed Bulk without using transfer duration as a clock.
        let (client_epoch_tx, client_epoch_rx) = mpsc::channel(1);
        let (server_epoch_tx, server_epoch_rx) = mpsc::channel(1);
        let (daemon_bulk_progress_tx, daemon_bulk_progress_rx) = watch::channel(0_usize);
        let (client_bulk_progress_tx, client_bulk_progress_rx) = watch::channel(0_usize);
        let (query_tx, query_rx) = mpsc::channel(1);
        let (echo_tx, mut echo_rx) = mpsc::channel(1);

        let server_receive = tokio::spawn(run_server_receiver(
            workload,
            daemon_client.clone(),
            query_tx,
            daemon_bulk_progress_tx,
        ));
        let client_receive = tokio::spawn(run_client_receiver(
            workload,
            client.clone(),
            echo_tx,
            client_bulk_progress_tx,
        ));
        let responder = tokio::spawn(run_echo_responder(
            workload,
            daemon_client.clone(),
            query_rx,
            daemon_bulk_progress_rx,
            client_bulk_progress_rx,
        ));
        let client_bulk = tokio::spawn(send_client_bulk(workload, client.clone(), client_epoch_rx));
        let server_bulk = tokio::spawn(send_server_bulk(workload, daemon_client, server_epoch_rx));

        let mut latencies = Vec::with_capacity(workload.echo_count);
        for index in 0..workload.echo_count {
            let payload = echo_payload(index);
            let issued = Instant::now();
            client
                .send(Lane::Interactive, INTERACTIVE_STREAM, payload.clone(), FrameFlags::empty())
                .await
                .unwrap();
            let (client_credit, server_credit) =
                tokio::join!(client_epoch_tx.send(index), server_epoch_tx.send(index),);
            client_credit.expect("client Bulk producer stopped before its epoch credit");
            server_credit.expect("server Bulk producer stopped before its epoch credit");
            let echoed = tokio::time::timeout(ECHO_TIMEOUT, echo_rx.recv())
                .await
                .expect("Interactive echo exceeded the finite fairness bound")
                .expect("Interactive echo receiver stopped");
            let elapsed = issued.elapsed();
            assert_eq!(echoed, payload, "Interactive echo {index} was corrupted");
            latencies.push(elapsed);
        }
        drop((client_epoch_tx, server_epoch_tx));

        let client_bulk = client_bulk.await.unwrap();
        let server_bulk = server_bulk.await.unwrap();
        let responder = responder.await.unwrap();
        let server_receive = server_receive.await.unwrap();
        let client_receive = client_receive.await.unwrap();

        assert_eq!(client_bulk.bytes, workload.bulk_bytes_per_direction);
        assert_eq!(server_bulk.bytes, workload.bulk_bytes_per_direction);
        assert_eq!(server_receive.bytes, client_bulk.bytes);
        assert_eq!(client_receive.bytes, server_bulk.bytes);
        assert_eq!(responder.responses, workload.echo_count);
        assert!(
            responder.daemon_received_client_bulk
                >= receiver_fence_target(workload, workload.echo_count - 1)
        );
        assert!(
            responder.client_received_daemon_bulk
                >= receiver_fence_target(workload, workload.echo_count - 1)
        );
        assert_eq!(
            server_receive.digest, expected_client_bulk,
            "client-to-daemon Bulk digest changed",
        );
        assert_eq!(
            client_receive.digest, expected_server_bulk,
            "daemon-to-client Bulk digest changed",
        );
        assert!(server_receive.started <= server_receive.bulk_finished);
        assert!(server_receive.bulk_finished <= server_receive.finished);
        assert!(client_receive.started <= client_receive.bulk_finished);
        assert!(client_receive.bulk_finished <= client_receive.finished);

        let metrics = latency_metrics(latencies);
        if workload.enforce_latency_bounds {
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
        }
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
            "interactive-under-bulk: echoes={} bulk_each_mib={} \
             p50={:?} p95={:?} p99={:?} max={:?} transfer={:?} aggregate_mib_s={:.1} \
             receiver_fenced_mib={:.2}/{:.2}",
            workload.echo_count,
            workload.bulk_bytes_per_direction / (1024 * 1024),
            metrics.p50,
            metrics.p95,
            metrics.p99,
            metrics.max,
            transfer_duration,
            aggregate_mib_per_second,
            responder.daemon_received_client_bulk as f64 / (1024.0 * 1024.0),
            responder.client_received_daemon_bulk as f64 / (1024.0 * 1024.0),
        );

        client.close().await.unwrap();
        server.shutdown().await.unwrap();
    })
    .await
    .expect("Interactive-under-bulk E2E exceeded its wall-clock safety timeout");
}

async fn send_client_bulk(
    workload: Workload,
    client: Arc<ClientConnection>,
    mut epochs: mpsc::Receiver<usize>,
) -> BulkReport {
    let mut started = None;
    let bulk_frames_per_echo = workload.bulk_frames_per_echo();
    for expected_epoch in 0..workload.echo_count {
        let epoch = epochs.recv().await.expect("client Bulk epoch source stopped early");
        assert_eq!(epoch, expected_epoch, "client Bulk epoch changed order");
        started.get_or_insert_with(Instant::now);
        let first = epoch * bulk_frames_per_echo;
        for index in first..first + bulk_frames_per_echo {
            client
                .send(
                    Lane::Bulk,
                    CLIENT_BULK_STREAM,
                    bulk_payload(0x39, index),
                    FrameFlags::empty(),
                )
                .await
                .unwrap();
        }
    }
    BulkReport { started: started.unwrap(), bytes: workload.bulk_bytes_per_direction }
}

async fn send_server_bulk(
    workload: Workload,
    daemon: Arc<ServerConnection>,
    mut epochs: mpsc::Receiver<usize>,
) -> BulkReport {
    let mut started = None;
    let bulk_frames_per_echo = workload.bulk_frames_per_echo();
    for expected_epoch in 0..workload.echo_count {
        let epoch = epochs.recv().await.expect("server Bulk epoch source stopped early");
        assert_eq!(epoch, expected_epoch, "server Bulk epoch changed order");
        started.get_or_insert_with(Instant::now);
        let first = epoch * bulk_frames_per_echo;
        for index in first..first + bulk_frames_per_echo {
            daemon
                .send(
                    Lane::Bulk,
                    SERVER_BULK_STREAM,
                    bulk_payload(0xa7, index),
                    FrameFlags::empty(),
                )
                .await
                .unwrap();
        }
    }
    BulkReport { started: started.unwrap(), bytes: workload.bulk_bytes_per_direction }
}

async fn run_server_receiver(
    workload: Workload,
    daemon: Arc<ServerConnection>,
    query_tx: mpsc::Sender<(usize, Bytes)>,
    progress: watch::Sender<usize>,
) -> ReceiveReport {
    let mut bulk_index = 0;
    let mut started = None;
    let mut bulk_finished = None;
    let mut echo_count = 0;
    let mut bulk_digest = Sha256::new();
    let bulk_frame_count = workload.bulk_frame_count();
    while bulk_index < bulk_frame_count || echo_count < workload.echo_count {
        let frame = daemon.receive().await.unwrap().expect("client connection closed early");
        match (frame.lane, frame.stream) {
            (Lane::Bulk, CLIENT_BULK_STREAM) => {
                let received_at = Instant::now();
                if started.is_none() {
                    started = Some(received_at);
                }
                assert_bulk_frame_header(&frame.payload, bulk_index);
                bulk_digest.update(&frame.payload);
                bulk_index += 1;
                progress.send_replace(bulk_index * BULK_CHUNK_BYTES);
                if bulk_index == bulk_frame_count {
                    bulk_finished = Some(received_at);
                }
            }
            (Lane::Interactive, INTERACTIVE_STREAM) => {
                assert_eq!(frame.payload, echo_payload(echo_count));
                query_tx
                    .send((echo_count, frame.payload))
                    .await
                    .expect("Interactive responder stopped");
                echo_count += 1;
            }
            (lane, stream) => panic!("unexpected client frame on {lane}/{stream}"),
        }
    }
    assert_eq!(bulk_index, bulk_frame_count);
    assert_eq!(echo_count, workload.echo_count);
    ReceiveReport {
        started: started.unwrap(),
        bulk_finished: bulk_finished.unwrap(),
        finished: Instant::now(),
        bytes: bulk_index * BULK_CHUNK_BYTES,
        digest: bulk_digest.finalize().into(),
    }
}

async fn run_client_receiver(
    workload: Workload,
    client: Arc<ClientConnection>,
    echo_tx: mpsc::Sender<Bytes>,
    progress: watch::Sender<usize>,
) -> ReceiveReport {
    let mut bulk_index = 0;
    let mut started = None;
    let mut bulk_finished = None;
    let mut echo_count = 0;
    let mut bulk_digest = Sha256::new();
    let bulk_frame_count = workload.bulk_frame_count();
    while bulk_index < bulk_frame_count || echo_count < workload.echo_count {
        let frame = client.receive().await.unwrap().expect("daemon connection closed early");
        match (frame.lane, frame.stream) {
            (Lane::Bulk, SERVER_BULK_STREAM) => {
                let received_at = Instant::now();
                if started.is_none() {
                    started = Some(received_at);
                }
                assert_bulk_frame_header(&frame.payload, bulk_index);
                bulk_digest.update(&frame.payload);
                bulk_index += 1;
                progress.send_replace(bulk_index * BULK_CHUNK_BYTES);
                if bulk_index == bulk_frame_count {
                    bulk_finished = Some(received_at);
                }
            }
            (Lane::Interactive, INTERACTIVE_STREAM) => {
                echo_tx.send(frame.payload).await.expect("Interactive echo consumer stopped");
                echo_count += 1;
            }
            (lane, stream) => panic!("unexpected daemon frame on {lane}/{stream}"),
        }
    }
    assert_eq!(bulk_index, bulk_frame_count);
    assert_eq!(echo_count, workload.echo_count);
    ReceiveReport {
        started: started.unwrap(),
        bulk_finished: bulk_finished.unwrap(),
        finished: Instant::now(),
        bytes: bulk_index * BULK_CHUNK_BYTES,
        digest: bulk_digest.finalize().into(),
    }
}

async fn run_echo_responder(
    workload: Workload,
    daemon: Arc<ServerConnection>,
    mut queries: mpsc::Receiver<(usize, Bytes)>,
    mut daemon_received_client_bulk: watch::Receiver<usize>,
    mut client_received_daemon_bulk: watch::Receiver<usize>,
) -> EchoFenceReport {
    let mut daemon_progress = 0;
    let mut client_progress = 0;
    for expected_index in 0..workload.echo_count {
        let (index, payload) =
            queries.recv().await.expect("Interactive query source stopped early");
        assert_eq!(index, expected_index, "Interactive query changed order");
        let target = receiver_fence_target(workload, index);
        daemon_progress = wait_for_receiver_progress(
            &mut daemon_received_client_bulk,
            target,
            "client-to-daemon",
        )
        .await;
        client_progress = wait_for_receiver_progress(
            &mut client_received_daemon_bulk,
            target,
            "daemon-to-client",
        )
        .await;
        daemon
            .send(Lane::Interactive, INTERACTIVE_STREAM, payload, FrameFlags::empty())
            .await
            .unwrap();
    }
    EchoFenceReport {
        responses: workload.echo_count,
        daemon_received_client_bulk: daemon_progress,
        client_received_daemon_bulk: client_progress,
    }
}

async fn wait_for_receiver_progress(
    progress: &mut watch::Receiver<usize>,
    target: usize,
    direction: &str,
) -> usize {
    progress
        .wait_for(|received| *received >= target)
        .await
        .unwrap_or_else(|_| panic!("{direction} Bulk receiver stopped before {target} bytes"));
    let received = *progress.borrow_and_update();
    assert!(received >= target, "{direction} Bulk receiver fence opened early");
    received
}

fn receiver_fence_target(workload: Workload, echo_index: usize) -> usize {
    (echo_index * workload.bulk_frames_per_echo() + workload.receiver_fence_frames_per_echo())
        * BULK_CHUNK_BYTES
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

fn expected_bulk_digest(workload: Workload, seed: u8) -> [u8; 32] {
    let mut digest = Sha256::new();
    for index in 0..workload.bulk_frame_count() {
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
    assert!(!samples.is_empty());
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
