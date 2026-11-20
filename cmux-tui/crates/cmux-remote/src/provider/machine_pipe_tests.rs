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
