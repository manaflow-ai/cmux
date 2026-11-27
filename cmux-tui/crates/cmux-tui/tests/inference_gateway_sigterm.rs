//! `cmux inference gateway` under systemd's stop: SIGTERM lets the calls in flight finish, turns new ones away with a
//! code to retry, closes its socket and exits 0 within seconds. Before this, the process-wide handler (main.rs) took
//! SIGTERM and the gateway never looked, so each `systemctl restart team-gw` waited out systemd's 90 s stop timeout
//! and a SIGKILL cut every call in flight (gcp-agent-lane-13, 2026-11-22: about 110 calls failed in one restart).
#![cfg(unix)]

use std::process::{ExitStatus, Stdio};
use std::time::Duration;

use base64::Engine as _;
use futures_util::{SinkExt as _, StreamExt as _};
use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt as _, AsyncReadExt as _, AsyncWriteExt as _, BufReader};
use tokio::net::{TcpListener, TcpStream};
use tokio::process::{Child, Command};
use tokio::sync::{mpsc, oneshot};
use tokio_tungstenite::WebSocketStream;
use tokio_tungstenite::tungstenite::Message;

const STEP: Duration = Duration::from_secs(15);
/// How soon after SIGTERM the gateway must be gone once its calls are done.
const EXIT_WITHIN: Duration = Duration::from_secs(5);

struct Gateway {
    child: Child,
    stderr: mpsc::UnboundedReceiver<String>,
    socket: WebSocketStream<TcpStream>,
    _home: tempfile::TempDir,
}

/// The gateway, connected to a stand-in cmux API that has sent `hello`, with its calls going to `upstream`.
async fn start(upstream: &str) -> Gateway {
    let home = tempfile::tempdir().unwrap();
    let token = home.path().join("token");
    std::fs::write(&token, "test-token\n").unwrap();
    let api = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let mut child = Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
        .args(["inference", "gateway", "--api"])
        .arg(format!("http://{}", api.local_addr().unwrap()))
        .args(["--team", "team_test", "--upstream", upstream, "--token-file"])
        .arg(&token)
        .env("HOME", home.path())
        .env("XDG_STATE_HOME", home.path().join("xdg"))
        .env("CMUX_TUI_CONFIG", home.path().join("config.json"))
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .kill_on_drop(true)
        .spawn()
        .unwrap();
    let (tx, stderr) = mpsc::unbounded_channel();
    let mut lines = BufReader::new(child.stderr.take().unwrap()).lines();
    tokio::spawn(async move {
        while let Ok(Some(line)) = lines.next_line().await {
            let _ = tx.send(line);
        }
    });
    let (stream, _) =
        tokio::time::timeout(STEP, api.accept()).await.expect("the gateway never dialed").unwrap();
    let mut socket = tokio_tungstenite::accept_async(stream).await.unwrap();
    socket
        .send(Message::Text(
            json!({"v": 1, "t": "hello", "protocol": "cmux.inference-gateway/1"})
                .to_string()
                .into(),
        ))
        .await
        .unwrap();
    let mut gateway = Gateway { child, stderr, socket, _home: home };
    gateway.log_line("connected to").await;
    gateway
}

impl Gateway {
    /// The first stderr line holding `needle` (a lifecycle line the gateway prints), within STEP.
    async fn log_line(&mut self, needle: &str) -> String {
        let wait = async {
            while let Some(line) = self.stderr.recv().await {
                if line.contains(needle) {
                    return line;
                }
            }
            panic!("the gateway's stderr ended before it said {needle:?}");
        };
        tokio::time::timeout(STEP, wait)
            .await
            .unwrap_or_else(|_| panic!("the gateway never said {needle:?}"))
    }

