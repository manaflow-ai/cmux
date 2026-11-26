//! The published web join contract must reach the hub through the generated client.

use cmux_cloud_client::types::JoinRedeem;
use serde_json::{Value, json};
use std::time::Duration;
use tokio::io::{AsyncReadExt as _, AsyncWriteExt as _};
use tokio::net::TcpListener;

const KEY: &str = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";

fn request() -> Value {
    json!({
        "token": "cmj_test_join_token",
        "platform": "web",
        "hostname": "web",
        "wgPublicKey": KEY,
        "capabilities": [],
    })
}

// One request per listener. The read deadline also bounds a broken client test.
async fn hub(
    status: u16,
    response: Value,
    headers: String,
) -> (String, tokio::task::JoinHandle<String>) {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let origin = format!("http://{}", listener.local_addr().unwrap());
    let task = tokio::spawn(async move {
        tokio::time::timeout(Duration::from_secs(5), async move {
            let (mut stream, _) = listener.accept().await.unwrap();
            let mut bytes = Vec::new();
            loop {
                let mut buffer = [0; 1024];
                let count = stream.read(&mut buffer).await.unwrap();
                assert_ne!(count, 0, "request ended before its body");
                bytes.extend_from_slice(&buffer[..count]);
                if let Some(end) = bytes.windows(4).position(|v| v == b"\r\n\r\n") {
                    let head = String::from_utf8_lossy(&bytes[..end]);
                    let length: usize = head.lines().find_map(|line| {
                        let (name, value) = line.split_once(':')?;
                        name.eq_ignore_ascii_case("content-length").then(|| value.trim().parse().unwrap())
                    }).unwrap();
                    if bytes.len() >= end + 4 + length {
                        break;
                    }
                }
            }
            let body = response.to_string();
            let reply = format!("HTTP/1.1 {status} Test\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n{headers}\r\n{body}", body.len());
            stream.write_all(reply.as_bytes()).await.unwrap();
            String::from_utf8(bytes).unwrap()
        }).await.unwrap()
    });
    (origin, task)
}

fn client(origin: &str) -> cmux_cloud_client::Client {
    let _ = rustls::crypto::ring::default_provider().install_default();
    cmux_build_space::init_process(Ok(None));
    cmux_cloud_client::client_for(origin, None, None, "web-redeem-test", Duration::from_secs(5))
        .unwrap()
}

fn check_wire(seen: &str) {
    let (headers, body) = seen.split_once("\r\n\r\n").unwrap();
    assert!(headers.starts_with("POST /v1/machines/join-tokens/redeem HTTP/1.1\r\n"));
    assert!(!headers.to_ascii_lowercase().contains("authorization:"));
    assert_eq!(serde_json::from_str::<Value>(body).unwrap(), request());
}

#[tokio::test]
async fn web_redeem_sends_the_published_shape_without_privileges() {
    let answer = json!({
        "credential": "cmm_test_device_credential",
        "machineId": "machine_web", "joinTokenId": "join_web", "teamId": "team_web",
        "wgPublicKey": KEY, "userId": "user_web",
    });
    let (origin, seen) = hub(200, answer.clone(), String::new()).await;
    let body: JoinRedeem = serde_json::from_value(request()).unwrap();
    let redeemed = client(&origin).machine_redeem_redeem(&body).await.unwrap().into_inner();
    assert_eq!(serde_json::to_value(redeemed).unwrap(), answer);
    check_wire(&seen.await.unwrap());
}

#[tokio::test]
async fn web_redeem_old_or_unavailable_hubs_remain_refusals() {
    for status in [400, 401, 404, 410, 503] {
        let (origin, seen) =
            hub(status, json!({"message": "web unavailable"}), String::new()).await;
        let body: JoinRedeem = serde_json::from_value(request()).unwrap();
        let error = client(&origin).machine_redeem_redeem(&body).await.unwrap_err();
        assert_eq!(cmux_cloud_client::ApiError::from_api(error).await.status, Some(status));
        check_wire(&seen.await.unwrap());
    }
}

#[tokio::test]
async fn web_redeem_does_not_forward_join_tokens_on_redirect() {
    let other = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    other.set_nonblocking(true).unwrap();
    let location = format!("Location: http://{}/stolen\r\n", other.local_addr().unwrap());
    let (origin, seen) = hub(307, json!({}), location).await;
    let body: JoinRedeem = serde_json::from_value(request()).unwrap();
    let error = client(&origin).machine_redeem_redeem(&body).await.unwrap_err();
    assert_eq!(cmux_cloud_client::ApiError::from_api(error).await.status, Some(307));
    check_wire(&seen.await.unwrap());
    // A followed redirect would connect before the request above could finish.
    assert_eq!(other.accept().unwrap_err().kind(), std::io::ErrorKind::WouldBlock);
}

#[tokio::test]
async fn web_redeem_rejects_a_success_without_machine_identity() {
    let (origin, seen) =
        hub(200, json!({"credential": "cmm_test_device_credential"}), String::new()).await;
    let body: JoinRedeem = serde_json::from_value(request()).unwrap();
    assert!(client(&origin).machine_redeem_redeem(&body).await.is_err());
    check_wire(&seen.await.unwrap());
}

#[test]
fn web_redeem_keeps_native_platforms_and_rejects_unknown_platforms() {
    for platform in ["macos", "linux", "windows", "web"] {
        let mut value = request();
        value["platform"] = json!(platform);
        let body: JoinRedeem = serde_json::from_value(value.clone()).unwrap();
        assert_eq!(serde_json::to_value(body).unwrap(), value);
    }
    let mut value = request();
    value["platform"] = json!("unknown");
    assert!(serde_json::from_value::<JoinRedeem>(value).is_err());
}
