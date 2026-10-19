//! Keystroke echo while another pane floods, across a shaped link.
//!
//! A real daemon and client talk over a direct WebSocket through a TCP
//! shaper (one-way delay, a bandwidth cap and a bounded router queue). The
//! daemon's mux socket is a scripted mux server: surface 1 floods output,
//! surface 2 echoes every keystroke, sometimes follows it with a burst, and
//! a `read-screen` on surface 2 is answered with how many surface-2 lines it
//! wrote first. The client is a local mux client on the bridge socket.
//!
//! Surface 2 also moves between lanes on purpose: some echoes are followed
//! by bursts past the echo credit (the surface must go back to Bulk), by a
//! `scroll-changed` event, or by an unscoped `loopback-data` line (a
//! barrier), and some keystrokes come after a gap longer than the window.
//! Each of those falls back to Bulk by design, so those keystrokes are as
//! slow as without the feature. `ECHO_LANE_E2E_PLAIN=1` leaves them out, to
//! measure plain typing.
//!
//! Checked: every surface-1 line arrives once and in order, every surface-2
//! line, unscoped line and reply arrives in the order the server wrote them
//! (the ordering rule of `mux-echo-lane-v1`), every keystroke is echoed, and
//! with the feature on the median echo is fast (the feature really ran).
//! Printed: echo latency p50/p95/p99. Run once as is (opt-in) and once
//! with `CMUX_REMOTE_MUX_ECHO_LANE=0` (the previous behavior) to compare.

#![cfg(unix)]

use std::sync::Arc;
use std::time::{Duration, Instant};

use base64::Engine;
use cmux_remote::bridge::serve_mux_bridge;
use cmux_remote::connection::{ClientConnection, ClientConnectionConfig, ReconnectPolicy};
use cmux_remote::crypto::{ClientAuthMode, StaticIdentity};
use cmux_remote::daemon::{RemoteDaemon, serve_direct_websocket};
use cmux_remote::identity::AuthDatabase;
use cmux_remote::provider::{ConnectRequest, DirectWebSocketProvider, TransportProvider};
use cmux_remote::service::{EndpointRole, ServiceMultiplexer};
use cmux_remote::services::DaemonServices;
use cmux_remote::session::SessionLimits;
use cmux_remote::workspace::WorkspaceService;
use cmux_remote_protocol::{LanePolicy, SessionId};
use serde_json::{Value, json};
use tempfile::tempdir;
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::net::{TcpListener, TcpStream, UnixListener, UnixStream};
use tokio::sync::{mpsc, oneshot};
use url::Url;
use zeroize::Zeroizing;

const MAXIMUM_FRAME_BYTES: usize = 65_535;
const ONE_WAY_DELAY: Duration = Duration::from_millis(15);
/// 40 Mbit/s each way.
const BYTES_PER_SECOND: f64 = 5_000_000.0;
/// Chunks the shaper holds per direction (a router queue of about 1 MiB).
const ROUTER_QUEUE_CHUNKS: usize = 64;
const SHAPER_CHUNK: usize = 16 * 1024;
const KEYSTROKES: u64 = 40;
const KEY_GAP: Duration = Duration::from_millis(40);
const FLOOD_LINE_BYTES: usize = 3 * 1024;
const BURST_EVERY: u64 = 10;
const READ_SCREEN_EVERY: u64 = 13;
const TEST_TIMEOUT: Duration = Duration::from_secs(900);

/// Forwards one direction: a delay, then the bandwidth cap. The bounded
/// queue pushes back on the sender like a full router buffer.
async fn shape(mut from: tokio::net::tcp::OwnedReadHalf, mut to: tokio::net::tcp::OwnedWriteHalf) {
    let (tx, mut rx) = mpsc::channel::<(Instant, Vec<u8>)>(ROUTER_QUEUE_CHUNKS);
    let reader = tokio::spawn(async move {
        let mut buffer = vec![0_u8; SHAPER_CHUNK];
        loop {
            let Ok(n) = from.read(&mut buffer).await else { return };
            if n == 0
                || tx.send((Instant::now() + ONE_WAY_DELAY, buffer[..n].to_vec())).await.is_err()
            {
                return;
            }
        }
    });
    let mut link_free = Instant::now();
    while let Some((due, bytes)) = rx.recv().await {
        // Network simulation: the link is busy until `link_free`.
        let start = due.max(link_free);
        link_free = start + Duration::from_secs_f64(bytes.len() as f64 / BYTES_PER_SECOND);
        tokio::time::sleep_until(link_free.into()).await;
        if to.write_all(&bytes).await.is_err() {
            break;
        }
    }
    reader.abort();
    let _ = to.shutdown().await;
}

