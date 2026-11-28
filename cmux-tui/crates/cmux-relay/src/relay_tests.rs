use std::net::SocketAddr;

use futures_util::{SinkExt, StreamExt};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;
use tokio::task::JoinHandle;
use tokio::time::timeout;
use tokio_tungstenite::tungstenite::Message as ClientMessage;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tokio_tungstenite::tungstenite::http::{HeaderValue, header::ORIGIN};
use tokio_tungstenite::{MaybeTlsStream, WebSocketStream, connect_async};

use super::*;

const RELAY_CONTROL_CONFORMANCE: &str =
    include_str!("../../cmux-remote-protocol/tests/fixtures/relay-control-v1.jsonl");

#[test]
fn relay_control_matches_shared_wire_fixture() {
    for encoded in RELAY_CONTROL_CONFORMANCE.lines() {
        let control: RelayControl = serde_json::from_str(encoded).unwrap();
        assert_eq!(serde_json::to_string(&control).unwrap(), encoded);
    }
}

type TestSocket = WebSocketStream<MaybeTlsStream<TcpStream>>;

struct TestServer {
    address: SocketAddr,
    relay: Relay,
    task: JoinHandle<()>,
}

impl TestServer {
    async fn start(config: RelayConfig) -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let relay = Relay::new(config).unwrap();
        let (listener, router) = relay.server_parts(listener);
        let task = tokio::spawn(async move {
            axum::serve(listener, router).await.unwrap();
        });
        Self { address, relay, task }
    }

    async fn connect(&self) -> TestSocket {
        let url = format!("ws://{}/v1/relay", self.address);
        connect_async(url).await.unwrap().0
    }
}

impl Drop for TestServer {
    fn drop(&mut self) {
        self.task.abort();
    }
}

async fn send_control(socket: &mut TestSocket, control: RelayControl) {
    let text = serde_json::to_string(&control).unwrap();
    socket.send(ClientMessage::Text(text.into())).await.unwrap();
}

async fn receive_control(socket: &mut TestSocket) -> RelayControl {
    loop {
        let message = timeout(Duration::from_secs(2), socket.next())
            .await
            .expect("timed out waiting for relay control")
            .expect("relay closed before control response")
            .unwrap();
        match message {
            ClientMessage::Text(text) => return serde_json::from_str(&text).unwrap(),
            ClientMessage::Ping(bytes) => {
                socket.send(ClientMessage::Pong(bytes)).await.unwrap();
            }
            other => panic!("expected relay control text, got {other:?}"),
        }
    }
}

async fn receive_binary(socket: &mut TestSocket) -> Bytes {
    loop {
        let message = timeout(Duration::from_secs(2), socket.next())
            .await
            .expect("timed out waiting for relay binary frame")
            .expect("relay closed before binary frame")
            .unwrap();
        match message {
            ClientMessage::Binary(bytes) => return bytes,
            ClientMessage::Ping(bytes) => {
                socket.send(ClientMessage::Pong(bytes)).await.unwrap();
            }
            other => panic!("expected opaque binary frame, got {other:?}"),
        }
    }
}

async fn register_open_daemon(server: &TestServer, slot: &str) -> TestSocket {
    let mut daemon = server.connect().await;
    send_control(
        &mut daemon,
        RelayControl::Register {
            protocol: REMOTE_PROTOCOL_VERSION,
            slot: slot.into(),
            ticket: format!("{slot}-daemon-ticket"),
        },
    )
    .await;
    assert!(matches!(receive_control(&mut daemon).await, RelayControl::Registered { .. }));
    daemon
}

async fn open_client_control(
    server: &TestServer,
    daemon: &mut TestSocket,
    slot: &str,
    lane: &str,
    generation: u64,
) -> TestSocket {
    let mut client = server.connect().await;
    send_control(
        &mut client,
        RelayControl::Connect {
            protocol: REMOTE_PROTOCOL_VERSION,
            slot: slot.into(),
            ticket: format!("{slot}-client-ticket"),
            lane: LaneToken(lane.into()),
            generation,
            accepts_parked: false,
            grant: None,
            inline: false,
        },
    )
    .await;
    assert!(matches!(receive_control(&mut client).await, RelayControl::Allocated { .. }));
    assert!(matches!(receive_control(daemon).await, RelayControl::Incoming { .. }));
    client
}

fn provider_ticket(
    config: &RelayConfig,
    permission: RelayPermission,
    lane: Option<LaneToken>,
    generation: Option<u64>,
) -> String {
    let issued_at_unix = unix_timestamp(SystemTime::now()).unwrap();
    provider_ticket_expiring_at(config, permission, lane, generation, issued_at_unix + 60)
}

