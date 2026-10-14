#![allow(clippy::result_large_err)] // tungstenite's handshake callback signature
//! cnx-hostd end to end over a local fake signaling server: admission, both
//! transports, and every service.

use std::sync::Arc;
use std::time::Duration;

use bytes::Bytes;
use cnx_hostd::config::{AcpmuxTarget, ServiceConfig};
use cnx_hostd::host::{AnswerContext, IceSource, serve_signaling};
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

/// A stand-in Chief owner: lists the Chief, an owner-and-agents chat and a
/// chat with a paired install; `subscribe` replies, then sends an event for
/// each and a terminal event.
fn fake_chief(dir: &std::path::Path) {
    let listener = tokio::net::UnixListener::bind(dir.join("chief.sock")).unwrap();
    tokio::spawn(async move {
        while let Ok((stream, _)) = listener.accept().await {
            tokio::spawn(async move {
                let (read, mut write) = stream.into_split();
                let mut lines = BufReader::new(read).lines();
                let human = serde_json::json!({"id": "user_local", "kind": "human", "display_name": "A"});
                let chief = serde_json::json!({"id": "agent_mux", "kind": "agent", "display_name": "Chief"});
                let remote = serde_json::json!({"id": "remote_ab", "kind": "human", "display_name": "P"});
                while let Ok(Some(line)) = lines.next_line().await {
                    let request: serde_json::Value = serde_json::from_str(&line).unwrap();
                    let mut out = Vec::new();
                    match request["cmd"].as_str() {
                        Some("conversation-list") => out.push(serde_json::json!({"id": request["id"], "ok": true, "data": {"conversations": [
                            {"id": "conv_CHIEF", "participants": [human, chief]},
                            {"id": "conv_REMOTE", "participants": [human, remote]},
                        ]}})),
                        Some("subscribe") => {
                            out.push(serde_json::json!({"id": request["id"], "ok": true, "data": {}}));
                            for conversation in ["conv_REMOTE", "conv_CHIEF"] {
                                out.push(serde_json::json!({"event": "conversation-typing", "conversation": conversation,
                                    "participant": "agent_mux", "on": true}));
                            }
                            out.push(serde_json::json!({"event": "terminal-registry-changed"}));
                        }
                        _ => out.push(serde_json::json!({"id": request["id"], "ok": true, "data": {"cmd": request["cmd"]}})),
                    }
                    for answer in out {
                        write.write_all(format!("{answer}\n").as_bytes()).await.unwrap();
                    }
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
    let server = FakeSignaling::start(fake).await;
    let sockets = tempfile::tempdir().unwrap();
    let root = tempfile::tempdir().unwrap();
    let outside = tempfile::tempdir().unwrap();
    std::fs::write(root.path().join("notes.md"), "# hello\n").unwrap();
    std::fs::write(outside.path().join("secret"), "nope").unwrap();
    fake_daemon(sockets.path());
    fake_chief(sockets.path());
    let services = ServiceConfig {
        chief_socket: Some(sockets.path().join("chief.sock")),
        tui_socket_dir: sockets.path().to_path_buf(),
        default_session: "main".into(),
        default_socket: None,
        file_roots: vec![root.path().to_path_buf()],
        acpmux: AcpmuxTarget::Fixed { url: fake_acpmux().await, token: Some("acp-token".into()) },
    };
    let mac_id = uuid::Uuid::new_v4().to_string();
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
    let phone =
        SignalingClient::connect(&server.base_url, "user:alice", "team", &uuid::Uuid::new_v4().to_string())
            .await
            .unwrap();
    Fixture {
        _server: server,
        phone,
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

    // daemon never reaches the Chief owner's session.
    let mut owner = link.open("daemon", serde_json::json!({"session": "cmux-chief-c39c6f72"})).await.unwrap();
    assert_eq!(drain(&mut owner).await.1, "bad_request");

    // chief: scoped to the owner's agent conversations, both ways.
    let mut chief = link.open("chief", serde_json::json!({})).await.unwrap();
    chief
        .send(Bytes::from_static(
            b"{\"id\":\"c1\",\"cmd\":\"conversation-list\"}\n{\"id\":\"c2\",\"cmd\":\"conversation-snapshot\",\"conversation\":\"conv_REMOTE\",\"tail\":1}\n",
        ))
        .await
        .unwrap();
    let mut chief_buffer = Vec::new();
    let mut seen = Vec::new();
    for _ in 0..2 {
        seen.push(next_line(&mut chief, &mut chief_buffer).await);
    }
    let list = seen.iter().find(|v| v["id"] == "c1").expect("list reply");
    assert_eq!(list["data"]["conversations"].as_array().unwrap().len(), 1);
    assert_eq!(list["data"]["conversations"][0]["id"], "conv_CHIEF");
    let refused = seen.iter().find(|v| v["id"] == "c2").expect("refusal");
    assert_eq!(refused["error_code"], "forbidden");
    chief
        .send(Bytes::from_static(
            b"{\"id\":\"c3\",\"cmd\":\"conversation-snapshot\",\"conversation\":\"conv_CHIEF\",\"tail\":1}\n{\"id\":\"c4\",\"cmd\":\"subscribe\"}\n{\"id\":\"c5\",\"cmd\":\"conversation-agent-token\",\"participant\":\"agent_mux\"}\n",
        ))
        .await
        .unwrap();
    let mut rest = Vec::new();
    for _ in 0..4 {
        rest.push(next_line(&mut chief, &mut chief_buffer).await);
    }
    assert_eq!(rest.iter().find(|v| v["id"] == "c3").unwrap()["data"]["cmd"], "conversation-snapshot");
    assert_eq!(rest.iter().find(|v| v["id"] == "c5").unwrap()["error_code"], "forbidden");
    let events: Vec<_> = rest.iter().filter(|v| v.get("event").is_some()).collect();
    assert_eq!(events.len(), 1, "{rest:?}");
    assert_eq!(events[0]["conversation"], "conv_CHIEF");

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
