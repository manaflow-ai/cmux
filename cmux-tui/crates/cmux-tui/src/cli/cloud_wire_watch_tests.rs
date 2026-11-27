use futures_util::{SinkExt as _, StreamExt as _};
use serde_json::{Value, json};
use tokio::io::{AsyncReadExt as _, AsyncWriteExt as _};
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::tungstenite::handshake::server::{Request, Response};
use tokio_tungstenite::tungstenite::http::HeaderValue;
use tokio_tungstenite::tungstenite::protocol::CloseFrame;
use tokio_tungstenite::tungstenite::protocol::frame::coding::CloseCode;

use super::{SUBPROTOCOL, Wire, parse, protocols, watch};

fn input(api: &str, team: Option<&str>) -> Vec<u8> {
    json!({"api": api, "access": "acc", "team": team, "version": "1.0"}).to_string().into_bytes()
}

#[test]
fn the_socket_is_the_apis_wire_route() {
    assert_eq!(
        parse(&input("https://cloud-api-staging.cmux.dev", Some("team_1"))),
        Ok(Wire {
            origin: "https://cloud-api-staging.cmux.dev".into(),
            socket: "wss://cloud-api-staging.cmux.dev/v1/wire/cloud".into(),
            access: "acc".into(),
            team: Some("team_1".into()),
            version: Some("1.0".into()),
        })
    );
    assert_eq!(
        parse(&input("http://127.0.0.1:8787/", None)).map(|w| (w.socket, w.team)),
        Ok(("ws://127.0.0.1:8787/v1/wire/cloud".into(), None))
    );
}

#[test]
fn a_bad_wire_request_mints_no_ticket() {
    // Plain http off loopback, a path on the origin, no token, a team that is no protocol token.
    assert!(parse(&input("http://api.cmux.dev", None)).is_err());
    assert!(parse(&input("https://api.cmux.dev/v1", None)).is_err());
    assert!(parse(br#"{"api":"https://api.cmux.dev","access":""}"#).is_err());
    assert!(parse(&input("https://api.cmux.dev", Some("a, b"))).is_err());
    assert!(parse(b"not json").is_err());
}

#[test]
fn the_subprotocol_carries_the_ticket_and_team_never_the_token() {
    assert_eq!(protocols("t1", Some("team_1")), "cmux.wire.v1, ticket.t1, team.team_1");
    assert_eq!(protocols("t1", None), "cmux.wire.v1, ticket.t1");
}

/// Answers one `POST /v1/wire/ticket` with `answer`; returns the request's head and body.
async fn ticket(listener: &tokio::net::TcpListener, answer: &str) -> String {
    let (mut socket, _) = listener.accept().await.unwrap();
    let mut seen = Vec::new();
    let mut buffer = [0u8; 4096];
    while !String::from_utf8_lossy(&seen).contains(r#"{"scope":"cloud"}"#) {
        let read = socket.read(&mut buffer).await.unwrap();
        assert!(read > 0, "the ticket request ended early");
        seen.extend_from_slice(&buffer[..read]);
    }
    let response = format!(
        "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{answer}",
        answer.len()
    );
    socket.write_all(response.as_bytes()).await.unwrap();
    let _ = socket.shutdown().await;
    String::from_utf8_lossy(&seen).into_owned()
}

#[tokio::test]
async fn it_mints_a_ticket_subscribes_on_welcome_and_prints_each_frame() {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let server = tokio::spawn(async move {
        let post = ticket(&listener, r#"{"ticket":"tk1"}"#).await;
        let (socket, _) = listener.accept().await.unwrap();
        let mut seen = (String::new(), String::new());
        let callback = |request: &Request, mut response: Response| {
            let header = |name: &str| {
                request
                    .headers()
                    .get(name)
                    .map(|v| v.to_str().unwrap().to_owned())
                    .unwrap_or_default()
            };
            seen = (header("sec-websocket-protocol"), header("x-cmux-client-version"));
            assert_eq!(request.uri().path(), "/v1/wire/cloud");
            response
                .headers_mut()
                .insert("sec-websocket-protocol", HeaderValue::from_static(SUBPROTOCOL));
            Ok(response)
        };
        let mut ws = tokio_tungstenite::accept_hdr_async(socket, callback).await.unwrap();
        ws.send(Message::Text(r#"{"t":"welcome"}"#.into())).await.unwrap();
        let subscribe = ws.next().await.unwrap().unwrap();
        ws.send(Message::Text(r#"{"t":"snapshot","stream":"cloud:team_1"}"#.into())).await.unwrap();
        ws.send(Message::Text("not json".into())).await.unwrap();
        ws.send(Message::Text(r#"{"t":"ephemeral","event":"cloud.spare.ready"}"#.into()))
            .await
            .unwrap();
        ws.send(Message::Close(Some(CloseFrame {
            code: CloseCode::from(4000),
            reason: "".into(),
        })))
        .await
        .unwrap();
        let _ = ws.next().await;
        (post, seen, subscribe)
    });
    let mut lines = Vec::new();
    let last = watch(&input(&format!("http://{address}"), Some("team_1")), &mut |line: &Value| {
        lines.push(line.clone())
    })
    .await;
    assert_eq!(
        lines,
        vec![
            json!({"t": "welcome"}),
            json!({"t": "snapshot", "stream": "cloud:team_1"}),
            json!({"t": "ephemeral", "event": "cloud.spare.ready"}),
        ]
    );
    assert_eq!(last, json!({"closed": 4000}));
    let (post, (protocol, version), subscribe) = server.await.unwrap();
    assert!(post.starts_with("POST /v1/wire/ticket "), "{post}");
    assert!(post.to_ascii_lowercase().contains("authorization: bearer acc"), "{post}");
    assert_eq!(protocol, "cmux.wire.v1, ticket.tk1, team.team_1");
    assert!(!protocol.contains("acc"));
    assert_eq!(version, "1.0");
    assert_eq!(subscribe, Message::Text(r#"{"t":"subscribe"}"#.into()));
}

#[tokio::test]
async fn a_refused_ticket_opens_no_socket() {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let server = tokio::spawn(async move { ticket(&listener, r#"{"nope":true}"#).await });
    let last = watch(&input(&format!("http://{address}"), None), &mut |_: &Value| {}).await;
    assert_eq!(last["closed"], Value::Null);
    assert_eq!(last["error"], "Cloud wire ticket response");
    server.await.unwrap();
}