fn provider_ticket_expiring_at(
    config: &RelayConfig,
    permission: RelayPermission,
    lane: Option<LaneToken>,
    generation: Option<u64>,
    expires_at_unix: u64,
) -> String {
    let role = match permission {
        RelayPermission::Register => RelayRole::Daemon,
        RelayPermission::Connect => RelayRole::Client,
        RelayPermission::Join => panic!("join tickets are minted by the relay"),
    };
    let authority = TicketAuthority::hmac_with_issuer(
        config.ticket_secret.clone().unwrap(),
        config.ticket_issuer.clone(),
    )
    .unwrap();
    let issued_at_unix = unix_timestamp(SystemTime::now()).unwrap();
    authority
        .issue(&RelayTicketClaims {
            version: RelayTicketClaims::VERSION,
            issuer: config.ticket_issuer.clone(),
            permission,
            role,
            slot: "slot-a".into(),
            circuit: None,
            lane,
            generation,
            issued_at_unix,
            expires_at_unix,
            grant: None,
            region: None,
        })
        .unwrap()
}

#[tokio::test]
async fn websocket_circuit_registers_pairs_and_forwards_opaque_binary() {
    let server =
        TestServer::start(RelayConfig { allow_open: true, ..RelayConfig::default() }).await;
    let mut daemon_control = server.connect().await;
    send_control(
        &mut daemon_control,
        RelayControl::Register {
            protocol: REMOTE_PROTOCOL_VERSION,
            slot: "slot-a".into(),
            ticket: "daemon-ticket".into(),
        },
    )
    .await;
    assert!(matches!(receive_control(&mut daemon_control).await, RelayControl::Registered { .. }));

    let mut client_control = server.connect().await;
    send_control(
        &mut client_control,
        RelayControl::Connect {
            protocol: REMOTE_PROTOCOL_VERSION,
            slot: "slot-a".into(),
            ticket: "client-ticket".into(),
            lane: LaneToken("interactive".into()),
            generation: 7,
            accepts_parked: false,
            grant: None,
            inline: false,
        },
    )
    .await;
    let RelayControl::Allocated { circuit, lane, generation, join_ticket: client_join_ticket } =
        receive_control(&mut client_control).await
    else {
        panic!("client did not receive circuit allocation");
    };
    assert_eq!(lane, LaneToken("interactive".into()));
    assert_eq!(generation, 7);
    let RelayControl::Incoming {
        circuit: daemon_circuit_id,
        lane: daemon_lane,
        generation: daemon_generation,
        join_ticket: daemon_join_ticket,
    } = receive_control(&mut daemon_control).await
    else {
        panic!("daemon did not receive incoming circuit");
    };
    assert_eq!(daemon_circuit_id, circuit);
    assert_eq!(daemon_lane, lane);
    assert_eq!(daemon_generation, generation);
    assert_ne!(client_join_ticket, daemon_join_ticket);
    assert_ne!(client_join_ticket, "client-ticket");
    assert_ne!(daemon_join_ticket, "daemon-ticket");
    assert!(client_join_ticket.starts_with("o2."));
    assert!(daemon_join_ticket.starts_with("o2."));

    let mut client_circuit = server.connect().await;
    send_control(
        &mut client_circuit,
        RelayControl::Join {
            protocol: REMOTE_PROTOCOL_VERSION,
            slot: "slot-a".into(),
            circuit: circuit.clone(),
            lane: lane.clone(),
            generation,
            ticket: client_join_ticket,
            role: RelayRole::Client,
        },
    )
    .await;
    let mut daemon_circuit = server.connect().await;
    send_control(
        &mut daemon_circuit,
        RelayControl::Join {
            protocol: REMOTE_PROTOCOL_VERSION,
            slot: "slot-a".into(),
            circuit: circuit.clone(),
            lane: lane.clone(),
            generation,
            ticket: daemon_join_ticket,
            role: RelayRole::Daemon,
        },
    )
    .await;
    let ready = RelayControl::Ready { circuit: circuit.clone(), lane: lane.clone(), generation };
    assert_eq!(receive_control(&mut client_circuit).await, ready);
    assert_eq!(
        receive_control(&mut daemon_circuit).await,
        RelayControl::Ready { circuit: circuit.clone(), lane, generation }
    );

    client_circuit
        .send(ClientMessage::Binary(Bytes::from_static(b"client ciphertext")))
        .await
        .unwrap();
    assert_eq!(receive_binary(&mut daemon_circuit).await, Bytes::from_static(b"client ciphertext"));
    daemon_circuit
        .send(ClientMessage::Binary(Bytes::from_static(b"daemon ciphertext")))
        .await
        .unwrap();
    assert_eq!(receive_binary(&mut client_circuit).await, Bytes::from_static(b"daemon ciphertext"));

    assert_eq!(
        server.relay.health().await,
        HealthSnapshot { status: "ok", daemon_slots: 1, pending_circuits: 0, ready_circuits: 1 }
    );

    daemon_circuit
        .feed(ClientMessage::Binary(Bytes::from_static(b"final authorization rejection")))
        .await
        .unwrap();
    daemon_circuit.feed(ClientMessage::Close(None)).await.unwrap();
    daemon_circuit.flush().await.unwrap();
    assert_eq!(
        receive_binary(&mut client_circuit).await,
        Bytes::from_static(b"final authorization rejection"),
        "the relay dropped data queued before its peer disconnected"
    );
    let error = receive_control(&mut client_circuit).await;
    assert!(matches!(
        error,
        RelayControl::Error { code, retryable: true, .. } if code == "peer-disconnected"
    ));
}

