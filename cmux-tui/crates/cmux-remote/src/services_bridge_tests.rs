//! The remote end of the SSH mux bridge says it reads frames
//! (`bridge-hello` with `bridge-frames-v1`), only to a
//! daemon that knows the line, and a real cmux-tui-core daemon serves the far
//! client through it as it serves a direct one.

use std::path::Path;
use std::time::Duration;

use base64::Engine as _;
use cmux_remote_protocol::Service;
use cmux_tui_core::Actor;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use tempfile::tempdir;
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixListener;
use tokio::sync::oneshot;

use super::tests::endpoint_pair;
use super::{BRIDGE_HELLO_LINE, DaemonServices, MuxUploadBudget, open_mux_bridge};
use crate::service::{EndpointRole, ServiceMultiplexer};

const WAIT: Duration = Duration::from_secs(20);

/// A stand-in daemon's side of [`open_mux_bridge`]: answers the `identify`
/// probe (with `bridge-hello-v1` when `takes_hello`), accepts the bridge's
/// connection and, when it takes the hello, reads and answers it. Returns
/// the bridge's connection at its first far-client byte.
pub(super) async fn accept_bridge(
    listener: &UnixListener,
    takes_hello: bool,
) -> tokio::net::UnixStream {
    let (probe, _) = listener.accept().await.unwrap();
    let mut probe = BufReader::new(probe);
    let mut line = String::new();
    probe.read_line(&mut line).await.unwrap();
    let request: Value = serde_json::from_str(&line).unwrap();
    assert_eq!(request["cmd"], "identify", "the probe asks identify: {line}");
    let capabilities: &[&str] = if takes_hello {
        &["attach-streams-v1", "bridge-hello-v1"]
    } else {
        &["attach-streams-v1"]
    };
    let reply = json!({"id": request["id"], "ok": true,
        "data": {"protocol": 6, "capabilities": capabilities}});
    probe.get_mut().write_all(format!("{reply}\n").as_bytes()).await.unwrap();

    let (mut socket, _) = listener.accept().await.unwrap();
    if takes_hello {
        let mut hello = vec![0_u8; BRIDGE_HELLO_LINE.len()];
        socket.read_exact(&mut hello).await.unwrap();
        assert_eq!(hello, BRIDGE_HELLO_LINE);
        let reply = json!({"id": null, "ok": true, "data": {"features": ["bridge-frames-v1"]}});
        socket.write_all(format!("{reply}\n").as_bytes()).await.unwrap();
    }
    socket
}

/// The first line the stand-in daemon gets on the bridge's connection once
/// the bridge has written `first`.
async fn first_line_after_open(takes_hello: bool, first: &[u8]) -> Vec<u8> {
    let directory = tempdir().unwrap();
    let path = directory.path().join("mux.sock");
    let listener = UnixListener::bind(&path).unwrap();
    let daemon = tokio::spawn(async move {
        let socket = accept_bridge(&listener, takes_hello).await;
        let mut line = Vec::new();
        BufReader::new(socket).read_until(b'\n', &mut line).await.unwrap();
        line
    });
    let (mut socket, frames) = open_mux_bridge(&path).await.unwrap();
    assert_eq!(frames, takes_hello);
    socket.writer.write_all(first).await.unwrap();
    let line = tokio::time::timeout(WAIT, daemon).await.unwrap().unwrap();
    assert!(
        socket.reader.buffer().is_empty(),
        "the hello reply is the bridge's, not the far client's"
    );
    line
}

#[tokio::test]
async fn a_daemon_that_takes_the_bridge_hello_gets_it_before_the_far_client() {
    let line = first_line_after_open(true, b"{\"id\":1,\"cmd\":\"client-hello\"}\n").await;
    assert_eq!(line, b"{\"id\":1,\"cmd\":\"client-hello\"}\n");
}

#[tokio::test]
async fn an_older_daemon_never_gets_the_bridge_hello() {
    // Its first line would close the far client's hello window there.
    let line = first_line_after_open(false, b"{\"id\":1,\"cmd\":\"client-hello\"}\n").await;
    assert_eq!(line, b"{\"id\":1,\"cmd\":\"client-hello\"}\n");
}

/// One line-protocol connection: a direct one to the daemon socket or the
/// far client's through the bridge.
struct LineClient {
    reader: BufReader<tokio::net::unix::OwnedReadHalf>,
    writer: tokio::net::unix::OwnedWriteHalf,
    events: Vec<Value>,
}

impl LineClient {
    async fn connect(path: &Path) -> Self {
        let (reader, writer) = tokio::net::UnixStream::connect(path).await.unwrap().into_split();
        Self { reader: BufReader::new(reader), writer, events: Vec::new() }
    }

    async fn next(&mut self) -> Value {
        let mut line = String::new();
        let read = tokio::time::timeout(WAIT, self.reader.read_line(&mut line))
            .await
            .expect("no line before the deadline")
            .unwrap();
        assert_ne!(read, 0, "the connection closed");
        serde_json::from_str(&line).unwrap()
    }

    async fn request(&mut self, request: Value) -> Value {
        self.writer.write_all(format!("{request}\n").as_bytes()).await.unwrap();
        loop {
            let line = self.next().await;
            if line.get("event").is_some() {
                self.events.push(line);
            } else if line["id"] == request["id"] {
                return line;
            }
        }
    }

    async fn event(&mut self, name: &str) -> Value {
        if let Some(at) = self.events.iter().position(|event| event["event"] == name) {
            return self.events.remove(at);
        }
        loop {
            let line = self.next().await;
            if line["event"] == name {
                return line;
            }
            self.events.push(line);
        }
    }

