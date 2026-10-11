//! A page-like WebSocket client must authenticate with its first frame.

mod common;

use std::sync::Arc;
use std::time::{Duration, Instant};

use cmux_local_auth::ListenerPolicy;
use cmux_pane_protocol::envelope::{AUTH_REPLY_ID, Envelope};
use cmux_pane_protocol::example::{self, APP_ID, SCOPE};
use cmux_pane_protocol::frame::Message;
use cmux_pane_protocol::token::{Claims, SigningKey, Verifier, now};
use cmux_pane_protocol::{error, ws};
use common::{next_envelope, next_message, send};
use serde_json::json;

const PAGE_ORIGIN: &str = "http://127.0.0.1:4100";

async fn start() -> (std::net::SocketAddr, SigningKey) {
    let key = SigningKey::from_seed(&[9; 32]).unwrap();
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let verifier = Arc::new(Verifier::new(key.public_key(), APP_ID));
    let policy = ListenerPolicy::loopback(address.port()).with_origin(PAGE_ORIGIN);
    tokio::spawn(ws::serve(listener, Arc::new(example::provider()), verifier, policy));
    (address, key)
}

fn claims(scopes: &[&str], origin: Option<&str>) -> Claims {
    Claims {
        sub: "page-1".into(),
        page: None,
        app: "cmux.agent".into(),
        ns: vec![APP_ID.into()],
        scopes: scopes.iter().map(|scope| (*scope).to_owned()).collect(),
        roots: Vec::new(),
        origin: origin.map(str::to_owned),
        aud: APP_ID.into(),
        exp: now() + 60,
        iat: now(),
    }
}

fn url(address: std::net::SocketAddr) -> String {
    format!("ws://{address}/")
}

#[tokio::test]
async fn first_frame_token_authenticates_and_calls_go_direct() {
    let (address, key) = start().await;
    let mut page = ws::connect(address, &url(address), Some(PAGE_ORIGIN)).await.unwrap();
    send(&page, Envelope::Auth { token: key.sign(&claims(&[SCOPE], Some(PAGE_ORIGIN))) }).await;
    let Some(Envelope::Ok { id, value }) = next_envelope(&mut page).await else {
        panic!("auth refused")
    };
    assert_eq!(id, AUTH_REPLY_ID);
    assert_eq!(value["provider"], APP_ID);
    send(
        &page,
        Envelope::Call {
            id: 1,
            op: "com.example.hello.greet.say".into(),
            params: json!({ "name": "lane-a" }),
            cap: None,
        },
    )
    .await;
    assert_eq!(
        next_envelope(&mut page).await,
        Some(Envelope::Ok { id: 1, value: json!({ "message": "hello, lane-a" }) })
    );
    send(
        &page,
        Envelope::Call {
            id: 2,
            op: "com.example.hello.greet.say".into(),
            params: json!({ "name": 1 }),
            cap: None,
        },
    )
    .await;
    let Some(refused) = next_envelope(&mut page).await else { panic!("closed") };
    assert_eq!(refused.error_body().unwrap().code, error::INVALID_PARAMS);
    // Events: seq starts at 1.
    send(
        &page,
        Envelope::Sub {
            id: 3,
            stream: "com.example.hello.greet.ticks".into(),
            filter: None,
            cap: None,
        },
    )
    .await;
    let Some(Envelope::Ok { id: 3, value }) = next_envelope(&mut page).await else {
        panic!("sub refused")
    };
    let sub = value["sub"].as_u64().unwrap();
    for seq in 1..=3 {
        let Some(Envelope::Ev { sub: got, seq: got_seq, data, gap }) =
            next_envelope(&mut page).await
        else {
            panic!()
        };
        assert_eq!((got, got_seq, gap), (sub, seq, false));
        assert_eq!(data, json!({ "message": format!("tick {seq}") }));
    }
    // Ops not in the IR are refused.
    send(
        &page,
        Envelope::Call {
            id: 4,
            op: "com.example.hello.greet.shout".into(),
            params: json!({}),
            cap: None,
        },
    )
    .await;
    assert_eq!(
        next_envelope(&mut page).await.unwrap().error_body().unwrap().code,
        error::UNKNOWN_OP
    );
}