/// A register ticket signed with the relay's secret, with explicit times and claims version.
/// `signed_issued_at` is the issue time the signature covers; the payload carries
/// `issued_at_unix`, so a different value is a tampered ticket.
fn signed_register_ticket(
    config: &RelayConfig,
    version: u8,
    issued_at_unix: u64,
    signed_issued_at: u64,
    expires_at_unix: u64,
) -> String {
    use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
    use hmac::{Hmac, Mac};
    let claims = serde_json::json!({
        "version": version,
        "issuer": config.ticket_issuer,
        "permission": "register",
        "role": "daemon",
        "slot": "slot-a",
        "circuit": null,
        "lane": null,
        "generation": null,
        "issued_at_unix": issued_at_unix,
        "expires_at_unix": expires_at_unix,
    });
    let payload = URL_SAFE_NO_PAD.encode(serde_json::to_vec(&claims).unwrap());
    let signing = format!(
        "cmux-relay-ticket-v2\n{version}\n{}\nregister\ndaemon\nslot-a\n\n\n\n{signed_issued_at}\n{expires_at_unix}",
        config.ticket_issuer,
    );
    let mut mac =
        Hmac::<sha2::Sha256>::new_from_slice(config.ticket_secret.as_ref().unwrap()).unwrap();
    mac.update(signing.as_bytes());
    let signature = URL_SAFE_NO_PAD.encode(mac.finalize().into_bytes());
    format!("v2.{payload}.{signature}")
}

/// A client of the relay socket cannot register with a ticket that lives longer than five
/// minutes, was issued more than five minutes ago, is issued in the future past the clock
/// skew, has a tampered issue time, or uses the legacy claims version. A ticket of exactly
/// five minutes registers.
#[tokio::test]
async fn register_tickets_outside_lifetime_skew_version_or_signature_are_refused_on_the_wire() {
    let config = RelayConfig {
        ticket_secret: Some(vec![9; 32]),
        ticket_issuer: "relay.test".into(),
        ..RelayConfig::default()
    };
    let server = TestServer::start(config.clone()).await;
    let now = unix_timestamp(SystemTime::now()).unwrap();
    let max = RelayTicketClaims::MAX_LIFETIME_SECONDS;
    let refused = [
        ("lifetime over five minutes", signed_register_ticket(&config, 2, now, now, now + max + 1)),
        (
            "issued over five minutes ago",
            signed_register_ticket(&config, 2, now - max - 1, now - max - 1, now + 10),
        ),
        (
            "issued past the clock skew",
            signed_register_ticket(&config, 2, now + 120, now + 120, now + 200),
        ),
        ("tampered issue time", signed_register_ticket(&config, 2, now + 1, now, now + 60)),
        ("legacy claims version", signed_register_ticket(&config, 1, now, now, now + 60)),
    ];
    for (case, ticket) in refused {
        let mut socket = server.connect().await;
        send_control(
            &mut socket,
            RelayControl::Register {
                protocol: REMOTE_PROTOCOL_VERSION,
                slot: "slot-a".into(),
                ticket,
            },
        )
        .await;
        let reply = receive_control(&mut socket).await;
        assert!(
            matches!(&reply, RelayControl::Error { code, retryable: false, .. } if code == "invalid-ticket"),
            "{case}: {reply:?}"
        );
    }
    let mut socket = server.connect().await;
    send_control(
        &mut socket,
        RelayControl::Register {
            protocol: REMOTE_PROTOCOL_VERSION,
            slot: "slot-a".into(),
            ticket: signed_register_ticket(&config, 2, now, now, now + max),
        },
    )
    .await;
    let reply = receive_control(&mut socket).await;
    assert!(matches!(reply, RelayControl::Registered { .. }), "five-minute ticket: {reply:?}");
}

