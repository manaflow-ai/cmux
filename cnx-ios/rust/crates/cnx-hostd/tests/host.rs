#![allow(clippy::result_large_err)] // tungstenite's handshake callback signature
//! cnx-hostd end to end over a local fake signaling server: admission, both
//! transports, and every service.

use std::sync::Arc;
use std::time::Duration;

use bytes::Bytes;
use cnx_hostd::config::{AcpmuxTarget, ServiceConfig};
use cnx_hostd::control::Event;
use cnx_hostd::host::{AnswerContext, IceSource, serve_signaling};
use cnx_hostd::pairing::{DeniedDevice, DeviceTrust, Pairing, TrustedDevice, challenge_message};
use cnx_link::testing::{FakeOptions, FakeSignaling};
use cnx_link::{
    Channel, ChannelEvent, Connected, DialError, DialOptions, LinkConfig, SignalingClient, TransportKind,
};
use futures_util::{SinkExt, StreamExt};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};

struct Fixture {
    _server: FakeSignaling,
    _dirs: Vec<tempfile::TempDir>,
    phone: SignalingClient,
    phone_id: String,
    /// Pairing on: the app's `devices` line and the events hostd emitted.
    trust: Option<tokio::sync::watch::Sender<Option<DeviceTrust>>>,
    events: Option<tokio::sync::Mutex<tokio::sync::mpsc::UnboundedReceiver<Event>>>,
    mac_id: String,
    root: std::path::PathBuf,
    outside: std::path::PathBuf,
}

fn options() -> DialOptions {
    DialOptions { include_loopback: true, timeout: Duration::from_secs(20), ..DialOptions::default() }
}

/// A stand-in cmux-tui session socket: answers each request line with
/// `{"id":..,"ok":true,"data":{"cmd":..}}`.
fn fake_daemon(dir: &std::path::Path) {
    let listener = tokio::net::UnixListener::bind(dir.join("main.sock")).unwrap();
    tokio::spawn(async move {
        while let Ok((stream, _)) = listener.accept().await {
            tokio::spawn(async move {
                let (read, mut write) = stream.into_split();
                let mut lines = BufReader::new(read).lines();
                while let Ok(Some(line)) = lines.next_line().await {
                    let request: serde_json::Value = serde_json::from_str(&line).unwrap();
                    let answer =
                        serde_json::json!({"id": request["id"], "ok": true, "data": {"cmd": request["cmd"]}});
                    write.write_all(format!("{answer}\n").as_bytes()).await.unwrap();
                }
            });
        }
    });
}

/// A stand-in acpmux listener: requires the bearer token, echoes text.
async fn fake_acpmux() -> String {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("ws://{}/", listener.local_addr().unwrap());
    tokio::spawn(async move {
        while let Ok((stream, _)) = listener.accept().await {
            tokio::spawn(async move {
                let check = |request: &tokio_tungstenite::tungstenite::handshake::server::Request,
                             response: tokio_tungstenite::tungstenite::handshake::server::Response| {
                    let ok = request.headers().get("authorization").is_some_and(|v| v == "Bearer acp-token");
                    if ok {
                        Ok(response)
                    } else {
                        Err(tokio_tungstenite::tungstenite::handshake::server::ErrorResponse::new(None))
                    }
                };
                let Ok(socket) = tokio_tungstenite::accept_hdr_async(stream, check).await else { return };
                let (mut sink, mut source) = socket.split();
                while let Some(Ok(message)) = source.next().await {
                    if let tokio_tungstenite::tungstenite::Message::Text(text) = message {
                        let reply = format!("{{\"echo\":{text}}}");
                        sink.send(tokio_tungstenite::tungstenite::Message::Text(reply.into())).await.unwrap();
                    }
                }
            });
        }
    });
    url
}

async fn fixture(fake: FakeOptions) -> Fixture {
    fixture_with(fake, false).await
}

