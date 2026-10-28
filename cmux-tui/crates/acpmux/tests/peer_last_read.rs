//! `last` reads a running peer session without opening a live subscription. A link that
//! answers pings but withholds a read must return an error instead of waiting ten minutes.
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
const HERMETIC: daemon_env::Process = daemon_env::Process::deny();

use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::{Message, method};
use futures_util::{SinkExt, StreamExt};
use serde_json::{Value, json};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio_tungstenite::tungstenite::Message as Ws;

struct Fixture {
    hub: Arc<Hub>,
    dir: cmux_unix_socket::TestDir,
    socket: std::path::PathBuf,
    methods: Arc<Mutex<Vec<String>>>,
    tasks: Vec<tokio::task::JoinHandle<()>>,
}

impl Drop for Fixture {
    fn drop(&mut self) {
        for task in &self.tasks {
            task.abort();
        }
        if let Some(peer) = self.hub.peer_by_name("remote") {
            peer.stop();
        }
    }
}

impl Fixture {
    async fn new(hang: &'static str) -> Self {
        let mut config = Config::default();
        config.store.mode = StoreMode::Memory;
        let store =
            acpmux::store::open(&config.store, std::path::Path::new("/nonexistent")).unwrap();
        let hub = Hub::new(config, store);
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let methods = Arc::new(Mutex::new(Vec::new()));
        let seen = methods.clone();
        let peer = tokio::spawn(async move {
            let (tcp, _) = listener.accept().await.unwrap();
            let mut ws = tokio_tungstenite::accept_async(tcp).await.unwrap();
            while let Some(Ok(frame)) = ws.next().await {
                let Ws::Text(text) = frame else { continue };
                let Ok(Message::Request { id, method: m, params }) = Message::parse(&text) else {
                    continue;
                };
                seen.lock().unwrap().push(m.clone());
                if m == hang {
                    continue;
                }
                let row = json!({"sessionId": "remote-id", "name": "chat", "harness": "fake",
                    "status": "running", "createdAt": 1, "lastSeq": 2});
                let result = match m.as_str() {
                    method::INITIALIZE => json!({"protocolVersion": 1, "_meta": {"acpmux": {
                        "origin": "peer", "features": []}}}),
                    method::MUX_WATCH => json!({"sessions": [row]}),
                    method::MUX_INFO => row,
                    method::MUX_EVENTS => {
                        // A snapshot starts at the newest end, even while more events arrive.
                        assert!(params.unwrap()["beforeSeq"].as_u64().is_some());
                        json!({"events": [{"sessionId": "remote-id", "seq": 2,
                            "kind": "agent_message_chunk", "dir": "in", "msg": {
                                "jsonrpc": "2.0", "method": "session/update", "params": {
                                    "sessionId": "agent-id", "update": {
                                        "sessionUpdate": "agent_message_chunk",
                                        "content": {"type": "text", "text": "working reply"}
                                    }
                                }
                            }}], "hasMore": false, "lastSeq": 2, "pageThrough": 2})
                    }
                    _ => json!({}),
                };
                if ws.send(Ws::Text(Message::ok(id, result).to_line().into())).await.is_err() {
                    break;
                }
            }
        });
        hub.add_peer("remote", &format!("ws://127.0.0.1:{port}"), Some("token".into()), None, true)
            .await
            .unwrap();
        assert!(hub.peer_by_name("remote").unwrap().link().is_ready());
        let dir = cmux_unix_socket::short_test_dir("peer-last");
        let socket = dir.path().join("daemon.sock");
        let listener = acpmux::server::bind_unix(&socket).await.unwrap();
        let daemon_hub = hub.clone();
        let daemon = tokio::spawn(async move {
            acpmux::server::serve_unix(daemon_hub, listener).await.unwrap();
        });
        Self { hub, dir, socket, methods, tasks: vec![peer, daemon] }
    }

    async fn last(&self, budget: Duration) -> std::process::Output {
        tokio::time::timeout(
            budget,
            daemon_env::tokio_command(self.dir.path(), daemon_env::Agents::Deny)
                .env("ACPMUX_SOCKET", &self.socket)
                .args(["--json", "last", "remote/chat"])
                .kill_on_drop(true)
                .output(),
        )
        .await
        .expect("last must answer within its read budget")
        .unwrap()
    }
}

fn run(f: impl std::future::Future<Output = ()>) {
    tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .thread_stack_size(32 << 20)
        .enable_all()
        .build()
        .unwrap()
        .block_on(f);
}

#[test]
fn last_of_a_running_peer_is_a_snapshot_not_a_live_subscription() {
    run(async {
        let f = Fixture::new(method::MUX_ATTACH).await;
        let output = f.last(Duration::from_secs(2)).await;
        assert!(output.status.success(), "{}", String::from_utf8_lossy(&output.stderr));
        let reply: Value = serde_json::from_slice(&output.stdout).unwrap();
        assert_eq!(reply["replies"], json!(["working reply"]));
        assert!(!f.methods.lock().unwrap().iter().any(|m| m == method::MUX_ATTACH));
    });
}

#[test]
fn last_of_a_connected_peer_that_stops_answering_is_bounded() {
    run(async {
        let f = Fixture::new(method::MUX_INFO).await;
        let output = f.last(Duration::from_secs(35)).await;
        assert!(!output.status.success());
        let error = format!(
            "{}{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        assert!(error.contains("30 seconds") && error.contains("remote"), "{error}");
        assert!(f.hub.peer_by_name("remote").unwrap().link().is_ready());
    });
}

#[test]
fn forwarded_history_reads_have_a_deadline_and_release_pending_replies() {
    run(async {
        futures_util::future::join_all(
            [method::MUX_INFO, method::MUX_ATTACH, method::MUX_EVENTS].into_iter().map(
                |m| async move {
                    let f = Fixture::new(m).await;
                    let client = acpmux::client::Client::connect(&f.socket).await.unwrap();
                    let error = tokio::time::timeout(
                        Duration::from_secs(35),
                        client.request(m, json!({"sessionId": "remote/chat", "beforeSeq": 3})),
                    )
                    .await
                    .expect("forwarded read must not use the 600-second request budget")
                    .unwrap_err();
                    assert!(error.to_string().contains("30 seconds"), "{error}");
                    let peer = f.hub.peer_by_name("remote").unwrap();
                    tokio::task::yield_now().await;
                    assert_eq!(peer.pending_requests().await, 0);
                    assert!(peer.link().is_ready());
                },
            ),
        )
        .await;
    });
}