#[tokio::test]
async fn hmac_provider_and_join_tickets_enforce_permission_lane_and_generation() {
    let config = RelayConfig {
        ticket_secret: Some(vec![9; 32]),
        ticket_issuer: "relay.test".into(),
        ..RelayConfig::default()
    };
    let server = TestServer::start(config.clone()).await;
    let connect_ticket = provider_ticket(
        &config,
        RelayPermission::Connect,
        Some(LaneToken("interactive".into())),
        Some(19),
    );

    let mut wrong_provider = server.connect().await;
    send_control(
        &mut wrong_provider,
        RelayControl::Register {
            protocol: REMOTE_PROTOCOL_VERSION,
            slot: "slot-a".into(),
            ticket: connect_ticket.clone(),
        },
    )
    .await;
    assert!(matches!(
        receive_control(&mut wrong_provider).await,
        RelayControl::Error { code, retryable: false, .. } if code == "invalid-ticket"
    ));

    let mut daemon_control = server.connect().await;
    send_control(
        &mut daemon_control,
        RelayControl::Register {
            protocol: REMOTE_PROTOCOL_VERSION,
            slot: "slot-a".into(),
            ticket: provider_ticket(&config, RelayPermission::Register, None, None),
        },
    )
    .await;
    assert!(matches!(receive_control(&mut daemon_control).await, RelayControl::Registered { .. }));

    let lane = LaneToken("interactive".into());
    let generation = 19;
    let mut client_control = server.connect().await;
    send_control(
        &mut client_control,
        RelayControl::Connect {
            protocol: REMOTE_PROTOCOL_VERSION,
            slot: "slot-a".into(),
            ticket: connect_ticket,
            lane: lane.clone(),
            generation,
            accepts_parked: false,
            grant: None,
            inline: false,
        },
    )
    .await;
    let RelayControl::Allocated { circuit, join_ticket: client_join_ticket, .. } =
        receive_control(&mut client_control).await
    else {
        panic!("client did not receive allocation");
    };
    let RelayControl::Incoming { join_ticket: daemon_join_ticket, .. } =
        receive_control(&mut daemon_control).await
    else {
        panic!("daemon did not receive incoming circuit");
    };
    assert!(client_join_ticket.starts_with("v2."));
    assert!(daemon_join_ticket.starts_with("v2."));
    assert_ne!(client_join_ticket, daemon_join_ticket);

    let mut wrong_join = server.connect().await;
    send_control(
        &mut wrong_join,
        RelayControl::Join {
            protocol: REMOTE_PROTOCOL_VERSION,
            slot: "slot-a".into(),
            circuit: circuit.clone(),
            lane: LaneToken("bulk".into()),
            generation,
            ticket: client_join_ticket.clone(),
            role: RelayRole::Client,
        },
    )
    .await;
    assert!(matches!(
        receive_control(&mut wrong_join).await,
        RelayControl::Error { code, retryable: false, .. }
            if code == "circuit-route-mismatch"
    ));

    let mut client_circuit = server.connect().await;
    send_control(
        &mut client_circuit,
        RelayControl::Join {
            protocol: REMOTE_PROTOCOL_VERSION,
            slot: "slot-a".into(),
            circuit: circuit.clone(),
            lane: lane.clone(),
            generation,
            ticket: client_join_ticket,
            role: RelayRole::Client,
        },
    )
    .await;
    let mut daemon_circuit = server.connect().await;
    send_control(
        &mut daemon_circuit,
        RelayControl::Join {
            protocol: REMOTE_PROTOCOL_VERSION,
            slot: "slot-a".into(),
            circuit: circuit.clone(),
            lane: lane.clone(),
            generation,
            ticket: daemon_join_ticket,
            role: RelayRole::Daemon,
        },
    )
    .await;
    let ready = RelayControl::Ready { circuit, lane, generation };
    assert_eq!(receive_control(&mut client_circuit).await, ready);
    assert_eq!(receive_control(&mut daemon_circuit).await, ready);
}