async fn fixture_with(fake: FakeOptions, pairing: bool) -> Fixture {
    let server = FakeSignaling::start(fake).await;
    let sockets = tempfile::tempdir().unwrap();
    let root = tempfile::tempdir().unwrap();
    let outside = tempfile::tempdir().unwrap();
    std::fs::write(root.path().join("notes.md"), "# hello\n").unwrap();
    std::fs::write(outside.path().join("secret"), "nope").unwrap();
    fake_daemon(sockets.path());
    let services = ServiceConfig {
        tui_socket_dir: sockets.path().to_path_buf(),
        default_session: "main".into(),
        default_socket: None,
        file_roots: vec![root.path().to_path_buf()],
        acpmux: AcpmuxTarget::Fixed { url: fake_acpmux().await, token: Some("acp-token".into()) },
        pairing: None,
    };
    let mut services = services;
    let mac_id = uuid::Uuid::new_v4().to_string();
    let (mut trust, mut events) = (None, None);
    if pairing {
        let (trust_tx, trust_rx) = tokio::sync::watch::channel(None);
        let (events_tx, events_rx) = tokio::sync::mpsc::unbounded_channel();
        services.pairing = Some(Pairing {
            mac_device_id: mac_id.clone(),
            trust: trust_rx,
            emit: Arc::new(move |event| {
                let _ = events_tx.send(event);
            }),
        });
        trust = Some(trust_tx);
        events = Some(tokio::sync::Mutex::new(events_rx));
    }
    let mac = SignalingClient::connect(&server.base_url, "user:alice", "team", &mac_id).await.unwrap();
    tokio::spawn(serve_signaling(
        mac,
        AnswerContext {
            owner_user_id: "alice".into(),
            services: Arc::new(services),
            ice: IceSource::Fixed(Vec::new()),
            include_loopback: true,
            exclude_cgnat: false,
        },
    ));
    let phone_id = uuid::Uuid::new_v4().to_string();
    let phone = SignalingClient::connect(&server.base_url, "user:alice", "team", &phone_id).await.unwrap();
    Fixture {
        _server: server,
        phone,
        phone_id,
        trust,
        events,
        mac_id,
        root: root.path().to_path_buf(),
        outside: outside.path().to_path_buf(),
        _dirs: vec![sockets, root, outside],
    }
}

async fn connect(fixture: &Fixture, kind: TransportKind) -> Result<Connected, DialError> {
    cnx_link::dial::connect(&fixture.phone, &fixture.mac_id, kind, &options(), LinkConfig::default()).await
}

/// Everything the channel delivers until it closes, and the close code.
async fn drain(channel: &mut Channel) -> (Vec<u8>, String) {
    let mut bytes = Vec::new();
    loop {
        match tokio::time::timeout(Duration::from_secs(10), channel.recv()).await.expect("in time") {
            Some(ChannelEvent::Data(data)) => bytes.extend_from_slice(&data),
            Some(ChannelEvent::Closed(info)) => return (bytes, info.code),
            None => return (bytes, "none".into()),
        }
    }
}

async fn next_line(channel: &mut Channel, buffer: &mut Vec<u8>) -> serde_json::Value {
    loop {
        if let Some(newline) = buffer.iter().position(|&b| b == b'\n') {
            let line: Vec<u8> = buffer.drain(..=newline).collect();
            return serde_json::from_slice(&line).unwrap();
        }
        match tokio::time::timeout(Duration::from_secs(10), channel.recv()).await.expect("in time") {
            Some(ChannelEvent::Data(data)) => buffer.extend_from_slice(&data),
            other => panic!("unexpected {other:?}"),
        }
    }
}