async fn start_shaper(upstream: std::net::SocketAddr) -> std::net::SocketAddr {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    tokio::spawn(async move {
        while let Ok((downstream, _)) = listener.accept().await {
            let Ok(upstream) = TcpStream::connect(upstream).await else { continue };
            let _ = downstream.set_nodelay(true);
            let _ = upstream.set_nodelay(true);
            let (down_read, down_write) = downstream.into_split();
            let (up_read, up_write) = upstream.into_split();
            tokio::spawn(shape(down_read, up_write));
            tokio::spawn(shape(up_read, down_write));
        }
    });
    address
}

fn b64(bytes: &[u8]) -> String {
    base64::engine::general_purpose::STANDARD.encode(bytes)
}

fn unb64(text: &str) -> Vec<u8> {
    base64::engine::general_purpose::STANDARD.decode(text).unwrap()
}

/// The scripted mux server on the daemon's mux socket.
async fn run_mux_server(listener: UnixListener, mut stop: oneshot::Receiver<()>) {
    let (socket, _) = listener.accept().await.unwrap();
    let (read, mut write) = socket.into_split();
    let (lines_tx, mut lines_rx) = mpsc::channel::<Vec<u8>>(64);
    let writer = tokio::spawn(async move {
        while let Some(line) = lines_rx.recv().await {
            if write.write_all(&line).await.is_err() {
                return;
            }
        }
    });
    let line = |value: Value| {
        let mut bytes = serde_json::to_vec(&value).unwrap();
        bytes.push(b'\n');
        bytes
    };
    // Surface 1: a flood of numbered lines.
    let flood_tx = lines_tx.clone();
    let flood = tokio::spawn(async move {
        let filler = vec![b'x'; FLOOD_LINE_BYTES - 8];
        for counter in 0_u64.. {
            let mut data = counter.to_be_bytes().to_vec();
            data.extend_from_slice(&filler);
            let event = line(json!({"event": "output", "surface": 1, "data": b64(&data)}));
            if flood_tx.send(event).await.is_err() {
                return;
            }
        }
    });
    // Surface 2: echoes, bursts and read-screen replies, numbered by `g`.
    let mut reader = BufReader::new(read);
    let mut request = Vec::new();
    let mut g = 0_u64;
    let stress = std::env::var("ECHO_LANE_E2E_PLAIN").as_deref() != Ok("1");
    loop {
        request.clear();
        tokio::select! {
            _ = &mut stop => break,
            read = reader.read_until(b'\n', &mut request) => {
                if read.unwrap_or(0) == 0 {
                    break;
                }
            }
        }
        let value: Value = serde_json::from_slice(&request).unwrap();
        match value["cmd"].as_str() {
            Some("send") if value["surface"] == 2 => {
                let bytes = unb64(value["bytes"].as_str().unwrap());
                let key = u64::from_be_bytes(bytes[..8].try_into().unwrap());
                g += 1;
                let echo = json!({"event": "output", "surface": 2, "g": g, "data": b64(&bytes)});
                lines_tx.send(line(echo)).await.unwrap();
                if stress && key % BURST_EVERY == BURST_EVERY - 1 {
                    // Past the 64 KiB credit: these lines leave Interactive.
                    for _ in 0..6 {
                        g += 1;
                        let burst = vec![b'b'; 20 * 1024];
                        let event =
                            json!({"event": "output", "surface": 2, "g": g, "data": b64(&burst)});
                        lines_tx.send(line(event)).await.unwrap();
                    }
                }
                if key % 4 == 1 {
                    g += 1;
                    let event = json!({"event": "scroll-changed", "surface": 2, "g": g});
                    lines_tx.send(line(event)).await.unwrap();
                }
                if stress && key % 9 == 4 {
                    g += 1;
                    let event = json!({"event": "loopback-data", "stream": 9, "g": g, "data": ""});
                    lines_tx.send(line(event)).await.unwrap();
                }
            }
            Some("read-screen") => {
                g += 1;
                let reply = json!({"id": value["id"], "ok": true, "g": g});
                lines_tx.send(line(reply)).await.unwrap();
            }
            _ => {}
        }
    }
    flood.abort();
    drop(lines_tx);
    let _ = writer.await;
}