    /// The framed IPC capabilities `identify` lists for this connection.
    async fn ipc_offer(&mut self) -> Vec<String> {
        const IPC: [&str; 4] =
            ["ipc-frames-v2", "attach-streams-v1", "attach-frames-v1", "terminal-output-ring-v1"];
        let reply = self.request(json!({"id": 1, "cmd": "identify"})).await;
        assert_eq!(reply["ok"], true, "{reply}");
        let listed = reply["data"]["capabilities"].as_array().unwrap();
        IPC.iter()
            .filter(|name| listed.iter().any(|value| value == **name))
            .map(|name| (*name).to_string())
            .collect()
    }

    /// The bytes of this attach's `output` events up to and with `end`.
    async fn output_until(&mut self, end: &[u8]) -> Vec<u8> {
        let mut bytes = Vec::new();
        while !bytes.windows(end.len()).any(|window| window == end) {
            let event = self.event("output").await;
            let data = event["data"].as_str().unwrap();
            bytes.extend(base64::engine::general_purpose::STANDARD.decode(data).unwrap());
        }
        bytes
    }
}

/// A real daemon, the remote end of the bridge on its socket and the local
/// end on a bridge socket: the far client's `client-hello` still opens after
/// the bridge's hello, `identify` offers it what a direct client gets but
/// the ring, and an attach flood (LFs, 0xFF) reaches it with the digest a
/// direct attach sees.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_real_daemon_serves_the_far_client_through_the_bridge_as_a_direct_one() {
    let script = "read go; i=0; while [ $i -lt 3000 ]; do printf 'line %d \\377\\n' $i; \
                  i=$((i+1)); done; printf 'FLOOD-END\\n'; exec cat";
    let options = cmux_tui_core::SurfaceOptions {
        command: Some(vec!["/bin/sh".into(), "-c".into(), script.into()]),
        ..Default::default()
    };
    let session = format!("bridge-frames-{}", std::process::id());
    let mux = cmux_tui_core::Mux::new(session, options);
    let surface = mux.new_workspace_as(&Actor::Daemon, None, Some((80, 24))).unwrap().id;
    let socket = cmux_tui_core::server::serve(mux.clone(), None).unwrap();
    // The daemon takes the remote end's hello: its far client may get frames.
    assert!(open_mux_bridge(&socket).await.unwrap().1);

    let (client_endpoint, daemon_endpoint) = endpoint_pair();
    let client_mux = ServiceMultiplexer::new(client_endpoint, EndpointRole::Client);
    let daemon_mux = ServiceMultiplexer::new(daemon_endpoint, EndpointRole::Daemon);
    let remote = tokio::spawn({
        let daemon_mux = daemon_mux.clone();
        let socket = socket.clone();
        async move {
            let incoming = daemon_mux.accept().await.unwrap().unwrap();
            assert_eq!(incoming.service, Service::MuxControl);
            DaemonServices::serve_mux_control_with_budget(
                Some(socket),
                incoming.stream,
                MuxUploadBudget::new(),
            )
            .await
        }
    });
    let directory = tempdir().unwrap();
    let bridge_path = directory.path().join("bridge.sock");
    let bridge_listener = UnixListener::bind(&bridge_path).unwrap();
    let (bridge_shutdown, bridge_stop) = oneshot::channel();
    let bridge = tokio::spawn({
        let client_mux = client_mux.clone();
        async move {
            crate::bridge::serve_mux_bridge(client_mux, &bridge_listener, bridge_stop).await;
        }
    });

    let mut far = LineClient::connect(&bridge_path).await;
    let hello = far.request(json!({"id": 9, "cmd": "client-hello", "role": "main"})).await;
    assert_eq!(hello["ok"], true, "the bridge's hello kept the far client's window open: {hello}");
    let mut direct = LineClient::connect(&socket).await;
    let direct_offer = direct.ipc_offer().await;
    let far_offer = far.ipc_offer().await;
    let without_ring: Vec<_> =
        direct_offer.iter().filter(|name| *name != "terminal-output-ring-v1").cloned().collect();
    assert_eq!(far_offer, without_ring, "a framed bridge gets frames, never the ring");

    for client in [&mut far, &mut direct] {
        let attach =
            client.request(json!({"id": 2, "cmd": "attach-surface", "surface": surface})).await;
        assert_eq!(attach["ok"], true, "{attach}");
        client.event("vt-state").await;
    }
    let sent =
        direct.request(json!({"id": 3, "cmd": "send", "surface": surface, "text": "go\r"})).await;
    assert_eq!(sent["ok"], true, "{sent}");
    let local = direct.output_until(b"FLOOD-END").await;
    let remote_bytes = far.output_until(b"FLOOD-END").await;
    assert!(local.len() > 30_000, "the flood is {} bytes", local.len());
    assert!(local.contains(&0xFF) && local.contains(&b'\n'));
    assert_eq!(
        Sha256::digest(&remote_bytes),
        Sha256::digest(&local),
        "remote flood digest differs"
    );

    drop(far);
    drop(direct);
    let _ = bridge_shutdown.send(());
    bridge.await.unwrap();
    let _ = tokio::time::timeout(Duration::from_secs(5), remote).await;
    client_mux.shutdown().await;
    daemon_mux.shutdown().await;
    let _ = mux.close_surface_as(&Actor::Daemon, surface);
    cmux_tui_core::server::cleanup(&socket);
}
