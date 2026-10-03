//! The hub's control socket in-process (transport.md 12a): datagram ports
//! served on Unix datagram sockets with a priority class, and `path.changed`
//! events from the tunnel's one-path selector.
#![cfg(unix)]

use std::net::SocketAddr;
use std::os::unix::fs::{FileTypeExt, PermissionsExt};
use std::path::Path;
use std::sync::Arc;
use std::time::Duration;

use cmux_remote::wireguard_hub_control::{decode_header, encode_header, serve_hub_control};
use cmux_wg::testing::{LoopbackPair, loopback_pair};
use cmux_wg::{PathKind, Priority, ProbeConfig, SocketPath, WgNet};
use serde_json::{Value, json};
use tempfile::tempdir;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::unix::OwnedReadHalf;
use tokio::net::{UnixDatagram, UnixStream};
use tokio::time::timeout;

const TIMEOUT: Duration = Duration::from_secs(10);

struct Control {
    lines: tokio::io::Lines<BufReader<OwnedReadHalf>>,
    write: tokio::net::unix::OwnedWriteHalf,
    events: Vec<Value>,
}

impl Control {
    async fn open(path: &Path) -> Self {
        let (read, write) = UnixStream::connect(path).await.unwrap().into_split();
        Self { lines: BufReader::new(read).lines(), write, events: Vec::new() }
    }

    async fn next(&mut self) -> Value {
        let line = timeout(TIMEOUT, self.lines.next_line()).await.unwrap().unwrap().unwrap();
        serde_json::from_str(&line).unwrap()
    }

    /// Send one request and return its reply; events read meanwhile are kept.
    async fn call(&mut self, id: u64, method: &str, params: Value) -> Value {
        let request = json!({ "id": id, "method": method, "params": params });
        self.write.write_all(format!("{request}\n").as_bytes()).await.unwrap();
        loop {
            let line = self.next().await;
            if line.get("event").is_some() {
                self.events.push(line);
            } else {
                assert_eq!(line["id"], id, "{line}");
                return line;
            }
        }
    }
}

fn mode(path: &Path) -> u32 {
    std::fs::metadata(path).unwrap().permissions().mode() & 0o777
}

