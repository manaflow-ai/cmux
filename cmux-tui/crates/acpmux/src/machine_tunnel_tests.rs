//! The tunnel methods against a fake platform: an HTTP/1.1 server on loopback that records each
//! request (and the node key file as it was when the request came) and answers as told.

use super::*;
use cmux_link::key_holder::KeyFile;
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

/// What the wg-key route answers when it takes the key: the record with the key it was sent.
fn takes_the_key(seen: &Seen) -> (u16, Value) {
    (200, json!({"machineId": "machine_1", "joinTokenId": "join_1", "teamId": "team_1",
                 "wgPublicKey": seen.body["wgPublicKey"]}))
}

fn reason(error: &RpcError) -> &str {
    error.data.as_ref().and_then(|data| data["reason"].as_str()).unwrap_or_default()
}

fn public_of(dir: &Path) -> String {
    crate::cli::mesh_node_key::load_or_create_at(dir).unwrap().public_key_b64()
}

#[tokio::test]
async fn a_rekey_sends_the_new_key_before_it_replaces_the_key_file() {
    let dir = tempfile::tempdir().unwrap();
    let old = public_of(dir.path());
    let old_bytes = std::fs::read(KeyFile::Node.path_in(dir.path())).unwrap();
    let platform = platform(dir.path().into(), None, takes_the_key).await;
    let recorded = Mutex::new(None);
    let rekeys = tokio::sync::Mutex::new(());
    let answer = rekey_once(&rekeys, &machine(&platform.origin), dir.path(), None, TOKEN, |key| {
        *recorded.lock().unwrap() = Some(key.to_owned());
        Ok(())
    })
    .await
    .unwrap();
    let seen = platform.seen.lock().unwrap().clone();
    assert_eq!(seen.len(), 1);
    assert!(seen[0].line.starts_with("POST /v1/machines/credentials/machine_1/wg-key "));
    assert!(seen[0].headers.contains(&format!("authorization: bearer {TOKEN}")));
    assert!(seen[0].headers.contains("x-cmux-team: team_1"));
    // The platform had the new key while the file still held the old one.
    assert_eq!(seen[0].key_then.as_deref(), Some(old_bytes.as_slice()));
    let new = seen[0].body["wgPublicKey"].as_str().unwrap().to_owned();
    assert_ne!(new, old);
    assert_eq!(public_of(dir.path()), new, "the key file holds the key the platform took");
    assert_eq!(answer, json!({"machineId": "machine_1", "wgPublicKey": new, "restarted": false}));
    assert_eq!(recorded.lock().unwrap().as_deref(), Some(new.as_str()));
    assert!(!answer.to_string().contains(TOKEN));
    assert!(KeyHolder::acquire(dir.path()).is_ok(), "the rekey kept the key lock");
}

#[tokio::test]
async fn a_refused_rekey_leaves_the_key_file_as_it_was() {
    for (status, code) in [(409, "machine.wg_key_in_use"), (403, "machine.revoked"), (503, "mesh.unavailable")] {
        let dir = tempfile::tempdir().unwrap();
        let old_bytes = {
            public_of(dir.path());
            std::fs::read(KeyFile::Node.path_in(dir.path())).unwrap()
        };
        let platform = platform(dir.path().into(), None, move |_| {
            (status, json!({"_tag": "Refused", "code": code, "message": "no"}))
        })
        .await;
        let rekeys = tokio::sync::Mutex::new(());
        let error = rekey_once(&rekeys, &machine(&platform.origin), dir.path(), None, TOKEN, |_| {
            panic!("a refused rekey records no key")
        })
        .await
        .unwrap_err();
        assert_eq!(reason(&error), "platform");
        let data = error.data.clone().unwrap();
        assert_eq!(data["code"], code);
        assert_eq!(data["status"], status);
        assert_eq!(data["retryable"], status == 503);
        assert_eq!(std::fs::read(KeyFile::Node.path_in(dir.path())).unwrap(), old_bytes);
        assert!(!error.message.contains(TOKEN));
    }
}

#[tokio::test]
async fn a_platform_that_answers_another_key_changes_nothing_here() {
    let dir = tempfile::tempdir().unwrap();
    let old = public_of(dir.path());
    let platform = platform(dir.path().into(), None, |_| {
        (200, json!({"wgPublicKey": "mVS8z5lKoaFVnHkPXDVWTyIkp0ZB1Cj8DbpsGh+Ibhs="}))
    })
    .await;
    let rekeys = tokio::sync::Mutex::new(());
    let error = rekey_once(&rekeys, &machine(&platform.origin), dir.path(), None, TOKEN, |_| Ok(()))
        .await
        .unwrap_err();
    assert_eq!(reason(&error), "platform");
    assert_eq!(public_of(dir.path()), old);
}

#[tokio::test]
async fn a_second_rekey_while_one_runs_is_busy() {
    let dir = tempfile::tempdir().unwrap();
    public_of(dir.path());
    let hold = Arc::new(Notify::new());
    let platform = platform(dir.path().into(), Some(hold.clone()), takes_the_key).await;
    let target = machine(&platform.origin);
    let rekeys = tokio::sync::Mutex::new(());
    let first = rekey_once(&rekeys, &target, dir.path(), None, TOKEN, |_| Ok(()));
    let second = async {
        platform.arrived.notified().await;
        let second = rekey_once(&rekeys, &target, dir.path(), None, TOKEN, |_| Ok(())).await;
        hold.notify_one();
        second
    };
    let (first, second) = tokio::join!(first, second);
    assert!(first.is_ok(), "{first:?}");
    assert_eq!(reason(&second.unwrap_err()), "busy");
    assert_eq!(platform.seen.lock().unwrap().len(), 1, "the busy rekey sent nothing");
}

#[tokio::test]
async fn a_key_lock_another_holder_has_is_refused_key_held() {
    let dir = tempfile::tempdir().unwrap();
    let old = public_of(dir.path());
    let platform = platform(dir.path().into(), None, takes_the_key).await;
    // Another holder (the link, say): this process's pid is the record.
    let other = KeyHolder::acquire(dir.path()).unwrap();
    let rekeys = tokio::sync::Mutex::new(());
    let error = rekey_once(&rekeys, &machine(&platform.origin), dir.path(), None, TOKEN, |_| Ok(()))
        .await
        .unwrap_err();
    assert_eq!(reason(&error), "key_held");
    assert_eq!(error.data.unwrap()["holderPid"], std::process::id());
    assert!(platform.seen.lock().unwrap().is_empty(), "a non-holder sent the platform nothing");
    assert_eq!(public_of(dir.path()), old);
    drop(other);
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