struct Metrics {
    p50: Duration,
    p95: Duration,
    p99: Duration,
    flood_lines: u64,
}

/// The local mux client on the bridge socket.
async fn run_client(socket: UnixStream) -> Metrics {
    let (read, mut write) = socket.into_split();
    let (echo_tx, mut echo_rx) = mpsc::unbounded_channel::<(u64, Instant)>();
    let flood_seen = Arc::new(std::sync::atomic::AtomicU64::new(0));
    let flood_counter = flood_seen.clone();
    let reader = tokio::spawn(async move {
        let mut reader = BufReader::new(read);
        let mut line = Vec::new();
        let mut next_flood = 0_u64;
        let mut last_g = 0_u64;
        loop {
            line.clear();
            if reader.read_until(b'\n', &mut line).await.unwrap_or(0) == 0 {
                return next_flood;
            }
            let value: Value = serde_json::from_slice(&line).unwrap();
            if let Some(g) = value["g"].as_u64() {
                assert!(g > last_g, "surface-2 line or reply {g} arrived after {last_g}");
                last_g = g;
            }
            if value["event"] == "output" && value["surface"] == 1 {
                let data = unb64(value["data"].as_str().unwrap());
                let counter = u64::from_be_bytes(data[..8].try_into().unwrap());
                assert_eq!(counter, next_flood, "surface-1 output out of order or lost");
                next_flood += 1;
                flood_counter.store(next_flood, std::sync::atomic::Ordering::Relaxed);
            } else if value["event"] == "output" && value["surface"] == 2 {
                let data = unb64(value["data"].as_str().unwrap());
                if data.len() == 8 {
                    let key = u64::from_be_bytes(data[..8].try_into().unwrap());
                    let _ = echo_tx.send((key, Instant::now()));
                }
            }
        }
    });
    let mut latencies = Vec::new();
    let mut request_id = 1_000_000_u64;
    for key in 0..KEYSTROKES {
        let send = json!({
            "id": key + 1, "cmd": "send", "surface": 2,
            "bytes": b64(&key.to_be_bytes()), "no_reply": true,
        });
        let mut bytes = serde_json::to_vec(&send).unwrap();
        bytes.push(b'\n');
        let started = Instant::now();
        write.write_all(&bytes).await.unwrap();
        let (echoed, at) =
            tokio::time::timeout(Duration::from_secs(60), echo_rx.recv()).await.unwrap().unwrap();
        assert_eq!(echoed, key, "keystrokes echoed out of order");
        latencies.push(at - started);
        if key % READ_SCREEN_EVERY == 0 {
            request_id += 1;
            let mut read_screen =
                serde_json::to_vec(&json!({"id": request_id, "cmd": "read-screen", "surface": 2}))
                    .unwrap();
            read_screen.push(b'\n');
            write.write_all(&read_screen).await.unwrap();
        }
        // Now and then a gap longer than the echo window.
        let stress = std::env::var("ECHO_LANE_E2E_PLAIN").as_deref() != Ok("1");
        let gap = if stress && key % 11 == 10 { Duration::from_millis(700) } else { KEY_GAP };
        tokio::time::sleep(gap).await;
    }
    drop(write);
    assert!(!reader.is_finished(), "the client's reader stopped early");
    reader.abort();
    let flood_lines = flood_seen.load(std::sync::atomic::Ordering::Relaxed);
    latencies.sort();
    let at = |q: f64| latencies[((latencies.len() - 1) as f64 * q) as usize];
    Metrics { p50: at(0.5), p95: at(0.95), p99: at(0.99), flood_lines }
}

