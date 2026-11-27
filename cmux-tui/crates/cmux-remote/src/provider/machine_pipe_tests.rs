use super::*;
use tokio::io::AsyncBufReadExt as _;

#[test]
fn only_loopback_routes_go_through_a_machine() {
    for host in ["127.0.0.1", "[::1]", "::1", "localhost", "127.0.0.2"] {
        assert!(loopback_host(host), "{host}");
    }
    for host in ["10.0.0.1", "example.com", "[fd7a::10]"] {
        assert!(!loopback_host(host), "{host}");
    }
}

#[test]
fn a_refusal_says_why() {
    let refused = br#"{"jsonrpc":"2.0","id":1,"error":{"code":-32000,"message":"this machine's owner has not granted control from elsewhere (consent_required)","data":{"reason":"machine.unreachable"}}}"#;
    let refusal = crate::link::Refusal {
        reason: "consent_required".into(),
        message: "this machine's owner has not granted control from elsewhere".into(),
    };
    let error = machine_pipe_reply(refused).unwrap_err();
    assert_eq!(error.refusal(), Some(&refusal), "{error}");
    // A daemon that sends the far reason apart reads the same.
    let apart = br#"{"jsonrpc":"2.0","id":1,"error":{"code":-32000,"message":"this machine's owner has not granted control from elsewhere","data":{"reason":"consent_required"}}}"#;
    assert_eq!(machine_pipe_reply(apart).unwrap_err().refusal(), Some(&refusal));
    assert!(machine_pipe_reply(br#"{"jsonrpc":"2.0","id":1,"result":{"via":"hub"}}"#).is_ok());
    assert!(machine_pipe_reply(b"not json").is_err());
}

/// Only a reason no redial cures ends the dial; a transient one stays a transport failure,
/// which the caller redials.
#[test]
fn only_a_terminal_reason_ends_the_dial() {
    let reply = |message: &str, reason: &str| {
        json!({"jsonrpc": "2.0", "id": 1, "error": {
            "code": -32000, "message": message, "data": {"reason": reason},
        }})
        .to_string()
    };
    for (message, reason) in [
        ("the cmux-tui remote daemon at 127.0.0.1:7781 is not listening", "service.unreachable"),
        ("relay connect failed: the relay did not answer", "machine.unreachable"),
        ("connect failed: connection refused (os error 111)", "machine.unreachable"),
        ("the hub carrier is off", "carrier.off"),
        ("not listed yet (machine.unlisted)", "machine.unreachable"),
        ("something new", "some.future_reason"),
    ] {
        let error = machine_pipe_reply(reply(message, reason).as_bytes()).unwrap_err();
        assert!(matches!(error, LinkError::Transport(_)), "{message}: {error:?}");
    }
    for reason in TERMINAL_REFUSALS {
        let error = machine_pipe_reply(reply("no", reason).as_bytes()).unwrap_err();
        assert_eq!(error.refusal().map(|r| r.reason.as_str()), Some(*reason));
        let folded = format!("no ({reason})");
        let error =
            machine_pipe_reply(reply(&folded, "machine.unreachable").as_bytes()).unwrap_err();
        assert_eq!(error.refusal().map(|r| r.message.as_str()), Some("no"), "{reason}");
    }
}

/// A fake acpmux at a fresh socket: connection `n` (from 0) reads its request line, waits
/// `plan(n).0`, then answers `plan(n).1` (None: holds the connection without answering).
/// Answers the socket and how many pipes were asked for.
fn fake_acpmux(
    plan: fn(usize) -> (Duration, Option<&'static str>),
) -> (tempfile::TempDir, PathBuf, std::sync::Arc<std::sync::atomic::AtomicUsize>) {
    use std::sync::atomic::{AtomicUsize, Ordering};
    let dir = tempfile::tempdir().unwrap();
    let socket = dir.path().join("acpmux.sock");
    let listener = tokio::net::UnixListener::bind(&socket).unwrap();
    let asked = std::sync::Arc::new(AtomicUsize::new(0));
    let count = asked.clone();
    tokio::spawn(async move {
        loop {
            let (stream, _) = listener.accept().await.unwrap();
            let n = count.fetch_add(1, Ordering::SeqCst);
            tokio::spawn(async move {
                let mut stream = tokio::io::BufReader::new(stream);
                let mut request = String::new();
                stream.read_line(&mut request).await.unwrap();
                let (wait, answer) = plan(n);
                tokio::time::sleep(wait).await;
                let mut stream = stream.into_inner();
                match answer {
                    Some(line) => {
                        let _ = stream.write_all(format!("{line}\n").as_bytes()).await;
                        let _ = stream.read(&mut [0u8; 1]).await;
                    }
                    None => std::future::pending::<()>().await,
                }
            });
        }
    });
    (dir, socket, asked)
}

const OPENED: &str = r#"{"jsonrpc":"2.0","id":1,"result":{"via":"hub"}}"#;
const NOT_SERVING: &str = r#"{"jsonrpc":"2.0","id":1,"error":{"code":-32000,"message":"that machine's hub carrier is off (it did not answer on the relay within 6s)","data":{"reason":"carrier.not_serving"}}}"#;
const NO_CONSENT: &str = r#"{"jsonrpc":"2.0","id":1,"error":{"code":-32000,"message":"no","data":{"reason":"consent_required"}}}"#;

/// A pipe whose circuit is slow does not hold the dial: another one asked for beside it
/// opens in the usual time (to a Mac on a slow uplink one circuit in a few took 12 s, the
/// dial's whole connect stage, while the next opened in 5 s).
#[tokio::test]
async fn a_slow_pipe_does_not_hold_the_dial() {
    use std::sync::atomic::Ordering;
    let (_dir, socket, asked) =
        fake_acpmux(
            |n| {
                if n == 0 { (Duration::ZERO, None) } else { (Duration::ZERO, Some(OPENED)) }
            },
        );
    let dialer =
        MachinePipeDialer::new(socket, "mac".into()).with_stagger(Duration::from_millis(50));
    tokio::time::timeout(Duration::from_secs(5), dialer.dial("127.0.0.1", 7781))
        .await
        .expect("the dial waited on the slow pipe")
        .unwrap();
    assert_eq!(asked.load(Ordering::SeqCst), 2);
}

/// One circuit's slow join (`carrier.not_serving`) does not end the dial while another pipe
/// may still open; it was a refusal no redial cures, which ended the whole first connect.
#[tokio::test]
async fn one_pipe_refused_while_another_is_in_flight_is_not_the_answer() {
    let (_dir, socket, _) = fake_acpmux(|n| match n {
        0 => (Duration::from_millis(100), Some(NOT_SERVING)),
        _ => (Duration::from_millis(200), Some(OPENED)),
    });
    let dialer =
        MachinePipeDialer::new(socket, "mac".into()).with_stagger(Duration::from_millis(50));
    tokio::time::timeout(Duration::from_secs(5), dialer.dial("127.0.0.1", 7781))
        .await
        .expect("the dial hung")
        .unwrap();
}

/// A refusal with nothing else in flight is the answer at once, with its reason: it asks
/// no more pipes, and does not wait for the next stagger.
#[tokio::test]
async fn a_refusal_with_nothing_in_flight_ends_the_dial() {
    use std::sync::atomic::Ordering;
    let (_dir, socket, asked) = fake_acpmux(|_| (Duration::ZERO, Some(NO_CONSENT)));
    let dialer = MachinePipeDialer::new(socket, "mac".into()).with_stagger(Duration::from_secs(60));
    let error = tokio::time::timeout(Duration::from_secs(5), dialer.dial("127.0.0.1", 7781))
        .await
        .expect("the refusal waited for the next stagger")
        .err()
        .expect("a refused pipe opened");
    assert_eq!(error.refusal().map(|r| r.reason.as_str()), Some("consent_required"));
    assert_eq!(asked.load(Ordering::SeqCst), 1);
}

/// A route through another machine makes one link for every lane: each link is a hub
/// circuit of its own, and the first connect waited on three of them (cmux `remote exec
/// --via-machine` to a Mac on a slow uplink: 7 to 52 s, 2 in 10 timed out at 60 s).
#[tokio::test]
async fn a_route_through_a_machine_dials_one_link_for_every_lane() {
    use crate::provider::{
        ConnectRequest, DirectWebSocketProvider, OsTcpDialer, TransportProvider, lane_bindings,
    };
    use cmux_remote_protocol::{Lane, LanePolicy, SessionId};
    use std::sync::Arc;

    let bindings = |dialer: Arc<dyn Dialer>| async move {
        let request = ConnectRequest {
            endpoint: url::Url::parse("ws://127.0.0.1:7781/v1/link").unwrap(),
            session: SessionId([7; 16]),
            lane_policy: LanePolicy::Auto,
            routing: Default::default(),
        };
        let group =
            DirectWebSocketProvider::with_dialer(1 << 20, dialer).connect(request).await.unwrap();
        lane_bindings(LanePolicy::Auto, group.capabilities())
    };
    let machine = MachinePipeDialer::new("/nonexistent/acpmux.sock".into(), "mac".into());
    assert_eq!(bindings(Arc::new(machine)).await, vec![Lane::ALL.to_vec()]);
    // A direct WebSocket keeps a link per lane group.
    assert_eq!(bindings(Arc::new(OsTcpDialer)).await.len(), 3);
}

/// The dialer asks once, reads exactly the reply line, and hands back the rest of the
/// connection: the first byte after the reply is the pipe's.
#[tokio::test]
async fn the_dial_returns_the_connection_after_the_reply_line() {
    let dir = tempfile::tempdir().unwrap();
    let socket = dir.path().join("acpmux.sock");
    let listener = tokio::net::UnixListener::bind(&socket).unwrap();
    let server = tokio::spawn(async move {
        let (stream, _) = listener.accept().await.unwrap();
        let mut stream = tokio::io::BufReader::new(stream);
        let mut request = String::new();
        stream.read_line(&mut request).await.unwrap();
        let mut stream = stream.into_inner();
        stream
            .write_all(b"{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"via\":\"hub\"}}\nX")
            .await
            .unwrap();
        let mut echo = [0u8; 4];
        stream.read_exact(&mut echo).await.unwrap();
        stream.write_all(&echo).await.unwrap();
        request
    });
    let dialer = MachinePipeDialer::new(socket, "mac".into());
    let mut stream = dialer.dial("127.0.0.1", 7781).await.unwrap();
    let mut first = [0u8; 1];
    stream.read_exact(&mut first).await.unwrap();
    assert_eq!(&first, b"X");
    stream.write_all(b"ping").await.unwrap();
    let mut echo = [0u8; 4];
    stream.read_exact(&mut echo).await.unwrap();
    assert_eq!(&echo, b"ping");
    let request: Value = serde_json::from_str(&server.await.unwrap()).unwrap();
    assert_eq!(request["method"], MACHINE_PIPE_METHOD);
    assert_eq!(request["params"], json!({"machine": "mac", "port": 7781}));
    assert!(dialer.dial("10.0.0.1", 7781).await.is_err());
}