#[tokio::test]
async fn health_endpoint_is_available_without_a_websocket_upgrade() {
    let server =
        TestServer::start(RelayConfig { allow_open: true, ..RelayConfig::default() }).await;
    let mut stream = TcpStream::connect(server.address).await.unwrap();
    stream
        .write_all(format!("GET /healthz HTTP/1.1\r\nHost: {}\r\n\r\n", server.address).as_bytes())
        .await
        .unwrap();
    let mut response = Vec::new();
    timeout(Duration::from_secs(2), stream.read_to_end(&mut response)).await.unwrap().unwrap();
    let response = String::from_utf8(response).unwrap();
    assert!(response.starts_with("HTTP/1.1 200 OK"));
    assert!(response.to_ascii_lowercase().contains("connection: close"));
    assert!(response.contains("\"status\":\"ok\""));
}

#[tokio::test]
async fn concurrent_websocket_count_is_bounded() {
    let config = RelayConfig {
        max_connections: 1,
        ..RelayConfig { allow_open: true, ..RelayConfig::default() }
    };
    let server = TestServer::start(config).await;
    let mut first = server.connect().await;
    send_control(
        &mut first,
        RelayControl::Register {
            protocol: REMOTE_PROTOCOL_VERSION,
            slot: "slot-a".into(),
            ticket: "daemon-ticket".into(),
        },
    )
    .await;
    assert!(matches!(receive_control(&mut first).await, RelayControl::Registered { .. }));
    let url = format!("ws://{}/v1/relay", server.address);
    let error = connect_async(url).await.expect_err("second WebSocket upgrade was admitted");
    assert!(matches!(
        error,
        tokio_tungstenite::tungstenite::Error::Http(response)
            if response.status() == StatusCode::SERVICE_UNAVAILABLE
    ));
}

#[tokio::test]
async fn browser_origin_is_rejected_before_relay_admission() {
    let config = RelayConfig {
        max_connections: 1,
        ..RelayConfig { allow_open: true, ..RelayConfig::default() }
    };
    let server = TestServer::start(config).await;

    for path in ["/v1/relay", "/ws"] {
        let mut request = format!("ws://{}{path}", server.address).into_client_request().unwrap();
        request.headers_mut().insert(ORIGIN, HeaderValue::from_static("https://attacker.invalid"));
        let error =
            connect_async(request).await.expect_err("browser-origin WebSocket was upgraded");
        let tokio_tungstenite::tungstenite::Error::Http(response) = error else {
            panic!("browser-origin rejection was not an HTTP response");
        };
        assert_eq!(response.status(), StatusCode::FORBIDDEN);
        assert!(response.body().as_ref().is_none_or(Vec::is_empty));
    }

    let native = server.connect().await;
    drop(native);
}

#[tokio::test]
async fn partial_http_headers_expire_and_raw_admission_remains_bounded() {
    let config = RelayConfig {
        http_header_timeout: Duration::from_millis(120),
        max_http_connections: 1,
        ..RelayConfig { allow_open: true, ..RelayConfig::default() }
    };
    let server = TestServer::start(config).await;
    let mut slow = TcpStream::connect(server.address).await.unwrap();
    slow.write_all(b"GET /healthz HTTP/1.1\r\nHost:").await.unwrap();

    let mut queued = TcpStream::connect(server.address).await.unwrap();
    queued
        .write_all(format!("GET /healthz HTTP/1.1\r\nHost: {}\r\n\r\n", server.address).as_bytes())
        .await
        .unwrap();
    let mut first_byte = [0_u8; 1];
    assert!(timeout(Duration::from_millis(50), queued.read(&mut first_byte)).await.is_err());

    let mut response = first_byte[..0].to_vec();
    timeout(Duration::from_secs(2), queued.read_to_end(&mut response))
        .await
        .expect("queued connection was not admitted after the header deadline")
        .unwrap();
    assert!(String::from_utf8(response).unwrap().starts_with("HTTP/1.1 200 OK"));

    let mut discarded = Vec::new();
    let slow_result = timeout(Duration::from_secs(1), slow.read_to_end(&mut discarded))
        .await
        .expect("partial HTTP connection remained open past its deadline");
    assert!(slow_result.is_ok() || discarded.is_empty());
}