#[tokio::test]
async fn control_socket_serves_datagram_ports_and_path_events() {
    let LoopbackPair { client, server, client_socket, server_socket, client_v6, server_v6, .. } =
        loopback_pair().await.unwrap();
    let server_addr = server_socket.local_addr().unwrap();
    let peer = WgNet::start(server, server_socket).await.unwrap();
    // The hub's shape: one probed path (the config names the peer's address).
    let path = SocketPath::new(client_socket, Some(server_addr));
    let (net, paths) =
        WgNet::start_on_one_path(client, PathKind::ViaCloudRegion, Some(ProbeConfig::default()), path)
            .unwrap();
    let net = Arc::new(net);
    net.wait_for_handshake(TIMEOUT).await.unwrap();

    let dir = tempdir().unwrap();
    let control_path = dir.path().join("hub").join("control.sock");
    let control = serve_hub_control(Arc::clone(&net), Some(paths), control_path.clone())
        .await
        .unwrap();
    assert_eq!(mode(&control_path), 0o600);
    let mut session = Control::open(&control_path).await;

    let bound = session.call(1, "datagram.bind", json!({"port": 4103, "class": "media"})).await;
    let result = &bound["result"];
    assert_eq!(result["max_datagram"], 1152, "{bound}");
    assert_eq!(result["class"], "media");
    let dgram_path = Path::new(result["socket"].as_str().unwrap()).to_path_buf();
    assert_eq!(dgram_path, dir.path().join("hub").join("control.sock.dgram-4103"));
    assert!(std::fs::metadata(&dgram_path).unwrap().file_type().is_socket());
    assert_eq!(mode(&dgram_path), 0o600);

    // Refusals: reserved ports, a busy port, an unknown class or method.
    for (id, params, code) in [
        (2, json!({"port": 4102, "class": "media"}), "reserved_port"),
        (3, json!({"port": 4103, "class": "bulk"}), "port_busy"),
        (4, json!({"port": 4104, "class": "video"}), "invalid_params"),
    ] {
        let reply = session.call(id, "datagram.bind", params).await;
        assert_eq!(reply["error"]["code"], code, "{reply}");
    }
    let reply = session.call(5, "datagram.nope", Value::Null).await;
    assert_eq!(reply["error"]["code"], "unknown_method", "{reply}");

    // A datagram round trip through the Unix socket and the tunnel.
    let mut theirs = peer.bind_datagram(4103).await.unwrap();
    let client_path = dir.path().join("client.sock");
    let local = UnixDatagram::bind(&client_path).unwrap();
    let to_peer = SocketAddr::new(server_v6, 4103);
    let mut datagram = encode_header(to_peer);
    datagram.extend_from_slice(b"frame");
    local.send_to(&datagram, &dgram_path).await.unwrap();
    let (payload, from) = timeout(TIMEOUT, theirs.recv_from()).await.unwrap().unwrap();
    assert_eq!((payload.as_slice(), from), (&b"frame"[..], SocketAddr::new(client_v6, 4103)));
    theirs.send_to(b"ack", from, Priority::Interactive).await.unwrap();
    let mut buffer = vec![0u8; 2048];
    let len = timeout(TIMEOUT, local.recv(&mut buffer)).await.unwrap().unwrap();
    assert_eq!(decode_header(&buffer[..len]), Some((to_peer, &b"ack"[..])));

    // Path events: the snapshot, then a switch once the probes answer.
    let subscribed = session.call(6, "path.subscribe", Value::Null).await;
    assert_eq!(subscribed["result"]["max_datagram"], 1152, "{subscribed}");
    let event = timeout(TIMEOUT, async {
        loop {
            // Traffic keeps the session active, which is when probes run.
            local.send_to(&datagram, &dgram_path).await.unwrap();
            let _ = timeout(Duration::from_millis(500), theirs.recv_from()).await;
            if let Some(event) = session.events.iter().find(|event| !event["path"].is_null()) {
                return event.clone();
            }
            if let Ok(Ok(Some(line))) =
                timeout(Duration::from_millis(100), session.lines.next_line()).await
            {
                session.events.push(serde_json::from_str(&line).unwrap());
            }
        }
    })
    .await
    .expect("a path.changed event once the path answers probes");
    assert_eq!(event["event"], "path.changed");
    assert_eq!(event["kind"], "via-cloud-region", "{event}");
    assert_eq!(event["max_datagram"], 1152);
    assert!(event["rtt_ms"].as_f64().unwrap() > 0.0, "{event}");

    let stats = session.call(7, "datagram.stats", Value::Null).await;
    assert_eq!(stats["result"]["media_stale"], 0, "{stats}");

    // The binding ends with its control connection: the socket file goes
    // and the port can be bound again.
    drop(session);
    timeout(TIMEOUT, async {
        while dgram_path.exists() {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    })
    .await
    .expect("the datagram socket is unlinked when its control connection ends");
    let mut again = Control::open(&control_path).await;
    let rebound = again.call(1, "datagram.bind", json!({"port": 4103, "class": "bulk"})).await;
    assert_eq!(rebound["result"]["class"], "bulk", "{rebound}");

    drop(again);
    control.shutdown().await.unwrap();
    assert!(!control_path.exists(), "the control socket is removed on shutdown");
    drop(net);
    peer.shutdown().await;
}

#[tokio::test]
async fn a_hub_without_path_control_says_so() {
    let LoopbackPair { client, client_socket, .. } = loopback_pair().await.unwrap();
    let net = Arc::new(WgNet::start(client, client_socket).await.unwrap());
    let dir = tempdir().unwrap();
    let control_path = dir.path().join("control.sock");
    let control = serve_hub_control(net, None, control_path.clone()).await.unwrap();
    let mut session = Control::open(&control_path).await;
    let reply = session.call(1, "path.subscribe", Value::Null).await;
    assert_eq!(reply["error"]["code"], "unavailable", "{reply}");
    let reply = session.call(2, "datagram.stats", Value::Null).await;
    assert_eq!(reply["result"]["bulk_full"], 0, "{reply}");
    // A line that is not JSON gets an error, and the connection stays usable.
    session.write.write_all(b"not json\n").await.unwrap();
    assert_eq!(session.next().await["error"]["code"], "invalid_request");
    let reply = session.call(3, "path.get", Value::Null).await;
    assert_eq!(reply["error"]["code"], "unavailable", "{reply}");
    drop(session);
    control.shutdown().await.unwrap();
}
