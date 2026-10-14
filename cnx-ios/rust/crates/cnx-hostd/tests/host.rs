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

#[path = "support/fake_rb_host.rs"]
mod fake_rb_host;

struct Fixture {
    _server: FakeSignaling,
    _dirs: Vec<tempfile::TempDir>,
    phone: SignalingClient,
    mac_id: String,
    root: std::path::PathBuf,
    outside: std::path::PathBuf,
    uploads: std::path::PathBuf,
    browser_launches: Arc<std::sync::atomic::AtomicUsize>,
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
                    let answer = serde_json::json!({"id": request["id"], "ok": true,
                        "data": {"cmd": request["cmd"], "host": request["agent_session"]["host"]}});
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
    let server = FakeSignaling::start(fake).await;
    let sockets = tempfile::tempdir().unwrap();
    let root = tempfile::tempdir().unwrap();
    let outside = tempfile::tempdir().unwrap();
    let uploads = tempfile::tempdir().unwrap();
    std::fs::write(root.path().join("notes.md"), "# hello\n").unwrap();
    std::fs::write(outside.path().join("secret"), "nope").unwrap();
    fake_daemon(sockets.path());
    let browser_launches = Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let services = ServiceConfig {
        tui_socket_dir: sockets.path().to_path_buf(),
        default_session: "main".into(),
        default_socket: None,
        file_roots: vec![root.path().to_path_buf()],
        acpmux: AcpmuxTarget::Fixed { url: fake_acpmux().await, token: Some("acp-token".into()) },
        agent_tab_host: Some("install:mac-test".into()),
        uploads_dir: uploads.path().to_path_buf(),
        upload_max_bytes: 1024 * 1024,
        browser: cnx_hostd::browser::BrowserConfig::new(
            Some(fake_rb_host::launcher(Arc::clone(&browser_launches))),
            4,
        ),
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
        uploads: uploads.path().to_path_buf(),
        browser_launches,
        _dirs: vec![sockets, root, outside, uploads],
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

/// Reads rd stream-carrier frames off a channel.
#[derive(Default)]
struct RdReader(cmux_rd_proto::StreamDeframer);

impl RdReader {
    async fn next(&mut self, channel: &mut Channel) -> (u8, Vec<u8>) {
        loop {
            if let Some(frame) = self.0.next_frame().unwrap() {
                return frame;
            }
            match tokio::time::timeout(Duration::from_secs(10), channel.recv()).await.expect("in time") {
                Some(ChannelEvent::Data(data)) => self.0.extend(&data),
                other => panic!("unexpected {other:?}"),
            }
        }
    }

    /// The next control message, skipping datagrams.
    async fn control(&mut self, channel: &mut Channel) -> serde_json::Value {
        loop {
            let (kind, payload) = self.next(channel).await;
            if kind == cmux_rd_proto::STREAM_CONTROL {
                return serde_json::from_slice(&payload).unwrap();
            }
        }
    }

    async fn datagram(&mut self, channel: &mut Channel) -> Vec<u8> {
        loop {
            let (kind, payload) = self.next(channel).await;
            if kind == cmux_rd_proto::STREAM_DATAGRAM {
                return payload;
            }
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

    // acpmux: a message the link splits (over 256 KiB) arrives whole.
    let big = format!(
        r#"{{"jsonrpc":"2.0","id":2,"method":"session/prompt","params":{{"data":"{}"}}}}"#,
        "a".repeat(600_000)
    );
    acp.send(Bytes::from(big.clone())).await.unwrap();
    let mut echoed = Vec::new();
    while serde_json::from_slice::<serde_json::Value>(&echoed).is_err() {
        match tokio::time::timeout(Duration::from_secs(10), acp.recv()).await.expect("in time") {
            Some(ChannelEvent::Data(data)) => echoed.extend_from_slice(&data),
            other => panic!("unexpected {other:?}"),
        }
    }
    let echoed: serde_json::Value = serde_json::from_slice(&echoed).unwrap();
    assert_eq!(echoed["echo"]["params"]["data"].as_str().map(str::len), Some(600_000));

    // daemon: a phone's agent tab gets this Mac's host.
    daemon
        .send(Bytes::from_static(
            b"{\"id\":9,\"cmd\":\"new-conversation-tab\",\"pane\":1,\"agent_session\":{\"harness\":\"claude\"}}\n",
        ))
        .await
        .unwrap();
    let answer = next_line(&mut daemon, &mut buffer).await;
    assert_eq!(answer["data"]["host"], "install:mac-test");

    // upload: the bytes land in a new file, the reply names it.
    let mut upload =
        link.open("upload", serde_json::json!({"name": "../photo.jpg", "size": 5})).await.unwrap();
    upload.send(Bytes::from_static(b"he")).await.unwrap();
    upload.send(Bytes::from_static(b"llo")).await.unwrap();
    let (reply, code) = drain(&mut upload).await;
    assert_eq!(code, "eof");
    let reply: serde_json::Value = serde_json::from_slice(&reply).unwrap();
    let path = std::path::PathBuf::from(reply["path"].as_str().unwrap());
    assert!(path.starts_with(&fixture.uploads), "{path:?}");
    assert_eq!(path.file_name().unwrap(), "photo.jpg");
    assert_eq!(std::fs::read(&path).unwrap(), b"hello");
    // Into a workspace folder: next to acpmux's attachments.
    let mut upload = link
        .open(
            "upload",
            serde_json::json!({"name": "notes.txt", "size": 2, "cwd": fixture.root.to_str().unwrap()}),
        )
        .await
        .unwrap();
    upload.send(Bytes::from_static(b"hi")).await.unwrap();
    let (reply, code) = drain(&mut upload).await;
    assert_eq!(code, "eof");
    let reply: serde_json::Value = serde_json::from_slice(&reply).unwrap();
    let path = std::path::PathBuf::from(reply["path"].as_str().unwrap());
    let root = std::fs::canonicalize(&fixture.root).unwrap();
    assert!(path.starts_with(root.join(".cmux/attachments")), "{path:?}");
    // A folder that is no tab's and outside the roots, or too large: refused.
    let mut outside = link
        .open("upload", serde_json::json!({"name": "x", "size": 1, "cwd": fixture.outside.to_str().unwrap()}))
        .await
        .unwrap();
    assert_eq!(drain(&mut outside).await.1, "forbidden");
    let mut large =
        link.open("upload", serde_json::json!({"name": "x", "size": 2 * 1024 * 1024})).await.unwrap();
    assert_eq!(drain(&mut large).await.1, "too_large");
    // browser: hostd sends the hello, the phone reads the host's carrier.
    let tab = format!("s{}", kind as u8);
    let mut first =
        link.open("browser", serde_json::json!({"tab": tab, "url": "https://example.com/"})).await.unwrap();
    let mut rd = RdReader::default();
    assert_eq!(rd.control(&mut first).await["t"], "welcome");
    assert_eq!(rd.control(&mut first).await["t"], "started");
    assert_eq!(rd.control(&mut first).await["body"]["t"], "rb.opened");
    assert_eq!(rd.control(&mut first).await["body"]["url"], "https://example.com/");
    // Video shards flow.
    rd.datagram(&mut first).await;
    // A file: address never reaches the host; a web one does.
    let mut out = Vec::new();
    for url in ["file:///etc/passwd", "https://example.org/"] {
        let body =
            serde_json::json!({"t": "service", "service": "rb/1", "body": {"t": "rb.navigate", "url": url}});
        cmux_rd_proto::encode_stream_frame(
            cmux_rd_proto::STREAM_CONTROL,
            &serde_json::to_vec(&body).unwrap(),
            &mut out,
        )
        .unwrap();
    }
    first.send(Bytes::from(out)).await.unwrap();
    assert_eq!(rd.control(&mut first).await["body"]["url"], "https://example.org/");
    // A second viewer of the same tab takes the host over, and the page stays.
    let mut second = link.open("browser", serde_json::json!({"tab": tab})).await.unwrap();
    let mut rd2 = RdReader::default();
    assert_eq!(rd2.control(&mut second).await["t"], "welcome");
    rd2.control(&mut second).await;
    rd2.control(&mut second).await;
    assert_eq!(rd2.control(&mut second).await["body"]["url"], "https://example.org/");
    assert_eq!(drain(&mut first).await.1, "replaced");
    assert_eq!(fixture.browser_launches.load(std::sync::atomic::Ordering::SeqCst), 1);
    second.close("eof", "").await;
    let mut refused = link.open("browser", serde_json::json!({"tab": "x", "url": "file:///"})).await.unwrap();
    assert_eq!(drain(&mut refused).await.1, "forbidden");
    let mut bad_tab = link.open("browser", serde_json::json!({"tab": "../x"})).await.unwrap();
    assert_eq!(drain(&mut bad_tab).await.1, "bad_request");

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