#[tokio::test]
async fn per_slot_control_socket_quota_prevents_global_capacity_capture() {
    let config = RelayConfig {
        max_control_sockets_per_slot: 2,
        max_pending_circuits_per_slot: 8,
        max_allocations_per_second_per_slot: 8,
        ..RelayConfig { allow_open: true, ..RelayConfig::default() }
    };
    let server = TestServer::start(config).await;
    let mut daemon = register_open_daemon(&server, "slot-a").await;
    let _first = open_client_control(&server, &mut daemon, "slot-a", "interactive", 1).await;

    let mut second = server.connect().await;
    send_control(
        &mut second,
        RelayControl::Connect {
            protocol: REMOTE_PROTOCOL_VERSION,
            slot: "slot-a".into(),
            ticket: "slot-a-client-ticket".into(),
            lane: LaneToken("bulk".into()),
            generation: 1,
            accepts_parked: false,
            grant: None,
            inline: false,
        },
    )
    .await;
    assert!(matches!(
        receive_control(&mut second).await,
        RelayControl::Error { code, retryable: true, .. } if code == "slot-control-limit"
    ));
    assert_eq!(server.relay.health().await.pending_circuits, 1);
}

#[tokio::test]
async fn per_slot_pending_circuit_quota_bounds_repeated_connect() {
    let config = RelayConfig {
        max_pending_circuits_per_slot: 1,
        max_allocations_per_second_per_slot: 8,
        ..RelayConfig { allow_open: true, ..RelayConfig::default() }
    };
    let server = TestServer::start(config).await;
    let mut daemon = register_open_daemon(&server, "slot-a").await;
    let mut client = open_client_control(&server, &mut daemon, "slot-a", "interactive", 1).await;
    send_control(
        &mut client,
        RelayControl::Connect {
            protocol: REMOTE_PROTOCOL_VERSION,
            slot: "slot-a".into(),
            ticket: "slot-a-client-ticket".into(),
            lane: LaneToken("bulk".into()),
            generation: 1,
            accepts_parked: false,
            grant: None,
            inline: false,
        },
    )
    .await;
    assert!(matches!(
        receive_control(&mut client).await,
        RelayControl::Error { code, retryable: true, .. }
            if code == "slot-pending-circuit-limit"
    ));
    assert_eq!(server.relay.health().await.pending_circuits, 1);
}

#[tokio::test]
async fn per_slot_sliding_rate_limit_bounds_repeated_connect() {
    let config = RelayConfig {
        max_pending_circuits_per_slot: 8,
        max_allocations_per_second_per_slot: 1,
        ..RelayConfig { allow_open: true, ..RelayConfig::default() }
    };
    let server = TestServer::start(config).await;
    let mut daemon = register_open_daemon(&server, "slot-a").await;
    let mut client = open_client_control(&server, &mut daemon, "slot-a", "interactive", 1).await;
    send_control(
        &mut client,
        RelayControl::Connect {
            protocol: REMOTE_PROTOCOL_VERSION,
            slot: "slot-a".into(),
            ticket: "slot-a-client-ticket".into(),
            lane: LaneToken("bulk".into()),
            generation: 1,
            accepts_parked: false,
            grant: None,
            inline: false,
        },
    )
    .await;
    assert!(matches!(
        receive_control(&mut client).await,
        RelayControl::Error { code, retryable: true, .. }
            if code == "slot-allocation-rate-limit"
    ));
    assert_eq!(server.relay.health().await.pending_circuits, 1);
}

#[tokio::test]
async fn authenticated_control_socket_has_an_idle_deadline() {
    let config = RelayConfig {
        lease_duration: Duration::from_secs(2),
        control_idle_timeout: Duration::from_millis(50),
        ..RelayConfig { allow_open: true, ..RelayConfig::default() }
    };
    let server = TestServer::start(config).await;
    let mut daemon = register_open_daemon(&server, "slot-a").await;
    assert!(matches!(
        receive_control(&mut daemon).await,
        RelayControl::Error { code, retryable: true, .. } if code == "control-idle-timeout"
    ));
}

/// A Connect to `slot-a` with a fresh Connect ticket: what the relay answers first.
async fn connect_answer(server: &TestServer, config: &RelayConfig) -> RelayControl {
    let lane = LaneToken("interactive".into());
    let ticket = provider_ticket(config, RelayPermission::Connect, Some(lane.clone()), Some(1));
    let mut client = server.connect().await;
    send_control(
        &mut client,
        RelayControl::Connect {
            protocol: REMOTE_PROTOCOL_VERSION,
            slot: "slot-a".into(),
            ticket,
            lane,
            generation: 1,
            accepts_parked: false,
            grant: None,
            inline: false,
        },
    )
    .await;
    receive_control(&mut client).await
}

async fn register(server: &TestServer, ticket: String) -> TestSocket {
    let mut daemon = server.connect().await;
    send_control(
        &mut daemon,
        RelayControl::Register { protocol: REMOTE_PROTOCOL_VERSION, slot: "slot-a".into(), ticket },
    )
    .await;
    assert!(matches!(receive_control(&mut daemon).await, RelayControl::Registered { .. }));
    daemon
}

