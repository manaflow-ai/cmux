//! The tunnel methods against a fake platform: an HTTP/1.1 server on loopback that records each
//! request (and the node key file as it was when the request came) and answers as told.

use super::*;
use cmux_link::key_holder::KeyFile;
use std::sync::Arc;
use std::sync::Mutex;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::sync::Notify;

const TOKEN: &str = "person-access-token";

/// One request the fake platform saw.
#[derive(Clone, Debug)]
struct Seen {
    line: String,
    headers: String,
    body: Value,
    /// The node key file's bytes when the request came in.
    key_then: Option<Vec<u8>>,
}

struct Platform {
    origin: String,
    seen: Arc<Mutex<Vec<Seen>>>,
    /// Notified when a request has come in (before it is answered).
    arrived: Arc<Notify>,
}

/// A platform that answers each request with `answer`, after `hold` (when given) is notified.
async fn platform(
    key_dir: std::path::PathBuf,
    hold: Option<Arc<Notify>>,
    answer: impl Fn(&Seen) -> (u16, Value) + Send + Sync + 'static,
) -> Platform {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let origin = format!("http://{}", listener.local_addr().unwrap());
    let seen = Arc::new(Mutex::new(Vec::new()));
    let arrived = Arc::new(Notify::new());
    let answer = Arc::new(answer);
    let (seen_in, arrived_in) = (seen.clone(), arrived.clone());
    tokio::spawn(async move {
        loop {
            let Ok((mut stream, _)) = listener.accept().await else { return };
            let mut buffer = Vec::new();
            let mut chunk = [0u8; 4096];
            let head_end = loop {
                let n = stream.read(&mut chunk).await.unwrap();
                assert!(n > 0, "request ended early");
                buffer.extend_from_slice(&chunk[..n]);
                if let Some(at) = buffer.windows(4).position(|w| w == b"\r\n\r\n") {
                    break at + 4;
                }
            };
            let head = String::from_utf8_lossy(&buffer[..head_end]).to_string();
            let length = head
                .lines()
                .find_map(|line| {
                    let (name, value) = line.split_once(':')?;
                    name.eq_ignore_ascii_case("content-length").then(|| value.trim().parse().ok())?
                })
                .unwrap_or(0usize);
            while buffer.len() < head_end + length {
                let n = stream.read(&mut chunk).await.unwrap();
                buffer.extend_from_slice(&chunk[..n]);
            }
            let body = serde_json::from_slice(&buffer[head_end..head_end + length])
                .unwrap_or(Value::Null);
            let (line, headers) = head.split_once("\r\n").unwrap();
            let request = Seen {
                line: line.to_owned(),
                headers: headers.to_ascii_lowercase(),
                body,
                key_then: std::fs::read(KeyFile::Node.path_in(&key_dir)).ok(),
            };
            seen_in.lock().unwrap().push(request.clone());
            arrived_in.notify_one();
            if let Some(hold) = &hold {
                hold.notified().await;
            }
            let (status, reply) = answer(&request);
            let text = reply.to_string();
            let response = format!(
                "HTTP/1.1 {status} X\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{text}",
                text.len()
            );
            let _ = stream.write_all(response.as_bytes()).await;
        }
    });
    Platform { origin, seen, arrived }
}

fn machine(origin: &str) -> Machine {
    Machine { id: "machine_1".into(), team: "team_1".into(), origin: origin.into() }
}

fn reason(error: &RpcError) -> &str {
    error.data.as_ref().and_then(|data| data["reason"].as_str()).unwrap_or_default()
}

#[tokio::test]
async fn attach_and_detach_name_this_machine_as_the_person() {
    let dir = tempfile::tempdir().unwrap();
    let platform = platform(dir.path().into(), None, |seen| {
        if seen.line.contains("/detach ") {
            (200, json!({"detached": true, "tunnel_id": "machine_1", "network_id": "team_1"}))
        } else {
            (200, json!({"tunnel_id": "machine_1", "network_id": "team_1", "client_public_key": "k"}))
        }
    })
    .await;
    let target = machine(&platform.origin);
    let attached = attach(&target, &json!({"networkId": "team_1"}), TOKEN, false).await.unwrap();
    assert_eq!(attached["tunnel_id"], "machine_1");
    let detached = attach(&target, &json!({}), TOKEN, true).await.unwrap();
    assert_eq!(detached["detached"], true);
    let seen = platform.seen.lock().unwrap().clone();
    assert!(seen[0].line.starts_with("POST /v1/mesh/nodes/machine_1/attach "), "{}", seen[0].line);
    assert!(seen[1].line.starts_with("POST /v1/mesh/nodes/machine_1/detach "), "{}", seen[1].line);
    for request in &seen {
        assert!(request.headers.contains(&format!("authorization: bearer {TOKEN}")));
        assert!(request.headers.contains("x-cmux-team: team_1"));
    }
}

#[tokio::test]
async fn another_teams_network_is_refused_before_any_request() {
    let dir = tempfile::tempdir().unwrap();
    let platform = platform(dir.path().into(), None, |_| (200, json!({}))).await;
    let error = attach(&machine(&platform.origin), &json!({"networkId": "team_2"}), TOKEN, false)
        .await
        .unwrap_err();
    assert_eq!(reason(&error), "network_mismatch");
    assert!(platform.seen.lock().unwrap().is_empty());
}

#[tokio::test]
async fn a_sticky_detach_reads_as_the_platforms_refusal() {
    let dir = tempfile::tempdir().unwrap();
    let platform = platform(dir.path().into(), None, |_| {
        (404, json!({"code": "mesh.node.not_found", "message": "no such node"}))
    })
    .await;
    let error = attach(&machine(&platform.origin), &json!({}), TOKEN, false).await.unwrap_err();
    assert_eq!(error.data.unwrap()["code"], "mesh.node.not_found");
}

#[test]
fn the_token_must_be_one_printable_word() {
    for bad in [json!({}), json!({"token": ""}), json!({"token": "two words"}), json!({"token": 7}),
                json!({"token": "a".repeat(MAX_TOKEN_BYTES + 1)})] {
        assert_eq!(reason(&token(&bad).unwrap_err()), "token_required", "{bad}");
    }
    assert_eq!(token(&json!({"token": TOKEN})).unwrap().as_str(), TOKEN);
}