#[tokio::test]
async fn a_call_before_auth_is_refused_and_closed() {
    let (address, _key) = start().await;
    let mut page = ws::connect(address, &url(address), Some(PAGE_ORIGIN)).await.unwrap();
    send(
        &page,
        Envelope::Call {
            id: 1,
            op: "com.example.hello.greet.say".into(),
            params: json!({ "name": "x" }),
            cap: None,
        },
    )
    .await;
    let Some(refusal) = next_envelope(&mut page).await else { panic!("closed without a refusal") };
    let Envelope::Err { id: 0, code, .. } = refusal else { panic!("refusal must be err id 0") };
    assert_eq!(code, error::AUTH_REFUSED);
    let Some(Message::Close(close_code, _)) = next_message(&mut page).await else {
        panic!("no close frame")
    };
    assert_eq!(close_code, error::AUTH_REFUSED_CLOSE_CODE);
}

#[tokio::test]
async fn silence_is_closed_after_two_seconds() {
    let (address, _key) = start().await;
    let mut page = ws::connect(address, &url(address), Some(PAGE_ORIGIN)).await.unwrap();
    let started = Instant::now();
    let Some(refusal) = next_envelope(&mut page).await else { panic!("closed without a refusal") };
    assert_eq!(refusal.error_body().unwrap().code, error::AUTH_REFUSED);
    assert!(started.elapsed() >= Duration::from_millis(1900));
    assert_eq!(next_envelope(&mut page).await, None);
}

#[tokio::test]
async fn wrong_origin_scope_and_audience_are_refused() {
    let (address, key) = start().await;
    // A token bound to another origin.
    let mut page = ws::connect(address, &url(address), Some(PAGE_ORIGIN)).await.unwrap();
    send(&page, Envelope::Auth { token: key.sign(&claims(&[SCOPE], Some("http://evil.test"))) })
        .await;
    assert_eq!(
        next_envelope(&mut page).await.unwrap().error_body().unwrap().code,
        error::AUTH_REFUSED
    );
    // A token for another provider.
    let mut page = ws::connect(address, &url(address), Some(PAGE_ORIGIN)).await.unwrap();
    let mut other = claims(&[SCOPE], Some(PAGE_ORIGIN));
    other.aud = "cmux.git".into();
    send(&page, Envelope::Auth { token: key.sign(&other) }).await;
    assert_eq!(
        next_envelope(&mut page).await.unwrap().error_body().unwrap().code,
        error::AUTH_REFUSED
    );
    // A valid token without the op's scope.
    let mut page = ws::connect(address, &url(address), Some(PAGE_ORIGIN)).await.unwrap();
    send(&page, Envelope::Auth { token: key.sign(&claims(&["git:read"], Some(PAGE_ORIGIN))) })
        .await;
    assert!(matches!(next_envelope(&mut page).await, Some(Envelope::Ok { .. })));
    send(
        &page,
        Envelope::Call {
            id: 1,
            op: "com.example.hello.greet.say".into(),
            params: json!({ "name": "x" }),
            cap: None,
        },
    )
    .await;
    assert_eq!(
        next_envelope(&mut page).await.unwrap().error_body().unwrap().code,
        error::FORBIDDEN
    );
}

#[tokio::test]
async fn foreign_origin_and_rebound_host_fail_the_upgrade() {
    let (address, _key) = start().await;
    assert!(ws::connect(address, &url(address), Some("http://evil.test")).await.is_err());
    let rebound = format!("ws://evil.test:{}/", address.port());
    assert!(ws::connect(address, &rebound, None).await.is_err());
    assert!(ws::connect(address, &url(address), None).await.is_ok());
}