fn code_of(answer: &RelayControl) -> (&str, bool) {
    match answer {
        RelayControl::Error { code, retryable, .. } => (code.as_str(), *retryable),
        other => panic!("expected a relay error, got {other:?}"),
    }
}

/// F2 (cmuxterm-hq `docs/design/remote-cloud-durability.md`): a daemon whose Register ticket
/// runs out while it still answers (no renewal came: its ticket mint is down) leaves its slot
/// saying why. A Connect reads `credential-unavailable`, retryable, not a bare `slot-offline`
/// that a client shows as still connecting; the slot's next Register clears it.
#[tokio::test]
async fn a_ticket_that_ran_out_unrenewed_answers_connect_with_credential_unavailable() {
    let config = RelayConfig {
        ticket_secret: Some(vec![9; 32]),
        ticket_issuer: "relay.test".into(),
        ..RelayConfig::default()
    };
    let server = TestServer::start(config.clone()).await;
    assert_eq!(code_of(&connect_answer(&server, &config).await), ("slot-offline", true));

    let expires = unix_timestamp(SystemTime::now()).unwrap() + 1;
    let _daemon = register(
        &server,
        provider_ticket_expiring_at(&config, RelayPermission::Register, None, None, expires),
    )
    .await;
    tokio::time::sleep(Duration::from_millis(2_100)).await;
    // Before the sweep, the expired registration already says why.
    assert_eq!(code_of(&connect_answer(&server, &config).await), ("credential-unavailable", true));
    server.relay.cleanup_expired(Instant::now()).await;
    assert_eq!(code_of(&connect_answer(&server, &config).await), ("credential-unavailable", true));

    let _renewed =
        register(&server, provider_ticket(&config, RelayPermission::Register, None, None)).await;
    assert!(matches!(connect_answer(&server, &config).await, RelayControl::Allocated { .. }));
}

/// A daemon that went silent (its lease ran out before its ticket) is plainly offline: the
/// relay cannot tell a dead machine from a dead link, so it names no credential.
#[tokio::test]
async fn a_silent_daemon_whose_lease_ran_out_is_slot_offline() {
    let config = RelayConfig {
        ticket_secret: Some(vec![9; 32]),
        ticket_issuer: "relay.test".into(),
        lease_duration: Duration::from_secs(1),
        ..RelayConfig::default()
    };
    let server = TestServer::start(config.clone()).await;
    let _daemon =
        register(&server, provider_ticket(&config, RelayPermission::Register, None, None)).await;
    tokio::time::sleep(Duration::from_millis(1_200)).await;
    assert_eq!(code_of(&connect_answer(&server, &config).await), ("slot-offline", true));
    server.relay.cleanup_expired(Instant::now()).await;
    assert_eq!(code_of(&connect_answer(&server, &config).await), ("slot-offline", true));
}

async fn open_standby(server: &TestServer, slot: &str) -> TestSocket {
    let mut standby = server.connect().await;
    send_control(
        &mut standby,
        RelayControl::Standby {
            protocol: REMOTE_PROTOCOL_VERSION,
            slot: slot.into(),
            ticket: format!("{slot}-daemon-ticket"),
        },
    )
    .await;
    assert!(matches!(receive_control(&mut standby).await, RelayControl::Registered { .. }));
    standby
}

fn inline_connect(slot: &str, lane: &str, generation: u64) -> RelayControl {
    RelayControl::Connect {
        protocol: REMOTE_PROTOCOL_VERSION,
        slot: slot.into(),
        ticket: format!("{slot}-client-ticket"),
        lane: LaneToken(lane.into()),
        generation,
        accepts_parked: false,
        grant: None,
        inline: true,
    }
}