    /// One call down the socket: `request`, one `body` chunk, `body_end`.
    async fn call(&mut self, id: &str) {
        let body = base64::engine::general_purpose::STANDARD.encode(br#"{"model":"m"}"#);
        for frame in [
            json!({"v": 1, "t": "request", "id": id, "method": "POST", "path": "/v1/messages",
                   "headers": {"content-type": "application/json"}}),
            json!({"v": 1, "t": "body", "id": id, "data": body}),
            json!({"v": 1, "t": "body_end", "id": id}),
        ] {
            self.socket.send(Message::Text(frame.to_string().into())).await.unwrap();
        }
    }

    /// The next frame that is not a ping; None once the gateway closed the socket.
    async fn frame(&mut self) -> Option<Value> {
        let next = async {
            loop {
                match self.socket.next().await {
                    Some(Ok(Message::Text(text))) => {
                        let frame: Value = serde_json::from_str(&text).unwrap();
                        if frame["t"] != "ping" {
                            return Some(frame);
                        }
                    }
                    Some(Ok(Message::Close(_))) | None | Some(Err(_)) => return None,
                    Some(Ok(_)) => {}
                }
            }
        };
        tokio::time::timeout(STEP, next).await.expect("the gateway sent nothing")
    }

    fn sigterm(&self) {
        let pid = self.child.id().expect("the gateway already exited") as libc::pid_t;
        // SAFETY: kill(2) on the child this test started and still holds.
        assert_eq!(unsafe { libc::kill(pid, libc::SIGTERM) }, 0);
    }

    async fn exits_within(&mut self, limit: Duration) -> ExitStatus {
        match tokio::time::timeout(limit, self.child.wait()).await {
            Ok(status) => status.unwrap(),
            Err(_) => panic!("the gateway was still running {} s after SIGTERM", limit.as_secs()),
        }
    }
}

/// A subscription proxy stand-in for one call: says when the call reached it, then answers once released.
async fn held_upstream() -> (String, oneshot::Receiver<()>, oneshot::Sender<()>) {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let base = format!("http://{}", listener.local_addr().unwrap());
    let (reached_tx, reached) = oneshot::channel();
    let (release, released) = oneshot::channel::<()>();
    tokio::spawn(async move {
        let (mut sock, _) = listener.accept().await.unwrap();
        let mut seen = Vec::new();
        let mut buf = [0u8; 4096];
        loop {
            let n = sock.read(&mut buf).await.unwrap();
            assert!(n > 0, "the gateway closed the call before its body arrived");
            seen.extend_from_slice(&buf[..n]);

            // The gateway warms this origin with HEAD before sending the model call.  Consume
            // and answer that request on the same keep-alive socket so the test still holds the
            // subsequent POST response behind `released`.
            while let Some(end) = seen.windows(4).position(|window| window == b"\r\n\r\n") {
                let head = String::from_utf8_lossy(&seen[..end]).to_ascii_lowercase();
                let content_length = head
                    .lines()
                    .find_map(|line| line.strip_prefix("content-length:"))
                    .map_or(0, |value| value.trim().parse::<usize>().unwrap());
                let frame_len = end + 4 + content_length;
                if seen.len() < frame_len {
                    break;
                }
                let request = seen.drain(..frame_len).collect::<Vec<_>>();
                if head.starts_with("head ") {
                    // HEAD responses carry no body, even when they advertise a representation
                    // length.  Keep the socket open for reqwest's first real call.
                    sock.write_all(
                        b"HTTP/1.1 200 OK\r\ncontent-length: 0\r\nconnection: keep-alive\r\n\r\n",
                    )
                    .await
                    .unwrap();
                    continue;
                }
                if String::from_utf8_lossy(&request).contains(r#"{"model":"m"}"#) {
                    let _ = reached_tx.send(());
                    let _ = released.await;
                    sock.write_all(
                        b"HTTP/1.1 200 OK\r\ncontent-length: 7\r\nconnection: close\r\n\r\n{\"a\":1}",
                    )
                    .await
                    .unwrap();
                    sock.shutdown().await.unwrap();
                    return;
                }
            }
        }
    });
    (base, reached, release)
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn sigterm_lets_the_call_in_flight_finish_turns_new_ones_away_and_exits() {
    let (upstream, reached, release) = held_upstream().await;
    let mut gateway = start(&upstream).await;
    gateway.call("c1").await;
    tokio::time::timeout(STEP, reached).await.expect("the call never reached the proxy").unwrap();

    gateway.sigterm();
    gateway.log_line("stopping").await;
    // A call that comes while the gateway stops is turned away with a code the caller retries.
    gateway.call("c2").await;
    let refused = gateway.frame().await.expect("the socket closed before c2 was answered");
    assert_eq!(refused["t"], "error", "{refused}");
    assert_eq!(refused["id"], "c2", "{refused}");
    assert_eq!(refused["code"], "inference.gateway_restarting", "{refused}");

    // The call in flight still gets its whole answer.
    release.send(()).unwrap();
    let mut got = Vec::new();
    while let Some(frame) = gateway.frame().await {
        got.push(frame);
    }
    let kinds: Vec<_> = got
        .iter()
        .filter(|f| f["id"] == "c1")
        .map(|f| f["t"].as_str().unwrap().to_owned())
        .collect();
    assert_eq!(kinds.first().map(String::as_str), Some("head"), "{got:?}");
    assert_eq!(kinds.last().map(String::as_str), Some("end"), "{got:?}");
    let head = got.iter().find(|f| f["t"] == "head").unwrap();
    assert_eq!(head["status"], 200, "{got:?}");

    let status = gateway.exits_within(EXIT_WITHIN).await;
    assert!(status.success(), "the gateway's stop is a clean exit: {status:?}");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn sigterm_on_an_idle_gateway_closes_its_socket_and_exits_at_once() {
    // Nothing listens there: no call is made.
    let mut gateway = start("http://127.0.0.1:9").await;
    gateway.sigterm();
    assert!(gateway.frame().await.is_none(), "the gateway closes its socket when it stops");
    let status = gateway.exits_within(EXIT_WITHIN).await;
    assert!(status.success(), "the gateway's stop is a clean exit: {status:?}");
}
