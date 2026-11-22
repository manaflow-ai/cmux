//! The browser's own email-code sign-in on the web listener (`web_device.rs`).

use std::sync::{Arc, Mutex};
use std::time::Duration;

use base64::Engine;
use serde_json::{Value, json};
use tokio::sync::mpsc;

use super::*;
use crate::machine_record::MachineCredential;

const PAGE: &str = "https://browser.example.test";

fn key() -> String {
    base64::engine::general_purpose::STANDARD.encode([7u8; 32])
}

fn reason(error: &RpcError) -> &str {
    error.data.as_ref().and_then(|d| d["reason"].as_str()).unwrap_or_default()
}

/// One request a fake Stack saw: its path and JSON body.
type Seen = Arc<Mutex<Vec<(String, Value)>>>;

/// A fake Stack API on loopback: `respond(path, body)` answers each request.
async fn fake_stack(
    respond: impl Fn(&str, &Value) -> (u16, Value) + Send + Sync + 'static,
) -> (String, Seen) {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}", listener.local_addr().unwrap());
    let seen: Seen = Arc::default();
    let log = seen.clone();
    let respond = Arc::new(respond);
    tokio::spawn(async move {
        while let Ok((mut stream, _)) = listener.accept().await {
            let mut bytes = Vec::new();
            let (head_len, body_len) = loop {
                let mut chunk = [0; 4096];
                let n = stream.read(&mut chunk).await.unwrap_or(0);
                if n == 0 {
                    break (0, 0);
                }
                bytes.extend_from_slice(&chunk[..n]);
                if let Some(end) = bytes.windows(4).position(|w| w == b"\r\n\r\n") {
                    let head = String::from_utf8_lossy(&bytes[..end]).to_ascii_lowercase();
                    let length = head
                        .lines()
                        .find_map(|l| l.strip_prefix("content-length:"))
                        .and_then(|v| v.trim().parse::<usize>().ok())
                        .unwrap_or(0);
                    break (end + 4, length);
                }
            };
            if head_len == 0 {
                continue;
            }
            while bytes.len() < head_len + body_len {
                let mut chunk = [0; 4096];
                let n = stream.read(&mut chunk).await.unwrap_or(0);
                if n == 0 {
                    break;
                }
                bytes.extend_from_slice(&chunk[..n]);
            }
            let head = String::from_utf8_lossy(&bytes[..head_len]).into_owned();
            let path = head.split(' ').nth(1).unwrap_or_default().to_owned();
            let body = bytes
                .get(head_len..head_len + body_len)
                .and_then(|b| serde_json::from_slice(b).ok())
                .unwrap_or(Value::Null);
            let (status, answer) = respond(&path, &body);
            log.lock().unwrap().push((path, body));
            let answer = answer.to_string();
            let reply = format!(
                "HTTP/1.1 {status} X\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{answer}",
                answer.len()
            );
            let _ = stream.write_all(reply.as_bytes()).await;
        }
    });
    (url, seen)
}

fn config_at(url: &str) -> SignInConfig {
    let mut stack = cmux_stack_auth::StackConfig::new(url, "project", "key");
    stack.transport_retries = 0;
    stack.request_timeout = Duration::from_secs(10);
    SignInConfig {
        owner_user_id: "owner".into(),
        stack,
        callback_url: "https://account.example.test/auth/callback".into(),
    }
}

#[test]
fn the_owner_and_stack_project_come_from_the_join_record_only() {
    let joined = MachineCredential {
        hub_origin: cmux_cloud_environment::PRODUCTION_PLATFORM.into(),
        user_id: Some("user_owner".into()),
        ..Default::default()
    };
    let config = sign_in_config(Some(&joined)).unwrap();
    assert_eq!(config.owner_user_id, "user_owner");
    assert_eq!(config.stack.base_url, cmux_cloud_environment::STACK_ORIGIN);
    assert_eq!(config.stack.project_id, cmux_cloud_environment::PRODUCTION_STACK_PROJECT);
    assert_eq!(config.callback_url, "https://cmux.com/auth/callback");

    // Each missing trusted input is named; none is invented.
    let cases = [
        (None, "machineJoin"),
        (Some(MachineCredential { revoked: true, ..joined.clone() }), "machineJoin"),
        (Some(MachineCredential { user_id: None, ..joined.clone() }), "ownerUserId"),
        (
            Some(MachineCredential { hub_origin: "https://hub.example.test".into(), ..joined }),
            "stackDeployment",
        ),
    ];
    for (record, missing) in cases {
        let error = sign_in_config(record.as_ref()).unwrap_err();
        assert_eq!(reason(&error), "signin.unconfigured", "{error:?}");
        assert_eq!(error.data.as_ref().unwrap()["missing"], missing, "{error:?}");
    }
}

#[tokio::test]
async fn an_unconfigured_daemon_refuses_before_any_email_is_sent() {
    let pending = Mutex::new(None);
    let params = json!({"email": "owner@example.test", "publicKey": key()});
    let error = start_with(&pending, Some(PAGE), sign_in_config(None), &params).await.unwrap_err();
    assert_eq!(reason(&error), "signin.unconfigured");
    assert!(pending.lock().unwrap().is_none());
}