async fn exercise_services(fixture: &Fixture, kind: TransportKind) {
    let connected = connect(fixture, kind).await.expect("dial");
    let link = &connected.link;

    // echo
    let mut echo = link.open("echo", serde_json::json!({})).await.unwrap();
    echo.send(Bytes::from_static(b"ping")).await.unwrap();
    assert_eq!(echo.recv().await, Some(ChannelEvent::Data(Bytes::from_static(b"ping"))));

    // daemon: allowed lines reach the socket, denied ones are answered locally,
    // and responses stay whole lines in order.
    let mut daemon = link.open("daemon", serde_json::json!({})).await.unwrap();
    daemon
        .send(Bytes::from_static(
            b"{\"id\":1,\"cmd\":\"identify\"}\n{\"id\":2,\"cmd\":\"new-tab\",\"argv\":[\"sh\"]}\n{\"id\":3,\"cmd\":\"run\"}\n{\"id\":4,",
        ))
        .await
        .unwrap();
    daemon.send(Bytes::from_static(b"\"cmd\":\"list-workspaces\"}\n")).await.unwrap();
    let mut buffer = Vec::new();
    let mut answers = Vec::new();
    for _ in 0..4 {
        answers.push(next_line(&mut daemon, &mut buffer).await);
    }
    answers.sort_by_key(|answer| answer["id"].as_i64());
    assert_eq!(answers[0]["data"]["cmd"], "identify");
    assert_eq!(answers[1]["error_code"], "forbidden");
    assert_eq!(answers[2]["error_code"], "forbidden");
    assert_eq!(answers[3]["data"]["cmd"], "list-workspaces");
    let mut bad_session = link.open("daemon", serde_json::json!({"session": "../etc"})).await.unwrap();
    assert_eq!(drain(&mut bad_session).await.1, "bad_request");

    // file
    let mut file = link
        .open("file", serde_json::json!({"path": fixture.root.join("notes.md").to_str().unwrap()}))
        .await
        .unwrap();
    assert_eq!(drain(&mut file).await, (b"# hello\n".to_vec(), "eof".into()));
    let mut secret = link
        .open("file", serde_json::json!({"path": fixture.outside.join("secret").to_str().unwrap()}))
        .await
        .unwrap();
    assert_eq!(drain(&mut secret).await, (Vec::new(), "forbidden".into()));

    // acpmux: one data frame per WebSocket message.
    let mut acp = link.open("acpmux", serde_json::json!({})).await.unwrap();
    acp.send(Bytes::from_static(br#"{"jsonrpc":"2.0","id":1,"method":"initialize"}"#)).await.unwrap();
    match acp.recv().await {
        Some(ChannelEvent::Data(data)) => {
            let value: serde_json::Value = serde_json::from_slice(&data).unwrap();
            assert_eq!(value["echo"]["method"], "initialize");
        }
        other => panic!("unexpected {other:?}"),
    }

    // default deny
    let mut shell = link.open("shell", serde_json::json!({})).await.unwrap();
    assert_eq!(drain(&mut shell).await.1, "unknown_service");

    link.close("done");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn services_over_webrtc() {
    let fixture = fixture(FakeOptions::default()).await;
    exercise_services(&fixture, TransportKind::WebRtc).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn services_over_wireguard() {
    let fixture = fixture(FakeOptions::default()).await;
    exercise_services(&fixture, TransportKind::WireGuard).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn services_over_the_wireguard_relay() {
    let fixture = fixture(FakeOptions { strip_wg_endpoints: true, ..FakeOptions::default() }).await;
    exercise_services(&fixture, TransportKind::WireGuard).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn dials_without_a_stamped_user_are_refused() {
    let fixture = fixture(FakeOptions { omit_from_user_id: true, ..FakeOptions::default() }).await;
    for kind in [TransportKind::WebRtc, TransportKind::WireGuard] {
        let error = connect(&fixture, kind).await.err().expect("refused");
        assert_eq!(error, DialError::Bye("not_admitted".into()));
    }
}

// ---- Pairing (src/pairing.rs) ----

struct PhoneKeys {
    identity: ring::signature::EcdsaKeyPair,
    identity_hex: String,
    approval_hex: String,
}

fn p256() -> ring::signature::EcdsaKeyPair {
    use ring::signature::{ECDSA_P256_SHA256_FIXED_SIGNING, EcdsaKeyPair};
    let rng = ring::rand::SystemRandom::new();
    let pkcs8 = EcdsaKeyPair::generate_pkcs8(&ECDSA_P256_SHA256_FIXED_SIGNING, &rng).unwrap();
    EcdsaKeyPair::from_pkcs8(&ECDSA_P256_SHA256_FIXED_SIGNING, pkcs8.as_ref(), &rng).unwrap()
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn phone_keys() -> PhoneKeys {
    use ring::signature::KeyPair;
    let identity = p256();
    let identity_hex = hex(identity.public_key().as_ref());
    PhoneKeys { identity, identity_hex, approval_hex: hex(p256().public_key().as_ref()) }
}

fn json_frame(event: Option<ChannelEvent>) -> serde_json::Value {
    match event {
        Some(ChannelEvent::Data(data)) => serde_json::from_slice(&data).unwrap(),
        other => panic!("unexpected {other:?}"),
    }
}

/// Opens `auth`, signs the challenge with `signer`, and returns the channel
/// after the signature went out.
async fn auth(
    link: &cnx_link::Link,
    fixture: &Fixture,
    keys: &PhoneKeys,
    signer: &ring::signature::EcdsaKeyPair,
    action: &str,
) -> Channel {
    let mut channel = link
        .open(
            "auth",
            serde_json::json!({"identityKey": keys.identity_hex, "approvalKey": keys.approval_hex,
                               "name": "Test iPhone", "action": action}),
        )
        .await
        .unwrap();
    let challenge = json_frame(channel.recv().await);
    assert_eq!(challenge["mac"], fixture.mac_id);
    let message = challenge_message(
        &fixture.mac_id,
        &fixture.phone_id,
        challenge["challenge"].as_str().unwrap(),
        &keys.identity_hex,
        &keys.approval_hex,
        action,
    );
    let signature = hex(signer.sign(&ring::rand::SystemRandom::new(), &message).unwrap().as_ref());
    channel.send(Bytes::from(serde_json::json!({"signature": signature}).to_string())).await.unwrap();
    channel
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_token_alone_never_reaches_a_service_and_the_mac_approves_each_phone() {
    let fixture = fixture_with(FakeOptions::default(), true).await;
    let keys = phone_keys();
    let connected = connect(&fixture, TransportKind::WireGuard).await.expect("dial");
    let link = &connected.link;

    // Before auth: every service is refused.
    for service in ["daemon", "acpmux", "file", "echo"] {
        let mut channel = link.open(service, serde_json::json!({})).await.unwrap();
        assert_eq!(drain(&mut channel).await.1, "unpaired", "{service}");
    }

    // A signature by another key proves nothing and asks nobody.
    let mut forged = auth(link, &fixture, &keys, &p256(), "pair").await;
    assert_eq!(drain(&mut forged).await.1, "unpaired");

    // Unknown keys: hostd asks the app, the phone waits, the user allows.
    let mut channel = auth(link, &fixture, &keys, &keys.identity, "pair").await;
    assert_eq!(json_frame(channel.recv().await), serde_json::json!({"pending": true}));
    let request = fixture.events.as_ref().unwrap().lock().await.recv().await.unwrap();
    assert_eq!(
        request,
        Event::PairRequest {
            phone_device_id: fixture.phone_id.clone(),
            name: "Test iPhone".into(),
            identity_key: keys.identity_hex.clone(),
            approval_key: keys.approval_hex.clone(),
        }
    );
    fixture.trust.as_ref().unwrap().send_replace(Some(DeviceTrust {
        devices: vec![TrustedDevice {
            id: fixture.phone_id.clone(),
            identity_key: keys.identity_hex.clone(),
            approval_key: keys.approval_hex.clone(),
        }],
        denied: vec![],
    }));
    assert_eq!(json_frame(channel.recv().await), serde_json::json!({"ok": true}));
    let mut echo = link.open("echo", serde_json::json!({})).await.unwrap();
    echo.send(Bytes::from_static(b"ping")).await.unwrap();
    assert_eq!(echo.recv().await, Some(ChannelEvent::Data(Bytes::from_static(b"ping"))));
    link.close("done");

    // The next link with the same keys passes at once; with a new approval
    // key it asks again.
    let connected = connect(&fixture, TransportKind::WebRtc).await.expect("dial");
    let mut channel = auth(&connected.link, &fixture, &keys, &keys.identity, "pair").await;
    assert_eq!(json_frame(channel.recv().await), serde_json::json!({"ok": true}));
    let rotated = PhoneKeys {
        approval_hex: hex(ring::signature::KeyPair::public_key(&p256()).as_ref()),
        ..phone_keys()
    };
    let rotated = PhoneKeys {
        identity: keys.identity,
        identity_hex: keys.identity_hex.clone(),
        approval_hex: rotated.approval_hex,
    };
    let mut channel = auth(&connected.link, &fixture, &rotated, &rotated.identity, "pair").await;
    assert_eq!(json_frame(channel.recv().await), serde_json::json!({"pending": true}));
    assert!(matches!(
        fixture.events.as_ref().unwrap().lock().await.recv().await,
        Some(Event::PairRequest { .. })
    ));

    // Unpair by the paired identity key: the app hears it.
    let mut channel =
        auth(&connected.link, &fixture, &keys_like(&rotated), &rotated.identity, "unpair").await;
    assert_eq!(json_frame(channel.recv().await), serde_json::json!({"ok": true}));
    assert_eq!(
        fixture.events.as_ref().unwrap().lock().await.recv().await,
        Some(Event::Unpaired { phone_device_id: fixture.phone_id.clone() })
    );
}

fn keys_like(keys: &PhoneKeys) -> PhoneKeys {
    PhoneKeys {
        identity: p256(),
        identity_hex: keys.identity_hex.clone(),
        approval_hex: keys.approval_hex.clone(),
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_phone_the_user_refused_is_closed_denied() {
    let fixture = fixture_with(FakeOptions::default(), true).await;
    let keys = phone_keys();
    let connected = connect(&fixture, TransportKind::WireGuard).await.expect("dial");
    let mut channel = auth(&connected.link, &fixture, &keys, &keys.identity, "pair").await;
    assert_eq!(json_frame(channel.recv().await), serde_json::json!({"pending": true}));
    let _ = fixture.events.as_ref().unwrap().lock().await.recv().await;
    fixture.trust.as_ref().unwrap().send_replace(Some(DeviceTrust {
        devices: vec![],
        denied: vec![DeniedDevice { id: fixture.phone_id.clone(), identity_key: keys.identity_hex.clone() }],
    }));
    assert_eq!(drain(&mut channel).await.1, "denied");
    // The next try with the same key is refused at once, without asking.
    let mut again = auth(&connected.link, &fixture, &keys, &keys.identity, "pair").await;
    assert_eq!(drain(&mut again).await.1, "denied");
    assert!(fixture.events.as_ref().unwrap().lock().await.try_recv().is_err());
    let mut daemon = connected.link.open("daemon", serde_json::json!({})).await.unwrap();
    assert_eq!(drain(&mut daemon).await.1, "unpaired");
}