/// RFD 0039 cut 5: an inline Connect takes the daemon's Standby. Both sockets get `Ready` for
/// one circuit, the registration hears no `Incoming`, and binary frames flow both ways.
#[tokio::test]
async fn inline_connect_pairs_with_a_standby_and_forwards_both_ways() {
    let server =
        TestServer::start(RelayConfig { allow_open: true, ..RelayConfig::default() }).await;
    let mut daemon = register_open_daemon(&server, "slot-a").await;
    let mut standby = open_standby(&server, "slot-a").await;

    send_control(&mut standby, RelayControl::Ping { nonce: 7 }).await;
    assert!(matches!(receive_control(&mut standby).await, RelayControl::Pong { nonce: 7 }));

    let mut client = server.connect().await;
    send_control(&mut client, inline_connect("slot-a", "interactive", 3)).await;
    let RelayControl::Ready { circuit, lane, generation } = receive_control(&mut client).await
    else {
        panic!("inline connect was not answered ready");
    };
    assert_eq!((lane.0.as_str(), generation), ("interactive", 3));
    assert!(matches!(
        receive_control(&mut standby).await,
        RelayControl::Ready { circuit: standby_circuit, .. } if standby_circuit == circuit
    ));
    let health = server.relay.health().await;
    assert_eq!((health.pending_circuits, health.ready_circuits), (0, 1));

    client.send(ClientMessage::Binary(Bytes::from_static(b"client->daemon"))).await.unwrap();
    assert_eq!(receive_binary(&mut standby).await, Bytes::from_static(b"client->daemon"));
    standby.send(ClientMessage::Binary(Bytes::from_static(b"daemon->client"))).await.unwrap();
    assert_eq!(receive_binary(&mut client).await, Bytes::from_static(b"daemon->client"));

    // The registration was never sent Incoming: its next control is the Pong it asked for.
    send_control(&mut daemon, RelayControl::Ping { nonce: 9 }).await;
    assert!(matches!(receive_control(&mut daemon).await, RelayControl::Pong { nonce: 9 }));

    // A standby is taken once: the next inline Connect, with none free, is answered classically.
    let mut second = server.connect().await;
    send_control(&mut second, inline_connect("slot-a", "bulk", 3)).await;
    assert!(matches!(receive_control(&mut second).await, RelayControl::Allocated { .. }));
    assert!(matches!(receive_control(&mut daemon).await, RelayControl::Incoming { .. }));
}

/// With no Standby, an inline Connect falls back to `Allocated` and the daemon's `Incoming`.
#[tokio::test]
async fn inline_connect_without_a_standby_is_allocated() {
    let server =
        TestServer::start(RelayConfig { allow_open: true, ..RelayConfig::default() }).await;
    let mut daemon = register_open_daemon(&server, "slot-a").await;
    let mut client = server.connect().await;
    send_control(&mut client, inline_connect("slot-a", "interactive", 1)).await;
    assert!(matches!(receive_control(&mut client).await, RelayControl::Allocated { .. }));
    assert!(matches!(receive_control(&mut daemon).await, RelayControl::Incoming { .. }));
    assert_eq!(server.relay.health().await.pending_circuits, 1);
}

/// A slot holds at most `MAX_STANDBY_SOCKETS_PER_SLOT` standbys; one more is refused, retryable.
#[tokio::test]
async fn standby_sockets_are_capped_per_slot() {
    let server =
        TestServer::start(RelayConfig { allow_open: true, ..RelayConfig::default() }).await;
    let mut held = Vec::new();
    for _ in 0..inline::MAX_STANDBY_SOCKETS_PER_SLOT {
        held.push(open_standby(&server, "slot-a").await);
    }
    let mut extra = server.connect().await;
    send_control(
        &mut extra,
        RelayControl::Standby {
            protocol: REMOTE_PROTOCOL_VERSION,
            slot: "slot-a".into(),
            ticket: "slot-a-daemon-ticket".into(),
        },
    )
    .await;
    assert_eq!(code_of(&receive_control(&mut extra).await), ("standby-capacity", true));
}

#[tokio::test]
async fn a_standby_socket_pings_before_it_attaches_while_the_hold_lasts() {
    let held = TestServer::start(RelayConfig {
        allow_open: true,
        preattach_hold: Duration::from_secs(30),
        ..RelayConfig::default()
    })
    .await;
    let mut socket = held.connect().await;
    for nonce in [1, 2] {
        send_control(&mut socket, RelayControl::Ping { nonce }).await;
        assert!(
            matches!(receive_control(&mut socket).await, RelayControl::Pong { nonce: n } if n == nonce)
        );
    }
    send_control(
        &mut socket,
        RelayControl::Register {
            protocol: REMOTE_PROTOCOL_VERSION,
            slot: "slot-a".into(),
            ticket: "daemon-ticket".into(),
        },
    )
    .await;
    assert!(matches!(receive_control(&mut socket).await, RelayControl::Registered { .. }));

    // The default, no hold: a Ping first is answered, then the socket is refused.
    let plain = TestServer::start(RelayConfig { allow_open: true, ..RelayConfig::default() }).await;
    let mut socket = plain.connect().await;
    send_control(&mut socket, RelayControl::Ping { nonce: 3 }).await;
    assert!(matches!(receive_control(&mut socket).await, RelayControl::Pong { nonce: 3 }));
    assert_eq!(code_of(&receive_control(&mut socket).await), ("missing-attachment", false));
}