#[tokio::test]
async fn a_socket_with_no_page_origin_cannot_start() {
    let (url, seen) = fake_stack(|_, _| panic!("Stack was reached")).await;
    let pending = Mutex::new(None);
    let params = json!({"email": "owner@example.test", "publicKey": key()});
    let error = start_with(&pending, None, Ok(config_at(&url)), &params).await.unwrap_err();
    assert_eq!(reason(&error), "browser.sign_in.origin_mismatch");
    assert!(seen.lock().unwrap().is_empty());
}

#[tokio::test]
async fn complete_without_a_start_refuses_and_reaches_no_one() {
    let (url, seen) = fake_stack(|_, _| panic!("Stack was reached")).await;
    let pending = Mutex::new(None);
    let error =
        complete_with(&pending, Some(PAGE), Ok(config_at(&url)), &json!({"code": "abc123"}))
            .await
            .unwrap_err();
    assert_eq!(reason(&error), "browser.sign_in.not_started");
    assert!(seen.lock().unwrap().is_empty());
}

/// The second start's nonce is the one the code is completed with, and the completion consumes
/// it even when Stack refuses the code.
#[tokio::test]
async fn a_second_start_replaces_the_first_and_complete_is_single_use() {
    let nonces = Arc::new(Mutex::new(vec!["NONCETWO", "NONCEONE"]));
    let (url, seen) = fake_stack(move |path, _| match path {
        "/api/v1/auth/otp/send-sign-in-code" => {
            (200, json!({"nonce": nonces.lock().unwrap().pop().unwrap()}))
        }
        "/api/v1/auth/otp/sign-in" => {
            (400, json!({"code": "VERIFICATION_CODE_ERROR", "error": "refused"}))
        }
        _ => (404, json!({})),
    })
    .await;
    let config = config_at(&url);
    let pending = Mutex::new(None);
    let params = json!({"email": "owner@example.test", "publicKey": key()});
    for _ in 0..2 {
        let started = start_with(&pending, Some(PAGE), Ok(config.clone()), &params).await.unwrap();
        assert_eq!(started, json!({"expiresIn": 300}));
    }
    let code = json!({"code": " ABC123 "});
    let error = complete_with(&pending, Some(PAGE), Ok(config.clone()), &code).await.unwrap_err();
    assert!(reason(&error).starts_with("browser.sign_in."), "{error:?}");
    let sent = seen.lock().unwrap().clone();
    let codes: Vec<&Value> =
        sent.iter().filter(|(p, _)| p == "/api/v1/auth/otp/sign-in").map(|(_, b)| b).collect();
    assert_eq!(codes, [&json!({"code": "abc123NONCETWO"})], "{sent:?}");
    assert_eq!(
        sent[0].1,
        json!({"email": "owner@example.test", "callback_url": config.callback_url}),
        "{sent:?}"
    );
    // Used once: a retry needs a new start.
    let again = complete_with(&pending, Some(PAGE), Ok(config), &code).await.unwrap_err();
    assert_eq!(reason(&again), "browser.sign_in.not_started");
}

/// A connection served as the app's pane, the unix socket or a peer is not a web connection:
/// neither method exists for it.
#[tokio::test]
async fn only_a_web_connection_may_sign_in() {
    let mut config = crate::config::Config::default();
    config.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&config.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = crate::hub::Hub::new(config, store);
    for origin in [Origin::Local, Origin::LocalApp, Origin::Peer] {
        for m in [method::MUX_BROWSER_SIGN_IN_START, method::MUX_BROWSER_SIGN_IN_COMPLETE] {
            let error = request(
                &hub,
                origin,
                m,
                json!({"email": "a@b.c", "publicKey": key(), "code": "abc"}),
            )
            .await;
            assert_eq!(error["code"], -32601, "{origin:?} {m}: {error}");
        }
    }
    // A web connection reaches the method: with nothing started, complete is refused as such.
    let error =
        request(&hub, Origin::Web, method::MUX_BROWSER_SIGN_IN_COMPLETE, json!({"code": "abc"}))
            .await;
    assert_eq!(error["data"]["reason"], "browser.sign_in.not_started", "{error}");
}

/// The error object of one request on a fresh connection served as `origin`.
async fn request(hub: &Arc<crate::hub::Hub>, origin: Origin, m: &str, params: Value) -> Value {
    let (tx, in_rx) = mpsc::channel(16);
    let (out_tx, mut rx) = mpsc::channel(4096);
    tokio::spawn(crate::server::serve_connection_with(hub.clone(), in_rx, out_tx, origin));
    tx.send(crate::rpc::Message::request(1, m, params).to_line()).await.unwrap();
    loop {
        let line = tokio::time::timeout(Duration::from_secs(30), rx.recv()).await.unwrap().unwrap();
        let value: Value = serde_json::from_str(&line).unwrap();
        if value.get("id") == Some(&json!(1)) {
            return value.get("error").cloned().unwrap_or(Value::Null);
        }
    }
}
