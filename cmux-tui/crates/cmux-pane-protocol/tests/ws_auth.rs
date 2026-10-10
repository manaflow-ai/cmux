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