#[tokio::test(flavor = "current_thread")]
async fn keystroke_echo_while_another_pane_floods() {
    tokio::task::LocalSet::new()
        .run_until(async {
            tokio::time::timeout(TEST_TIMEOUT, async {
                let dir = tempdir().unwrap();
                let mux_path = dir.path().join("mux.sock");
                let bridge_path = dir.path().join("bridge.sock");
                let mux_listener = UnixListener::bind(&mux_path).unwrap();
                let (stop_mux, mux_stop) = oneshot::channel();
                let mux_server = tokio::task::spawn_local(run_mux_server(mux_listener, mux_stop));

                let auth = AuthDatabase::load_or_create(dir.path(), "echo-lane-e2e", false).unwrap();
                let (daemon, mut accepted) = RemoteDaemon::new(auth.clone(), SessionLimits::default());
                let server = serve_direct_websocket(
                    daemon,
                    "127.0.0.1:0".parse().unwrap(),
                    MAXIMUM_FRAME_BYTES,
                    false,
                )
                .await
                .unwrap();
                let shaped = start_shaper(server.local_addr()).await;
                let endpoint = Url::parse(&format!("ws://{shaped}/v1/link")).unwrap();
                let invitation =
                    auth.create_invitation(Duration::from_secs(60), Vec::new()).await.unwrap();
                let invitation_secret = invitation.secret_bytes().unwrap();
                let approver = tokio::spawn({
                    let auth = auth.clone();
                    async move {
                        let pending = auth.wait_for_pending(Duration::from_secs(10)).await.unwrap();
                        auth.approve(&pending[0].invitation_id).await.unwrap();
                    }
                });
                let session = SessionId([0x5e; 16]);
                let group = DirectWebSocketProvider::new(MAXIMUM_FRAME_BYTES)
                    .connect(ConnectRequest {
                        endpoint,
                        session,
                        // One carrier for every lane, as a relay route has.
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
                        device_name: "echo-lane-e2e".into(),
                        session,
                        lane_policy: LanePolicy::Single,
                        limits: SessionLimits::default(),
                        reconnect: ReconnectPolicy::default(),
                    },
                )
                .await
                .unwrap();
                approver.await.unwrap();
                let daemon_client = accepted.recv().await.unwrap();
                let services =
                    DaemonServices::new(WorkspaceService::new(), Some(mux_path.clone()));
                let service_task = tokio::task::spawn_local({
                    let services = services.clone();
                    async move { services.serve_client(daemon_client).await }
                });
                let multiplexer = ServiceMultiplexer::new(client.clone(), EndpointRole::Client);
                let bridge_listener = UnixListener::bind(&bridge_path).unwrap();
                let (stop_bridge, bridge_stop) = oneshot::channel();
                let bridge = tokio::task::spawn_local({
                    let multiplexer = multiplexer.clone();
                    async move { serve_mux_bridge(multiplexer, &bridge_listener, bridge_stop).await }
                });
                let socket = UnixStream::connect(&bridge_path).await.unwrap();
                // Let the flood fill every queue on the path first.
                tokio::time::sleep(Duration::from_secs(3)).await;
                let metrics = run_client(socket).await;
                let mode = match std::env::var("CMUX_REMOTE_MUX_ECHO_LANE").as_deref() {
                    Ok("0") => "off",
                    _ => "on",
                };
                println!(
                    "{{\"echo_lane\":\"{mode}\",\"keystrokes\":{KEYSTROKES},\"p50_ms\":{:.1},\"p95_ms\":{:.1},\"p99_ms\":{:.1},\"flood_lines\":{}}}",
                    metrics.p50.as_secs_f64() * 1e3,
                    metrics.p95.as_secs_f64() * 1e3,
                    metrics.p99.as_secs_f64() * 1e3,
                    metrics.flood_lines
                );
                if mode == "on" {
                    // Off, every echo waits behind the flood (seconds here).
                    assert!(
                        metrics.p50 < Duration::from_millis(1000),
                        "echo lane did not take effect: p50 {:?}",
                        metrics.p50
                    );
                }
                let _ = stop_mux.send(());
                let _ = stop_bridge.send(());
                let _ = bridge.await;
                multiplexer.shutdown().await;
                client.close().await.unwrap();
                service_task.abort();
                let _ = service_task.await;
                mux_server.abort();
                server.shutdown().await.unwrap();
            })
            .await
            .expect("echo lane E2E timed out");
        })
        .await;
}
