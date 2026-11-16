//! `cmux device invite` through the device routing (`device_args`, then `run`) against a fake
//! cmux platform on a loopback port: what it mints, with which credential, and what it refuses
//! before minting.

use std::io::{Read as _, Write as _};
use std::net::TcpListener;
use std::sync::mpsc;

use serde_json::{Value, json};

const CREDENTIAL: &str = "cmux-access-credential-0123456789";
const TOKEN: &str = "cmj_AbCdEfGh0123456789_-xyz";

/// A platform that mints one join token per request; every raw request goes to the channel.
fn fake_platform() -> (String, mpsc::Receiver<String>) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let origin = format!("http://{}", listener.local_addr().unwrap());
    let (sender, requests) = mpsc::channel();
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(mut stream) = stream else { return };
            let mut buffer = Vec::new();
            let mut chunk = [0_u8; 4096];
            let request = loop {
                let n = stream.read(&mut chunk).unwrap_or(0);
                buffer.extend_from_slice(&chunk[..n]);
                let text = String::from_utf8_lossy(&buffer).to_string();
                let Some(end) = text.find("\r\n\r\n") else {
                    if n == 0 {
                        break text;
                    }
                    continue;
                };
                let length = text[..end]
                    .lines()
                    .find_map(|l| {
                        l.to_ascii_lowercase()
                            .strip_prefix("content-length: ")
                            .and_then(|v| v.trim().parse::<usize>().ok())
                    })
                    .unwrap_or(0);
                if buffer.len() >= end + 4 + length || n == 0 {
                    break text;
                }
            };
            let (status, body) = if request.starts_with("POST /v1/machines/join-tokens ") {
                let answer = json!({
                    "token": TOKEN,
                    "joinTokenId": "jt_1",
                    "expiresAt": 4_102_444_800_000_u64,
                    "teamId": "team_1",
                    "label": "build-box",
                });
                (200, answer.to_string())
            } else {
                (404, json!({"code": "machine.not_found"}).to_string())
            };
            let _ = stream.write_all(
                format!(
                    "HTTP/1.1 {status} X\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{body}",
                    body.len()
                )
                .as_bytes(),
            );
            if sender.send(request).is_err() {
                return;
            }
        }
    });
    (origin, requests)
}

/// `cmux <words>` routed as the binary routes it: `device_args`, then `devices::run`.
fn cmux(words: &[&str]) -> i32 {
    let words: Vec<String> = words.iter().map(|w| (*w).to_owned()).collect();
    let rest = super::device_args(&words).expect("a device verb run by devices::run");
    super::run(&rest)
}

/// A credential file and an audit directory of the test's own.
fn scratch() -> (tempfile::TempDir, String) {
    let dir = tempfile::tempdir().unwrap();
    crate::remote_host::config::set_dir(dir.path().join("host"));
    let file = dir.path().join("credential");
    std::fs::write(&file, format!("{CREDENTIAL}\n")).unwrap();
    let path = file.to_str().unwrap().to_owned();
    (dir, path)
}

#[test]
fn device_invite_mints_one_join_token_with_the_given_credential_label_and_ttl() {
    let (origin, requests) = fake_platform();
    let (_dir, credential) = scratch();
    let code = cmux(&[
        "device",
        "invite",
        "--platform",
        &origin,
        "--cloud-token-file",
        &credential,
        "--label",
        "build-box",
        "--ttl",
        "5m",
        "--channel",
        "nightly-next",
        "--json",
    ]);
    assert_eq!(code, 0);
    let request = requests.recv().unwrap();
    assert!(request.starts_with("POST /v1/machines/join-tokens "), "{request}");
    let (head, body) = request.split_once("\r\n\r\n").unwrap();
    assert!(
        head.lines()
            .any(|l| l.eq_ignore_ascii_case(&format!("authorization: Bearer {CREDENTIAL}"))),
        "the given credential signs the mint"
    );
    assert_eq!(
        serde_json::from_str::<Value>(body).unwrap(),
        json!({"label": "build-box", "ttlSeconds": 300}),
        "no role is sent: the platform has none to enforce"
    );
    assert!(requests.try_recv().is_err(), "one mint, nothing else");
}

#[test]
fn device_invite_refuses_read_only_before_minting() {
    let (origin, requests) = fake_platform();
    let (_dir, credential) = scratch();
    for role in ["read-only", "daemon"] {
        let code = cmux(&[
            "device",
            "invite",
            "--role",
            role,
            "--platform",
            &origin,
            "--cloud-token-file",
            &credential,
        ]);
        assert_eq!(code, 2, "{role}");
    }
    assert!(requests.try_recv().is_err(), "nothing minted for a role the line cannot enforce");
}

#[test]
fn device_invite_refuses_a_channel_the_join_script_would_refuse_before_minting() {
    let (origin, requests) = fake_platform();
    let (_dir, credential) = scratch();
    for channel in ["", "Nightly", "feat/next", "a b"] {
        let code = cmux(&[
            "device",
            "invite",
            "--channel",
            channel,
            "--platform",
            &origin,
            "--cloud-token-file",
            &credential,
        ]);
        assert_eq!(code, 2, "{channel:?}");
    }
    assert!(requests.try_recv().is_err());
}