#[tokio::test]
async fn bundled_page_origin_must_match_the_token_exactly() {
    let (address, key) = start().await;
    let good = "cmux-page://cmux.settings";
    let mut page = ws::connect(address, &url(address), Some(good)).await.unwrap();
    send(&page, Envelope::Auth { token: key.sign(&claims(&[SCOPE], Some(good))) }).await;
    assert!(matches!(next_envelope(&mut page).await, Some(Envelope::Ok { id: 0, .. })));
    let mut other =
        ws::connect(address, &url(address), Some("cmux-page://com.evil.page")).await.unwrap();
    send(&other, Envelope::Auth { token: key.sign(&claims(&[SCOPE], Some(good))) }).await;
    assert_eq!(
        next_envelope(&mut other).await.unwrap().error_body().unwrap().code,
        error::AUTH_REFUSED
    );
}

/// The status line the listener answers to a raw upgrade request with these header lines.
async fn upgrade_status(address: std::net::SocketAddr, headers: &[&str]) -> String {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let mut stream = tokio::net::TcpStream::connect(address).await.unwrap();
    let mut request = String::from(
        "GET / HTTP/1.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\
         Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n",
    );
    for header in headers {
        request.push_str(header);
        request.push_str("\r\n");
    }
    request.push_str("\r\n");
    stream.write_all(request.as_bytes()).await.unwrap();
    let mut reply = Vec::new();
    let mut buffer = [0_u8; 512];
    while !reply.windows(2).any(|pair| pair == b"\r\n") {
        let read = tokio::time::timeout(Duration::from_secs(5), stream.read(&mut buffer))
            .await
            .expect("the listener answered the upgrade")
            .unwrap_or(0);
        if read == 0 {
            break;
        }
        reply.extend_from_slice(&buffer[..read]);
    }
    String::from_utf8_lossy(&reply).lines().next().unwrap_or("").to_owned()
}

/// The loopback listener rules (cmux-local-auth) at the wire: a request whose Host is not
/// this listener's loopback name, is missing or repeated, or whose Origin is `null`, foreign or
/// repeated never upgrades; the listener's own Host with no Origin (a non-browser client) and
/// with the allowed page origin does.
#[tokio::test]
async fn hostile_host_and_origin_headers_never_upgrade() {
    let (address, _key) = start().await;
    let port = address.port();
    let host = format!("Host: 127.0.0.1:{port}");
    let localhost = format!("Host: localhost:{port}");
    let page = format!("Origin: {PAGE_ORIGIN}");
    let ok = upgrade_status(address, &[&host]).await;
    assert!(ok.starts_with("HTTP/1.1 101"), "no-origin client: {ok}");
    let ok = upgrade_status(address, &[&localhost, &page]).await;
    assert!(ok.starts_with("HTTP/1.1 101"), "allowed page origin: {ok}");

    let rebound = format!("Host: evil.test:{port}");
    let suffixed = format!("Host: 127.0.0.1.evil.test:{port}");
    let userinfo = format!("Host: 127.0.0.1:{port}@evil.test");
    let refused: [(&str, Vec<&str>); 9] = [
        ("missing Host", vec![]),
        ("rebound Host", vec![&rebound]),
        ("suffixed loopback Host", vec![&suffixed]),
        ("Host with userinfo", vec![&userinfo]),
        ("repeated Host", vec![&host, &localhost]),
        ("null Origin", vec![&host, "Origin: null"]),
        ("foreign Origin", vec![&host, "Origin: http://evil.test"]),
        ("repeated Origin", vec![&host, &page, &page]),
        ("Origin on another port", vec![&host, "Origin: http://127.0.0.1:4101"]),
    ];
    for (case, headers) in refused {
        let status = upgrade_status(address, &headers).await;
        assert!(!status.starts_with("HTTP/1.1 101"), "{case} upgraded: {status}");
    }
}
