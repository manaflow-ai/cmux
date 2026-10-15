//! The local router's free tier (cx-ds09i): with no account bearer, the
//! relay leases a device token from the cmux API, proven by the app's
//! attestation provider on the admin socket, and forwards with it. Real
//! `acpmux router serve`, a real admin socket, a stand-in app provider and a
//! stand-in cmux API on loopback (a debug-build-only origin).
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process starts no agent.
const HERMETIC: daemon_env::Process = daemon_env::Process::deny();

use base64::Engine as _;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::io::{BufRead, BufReader, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Stdio};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

const PURPOSE: &str = "cmux.free-tier.v1";

fn scratch(tag: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("amxf-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

/// What the stand-in cmux API answers: per path, a queue of (status, body);
/// the last entry repeats.
#[derive(Default)]
struct Api {
    answers: Vec<(String, Vec<(u16, Value)>)>,
    /// (path, authorization header, body) of every request.
    seen: Vec<(String, String, Value)>,
    challenges: u32,
}

fn now_ms() -> u64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_millis() as u64
}

/// A one-request-per-connection HTTP/1.1 server on loopback.
fn start_api(api: Arc<Mutex<Api>>) -> String {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let origin = format!("http://{}", listener.local_addr().unwrap());
    std::thread::spawn(move || {
        for stream in listener.incoming().flatten() {
            let api = api.clone();
            std::thread::spawn(move || serve_one(stream, &api));
        }
    });
    origin
}

fn serve_one(mut stream: TcpStream, api: &Mutex<Api>) {
    let mut reader = BufReader::new(stream.try_clone().unwrap());
    let mut request_line = String::new();
    if reader.read_line(&mut request_line).is_err() {
        return;
    }
    let path = request_line.split_whitespace().nth(1).unwrap_or("").to_owned();
    let (mut length, mut auth) = (0usize, String::new());
    loop {
        let mut line = String::new();
        reader.read_line(&mut line).unwrap();
        let line = line.trim_end();
        if line.is_empty() {
            break;
        }
        let (name, value) = line.split_once(':').unwrap_or((line, ""));
        match name.to_ascii_lowercase().as_str() {
            "content-length" => length = value.trim().parse().unwrap_or(0),
            "authorization" => auth = value.trim().to_owned(),
            _ => {}
        }
    }
    let mut body = vec![0u8; length];
    reader.read_exact(&mut body).unwrap();
    let body: Value = serde_json::from_slice(&body).unwrap_or(Value::Null);
    let (status, answer) = {
        let mut api = api.lock().unwrap();
        api.seen.push((path.clone(), auth, body));
        if path == "/v1/inference/free/challenge" {
            api.challenges += 1;
            (
                200,
                json!({"challenge": format!("challenge-{}", api.challenges), "expires_at": now_ms() + 300_000}),
            )
        } else if let Some((_, queue)) = api.answers.iter_mut().find(|(p, _)| *p == path) {
            if queue.len() > 1 { queue.remove(0) } else { queue[0].clone() }
        } else {
            (404, json!({"error": {"code": "not_found"}}))
        }
    };
    let text = answer.to_string();
    let _ = write!(
        stream,
        "HTTP/1.1 {status} X\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{text}",
        text.len()
    );
}

fn token_answer(token: &str) -> (u16, Value) {
    (200, json!({"token": token, "expires_at": now_ms() + 3_600_000, "token_type": "Bearer"}))
}

struct Relay {
    child: Child,
    dir: PathBuf,
}

impl Drop for Relay {
    fn drop(&mut self) {
        let _ = admin(&self.dir, json!({"op": "shutdown"}));
        let _ = self.child.wait();
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

/// `acpmux router serve` in `dir`, ready once its admin socket answers.
fn start_relay(dir: &Path, test_origin: &str) -> Relay {
    let child = daemon_env::acpmux(dir)
        .args(["router", "serve"])
        .env("ACPMUX_HOME", dir)
        .env("CMUX_ROUTER_FREE_TEST_ORIGIN", test_origin)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    let relay = Relay { child, dir: dir.to_owned() };
    let deadline = Instant::now() + Duration::from_secs(20);
    while admin(dir, json!({"op": "status"})).is_err() {
        assert!(Instant::now() < deadline, "the relay did not start");
        std::thread::sleep(Duration::from_millis(50));
    }
    relay
}

fn admin(dir: &Path, request: Value) -> std::io::Result<Value> {
    let mut stream = UnixStream::connect(dir.join("router").join("router.sock"))?;
    stream.set_read_timeout(Some(Duration::from_secs(5)))?;
    stream.write_all(format!("{request}\n").as_bytes())?;
    let mut line = String::new();
    BufReader::new(stream).read_line(&mut line)?;
    Ok(serde_json::from_str(&line).unwrap_or(Value::Null))
}

fn mint(dir: &Path) -> (String, u16) {
    let scope = json!({"harness": "fake", "session": "s1", "surfaces": [], "families": ["open_ai_chat"], "expires_at": 0});
    let key = admin(dir, json!({"op": "mint_key", "scope": scope})).unwrap()["key"]
        .as_str()
        .unwrap()
        .to_owned();
    let port = admin(dir, json!({"op": "status"})).unwrap()["port"].as_u64().unwrap() as u16;
    (key, port)
}

/// One chat request to the relay's data plane: (status, body).
fn chat(port: u16, key: &str) -> (u16, Value) {
    let body = json!({"model": "free", "messages": []}).to_string();
    let mut stream = TcpStream::connect(("127.0.0.1", port)).unwrap();
    stream.set_read_timeout(Some(Duration::from_secs(30))).unwrap();
    write!(
        stream,
        "POST /v1/chat/completions HTTP/1.1\r\nhost: 127.0.0.1:{port}\r\nauthorization: Bearer {key}\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{body}",
        body.len()
    )
    .unwrap();
    let mut text = String::new();
    stream.read_to_string(&mut text).unwrap();
    let status = text.split_whitespace().nth(1).unwrap().parse().unwrap();
    let body = text.split("\r\n\r\n").nth(1).unwrap_or("");
    // A chunked body: the JSON is the line that starts with '{'.
    let json = body.lines().find(|l| l.starts_with('{')).unwrap_or("null");
    (status, serde_json::from_str(json).unwrap_or(Value::Null))
}

/// A stand-in app that holds each answer: (arrived signal, release).
type Gate = (std::sync::mpsc::Sender<()>, std::sync::mpsc::Receiver<()>);

/// What the stand-in app was asked: (req, purpose, client_data_hash bytes, fresh_key).
type Asked = Arc<Mutex<Vec<(String, String, Vec<u8>, Option<bool>)>>>;

/// A stand-in app provider: registers, then answers every request with
/// fixed proof strings. Returns the connection (dropping it ends the provider).
fn provider(dir: &Path, origin: &str, has_key: bool, asked: Asked) -> UnixStream {
    provider_with(dir, origin, has_key, false, asked, None)
}

fn provider_with(
    dir: &Path,
    origin: &str,
    has_key: bool,
    signed_in: bool,
    asked: Asked,
    gate: Option<Gate>,
) -> UnixStream {
    let stream = UnixStream::connect(dir.join("router").join("router.sock")).unwrap();
    let mut write = stream.try_clone().unwrap();
    let register = json!({"op": "attest_provider", "version": 1, "platform": "mac", "origin": origin, "enabled": true, "managed": false, "has_key": has_key, "signed_in": signed_in});
    write.write_all(format!("{register}\n").as_bytes()).unwrap();
    let mut reader = BufReader::new(stream.try_clone().unwrap());
    let mut line = String::new();
    reader.read_line(&mut line).unwrap();
    let reply: Value = serde_json::from_str(&line).unwrap();
    assert_eq!(reply["provider"], true, "register refused: {reply}");
    std::thread::spawn(move || {
        for line in reader.lines() {
            let Ok(line) = line else { return };
            let message: Value = serde_json::from_str(&line).unwrap();
            let Some(id) = message.get("id") else { continue };
            let hash = base64::engine::general_purpose::STANDARD
                .decode(message["client_data_hash"].as_str().unwrap())
                .unwrap();
            let req = message["req"].as_str().unwrap().to_owned();
            asked.lock().unwrap().push((
                req.clone(),
                message["purpose"].as_str().unwrap_or("").to_owned(),
                hash,
                message.get("fresh_key").and_then(Value::as_bool),
            ));
            // A slow app: say the request arrived, then answer only when released.
            if let Some((arrived, release)) = &gate {
                let _ = arrived.send(());
                let _ = release.recv();
            }
            let key = "a2V5LWlkLWZvci10aGUtdGVzdC1kZXZpY2UtMDEyMzQ1Ng";
            let reply = if req == "attest" {
                json!({"id": id, "key_id": key, "attestation": "YXR0ZXN0YXRpb24", "device_token": "ZGV2aWNlLXRva2Vu"})
            } else {
                json!({"id": id, "key_id": key, "assertion": "YXNzZXJ0aW9u"})
            };
            if write.write_all(format!("{reply}\n").as_bytes()).is_err() {
                return;
            }
        }
    });
    stream
}

fn sha(text: &str) -> Vec<u8> {
    Sha256::digest(text.as_bytes()).to_vec()
}

#[test]
fn free_tier_a_signed_out_request_is_served_with_the_device_token_the_app_proved() {
    let api = Arc::new(Mutex::new(Api::default()));
    api.lock().unwrap().answers = vec![
        ("/v1/inference/free/attest".into(), vec![token_answer("free-token-1")]),
        ("/v1/inference/chat/completions".into(), vec![(200, json!({"served": true}))]),
    ];
    let origin = start_api(api.clone());
    let dir = scratch("ok");
    let relay = start_relay(&dir, &origin);
    let (key, port) = mint(&dir);
    let asked: Asked = Arc::default();

    // Before any request: no lease, nothing asked (the lease starts at the first use).
    let held = provider(&dir, &origin, false, asked.clone());
    assert_eq!(admin(&dir, json!({"op": "status"})).unwrap()["free"]["state"], "idle");
    assert!(asked.lock().unwrap().is_empty());

    let (status, body) = chat(port, &key);
    assert_eq!(status, 200, "{body}");
    assert_eq!(body["served"], true);
    {
        let asked = asked.lock().unwrap();
        assert_eq!(asked.len(), 1);
        let (req, purpose, hash, fresh) = &asked[0];
        assert_eq!((req.as_str(), purpose.as_str(), *fresh), ("attest", PURPOSE, Some(false)));
        // The hash is SHA-256 of the server challenge, exactly as the server checks it.
        assert_eq!(hash, &sha("challenge-1"));
    }
    {
        let api = api.lock().unwrap();
        let attest = api.seen.iter().find(|(p, _, _)| p == "/v1/inference/free/attest").unwrap();
        assert_eq!(attest.2["challenge"], "challenge-1");
        assert_eq!(attest.2["platform"], "mac");
        assert_eq!(attest.2["attestation"], "YXR0ZXN0YXRpb24");
        let chat = api.seen.iter().find(|(p, _, _)| p == "/v1/inference/chat/completions").unwrap();
        assert_eq!(chat.1, "Bearer free-token-1");
    }
    // The token never shows in status; the state does.
    let status_reply = admin(&dir, json!({"op": "status"})).unwrap();
    assert_eq!(status_reply["free"]["state"], "active");
    assert!(!status_reply.to_string().contains("free-token-1"));

    // A second request reuses the token: no new proof.
    assert_eq!(chat(port, &key).0, 200);
    assert_eq!(asked.lock().unwrap().len(), 1);

    // The app quits (its reader thread holds clones, so end the socket itself):
    // the token is dropped at once and nothing is forwarded.
    held.shutdown(std::net::Shutdown::Both).unwrap();
    let deadline = Instant::now() + Duration::from_secs(5);
    while admin(&dir, json!({"op": "status"})).unwrap()["free"]["provider"] == true {
        assert!(Instant::now() < deadline, "provider end not seen");
        std::thread::sleep(Duration::from_millis(20));
    }
    let forwarded =
        api.lock().unwrap().seen.iter().filter(|(p, _, _)| p.ends_with("chat/completions")).count();
    let (status, body) = chat(port, &key);
    assert_eq!(status, 503, "{body}");
    assert_eq!(body["error"]["code"], "router.no_upstream");
    let after =
        api.lock().unwrap().seen.iter().filter(|(p, _, _)| p.ends_with("chat/completions")).count();
    assert_eq!(forwarded, after);
    drop(relay);
}

#[test]
fn free_tier_a_known_key_renews_by_assertion_and_a_new_month_takes_a_fresh_key() {
    let api = Arc::new(Mutex::new(Api::default()));
    api.lock().unwrap().answers = vec![
        // The grant's month ended: the assertion is refused, then a fresh key attests.
        (
            "/v1/inference/free/token".into(),
            vec![(403, json!({"error": {"code": "free.assertion"}}))],
        ),
        ("/v1/inference/free/attest".into(), vec![token_answer("free-token-2")]),
        ("/v1/inference/chat/completions".into(), vec![(200, json!({"served": true}))]),
    ];
    let origin = start_api(api.clone());
    let dir = scratch("mon");
    let relay = start_relay(&dir, &origin);
    let (key, port) = mint(&dir);
    let asked: Asked = Arc::default();
    let _held = provider(&dir, &origin, true, asked.clone());

    assert_eq!(chat(port, &key).0, 200);
    let asked = asked.lock().unwrap();
    let kinds: Vec<_> =
        asked.iter().map(|(req, _, hash, fresh)| (req.clone(), hash.clone(), *fresh)).collect();
    assert_eq!(
        kinds,
        vec![
            ("assert".to_owned(), sha("challenge-1"), None),
            ("attest".to_owned(), sha("challenge-2"), Some(true))
        ]
    );
    let api = api.lock().unwrap();
    let token = api.seen.iter().find(|(p, _, _)| p == "/v1/inference/free/token").unwrap();
    assert_eq!(token.2["assertion"], "YXNzZXJ0aW9u");
    assert_eq!(token.2["challenge"], "challenge-1");
    drop(relay);
}

#[test]
fn free_tier_a_device_that_used_its_month_gets_the_sign_in_answer() {
    let api = Arc::new(Mutex::new(Api::default()));
    api.lock().unwrap().answers = vec![(
        "/v1/inference/free/attest".into(),
        vec![(403, json!({"error": {"code": "free.device_used"}}))],
    )];
    let origin = start_api(api.clone());
    let dir = scratch("used");
    let relay = start_relay(&dir, &origin);
    let (key, port) = mint(&dir);
    let asked: Asked = Arc::default();
    let _held = provider(&dir, &origin, false, asked.clone());

    let (status, body) = chat(port, &key);
    assert_eq!(status, 403, "{body}");
    assert_eq!(body["error"]["code"], "free.device_used");
    assert!(body["error"]["message"].as_str().unwrap().contains("Sign in"));
    let free = admin(&dir, json!({"op": "status"})).unwrap()["free"].clone();
    assert_eq!(free["state"], "used_this_month");
    assert!(free["until_ms"].as_u64().unwrap() > now_ms());
    // Refused at once until next month: no second proof, no second API call.
    assert_eq!(chat(port, &key).0, 403);
    assert_eq!(asked.lock().unwrap().len(), 1);
    drop(relay);
}

#[test]
fn free_tier_the_account_bearer_wins_and_no_proof_is_asked() {
    let api = Arc::new(Mutex::new(Api::default()));
    let origin = start_api(api.clone());
    let dir = scratch("acct");
    let relay = start_relay(&dir, &origin);
    let (key, port) = mint(&dir);
    let asked: Asked = Arc::default();
    let _held = provider(&dir, &origin, true, asked.clone());
    // An account bearer for an origin that does not answer (`.invalid`).
    let set = admin(&dir, json!({"op": "set_upstream", "origin": "https://router.invalid", "bearer": "account-bearer", "expires_at": 0})).unwrap();
    assert!(set.get("error").is_none(), "{set}");

    let (status, body) = chat(port, &key);
    assert_eq!(status, 502, "{body}");
    assert_eq!(body["error"]["code"], "router.unreachable");
    assert!(asked.lock().unwrap().is_empty());
    assert!(api.lock().unwrap().seen.is_empty());
    drop(relay);
}

#[test]
fn free_tier_a_provider_for_an_unknown_origin_is_refused() {
    let dir = scratch("orig");
    let relay = start_relay(&dir, "http://127.0.0.1:1");
    for origin in
        ["https://api.example.com", "http://127.0.0.1:2", "https://cloud-api.cmux.dev.example.com"]
    {
        let mut stream = UnixStream::connect(dir.join("router").join("router.sock")).unwrap();
        stream.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
        let register = json!({"op": "attest_provider", "version": 1, "platform": "mac", "origin": origin, "enabled": true});
        stream.write_all(format!("{register}\n").as_bytes()).unwrap();
        let mut line = String::new();
        BufReader::new(stream).read_line(&mut line).unwrap();
        let reply: Value = serde_json::from_str(&line).unwrap();
        assert_eq!(reply["error"], "provider origin refused", "{origin}: {reply}");
    }
    assert_eq!(admin(&dir, json!({"op": "status"})).unwrap()["free"]["provider"], false);
    drop(relay);
}

#[test]
fn free_tier_a_signed_in_app_never_takes_a_free_lease() {
    let api = Arc::new(Mutex::new(Api::default()));
    let origin = start_api(api.clone());
    let dir = scratch("sgin");
    let relay = start_relay(&dir, &origin);
    let (key, port) = mint(&dir);
    let asked: Asked = Arc::default();
    // Signed in, but the account bearer has not reached this relay yet (a restart).
    let _held = provider_with(&dir, &origin, true, true, asked.clone(), None);

    let (status, body) = chat(port, &key);
    assert_eq!(status, 503, "{body}");
    assert_eq!(body["error"]["code"], "router.no_upstream");
    assert!(asked.lock().unwrap().is_empty());
    assert!(api.lock().unwrap().seen.is_empty());
    drop(relay);
}

#[test]
fn free_tier_a_lease_in_flight_stores_no_token_after_the_setting_turns_off_or_an_account_signs_in()
{
    for change in [
        json!({"enabled": false, "managed": false, "signed_in": false}),
        json!({"enabled": true, "managed": false, "signed_in": true}),
    ] {
        let api = Arc::new(Mutex::new(Api::default()));
        api.lock().unwrap().answers = vec![
            ("/v1/inference/free/attest".into(), vec![token_answer("free-token-late")]),
            ("/v1/inference/chat/completions".into(), vec![(200, json!({"served": true}))]),
        ];
        let origin = start_api(api.clone());
        let dir = scratch("late");
        let relay = start_relay(&dir, &origin);
        let (key, port) = mint(&dir);
        let asked: Asked = Arc::default();
        let (arrived_tx, arrived) = std::sync::mpsc::channel();
        let (release, release_rx) = std::sync::mpsc::channel();
        let held = provider_with(
            &dir,
            &origin,
            false,
            false,
            asked.clone(),
            Some((arrived_tx, release_rx)),
        );

        let request = std::thread::spawn(move || chat(port, &key));
        // The app is attesting (slowly) when the person turns the setting off or signs in.
        arrived.recv_timeout(Duration::from_secs(20)).expect("the relay asked the app for a proof");
        let mut write = held.try_clone().unwrap();
        write.write_all(format!("{change}\n").as_bytes()).unwrap();
        let deadline = Instant::now() + Duration::from_secs(5);
        while admin(&dir, json!({"op": "status"})).unwrap()["free"]["state"] != "off" {
            assert!(Instant::now() < deadline, "the change was not seen: {change}");
            std::thread::sleep(Duration::from_millis(20));
        }
        release.send(()).unwrap();

        let (status, body) = request.join().unwrap();
        assert_ne!(status, 200, "{change}: {body}");
        let forwarded =
            api.lock().unwrap().seen.iter().any(|(p, _, _)| p.ends_with("chat/completions"));
        assert!(!forwarded, "{change}: a request went out with the free token");
        let free = admin(&dir, json!({"op": "status"})).unwrap()["free"].clone();
        assert_eq!(free["state"], "off", "{change}");
        held.shutdown(std::net::Shutdown::Both).unwrap();
        drop(relay);
    }
}

#[test]
fn free_tier_a_lost_attest_reply_is_followed_by_an_assertion_not_a_second_attestation() {
    let api = Arc::new(Mutex::new(Api::default()));
    api.lock().unwrap().answers = vec![
        // The server stored the grant, but the reply never arrives (a gateway error here).
        (
            "/v1/inference/free/attest".into(),
            vec![(502, json!({"error": {"code": "bad_gateway"}}))],
        ),
        ("/v1/inference/free/token".into(), vec![token_answer("free-token-after-loss")]),
        ("/v1/inference/chat/completions".into(), vec![(200, json!({"served": true}))]),
    ];
    let origin = start_api(api.clone());
    let dir = scratch("lost");
    let relay = start_relay(&dir, &origin);
    let (key, port) = mint(&dir);
    let asked: Asked = Arc::default();
    let _held = provider(&dir, &origin, false, asked.clone());

    let (status, _) = chat(port, &key);
    assert_ne!(status, 200);
    // The relay waits out its first retry delay (2 s) before it asks again.
    std::thread::sleep(Duration::from_millis(2300));
    let (status, body) = chat(port, &key);
    assert_eq!(status, 200, "{body}");
    let kinds: Vec<_> =
        asked.lock().unwrap().iter().map(|(req, _, _, fresh)| (req.clone(), *fresh)).collect();
    assert_eq!(kinds, vec![("attest".to_owned(), Some(false)), ("assert".to_owned(), None)]);
    let api = api.lock().unwrap();
    assert_eq!(api.seen.iter().filter(|(p, _, _)| p == "/v1/inference/free/attest").count(), 1);
    let chat_call = api.seen.iter().find(|(p, _, _)| p.ends_with("chat/completions")).unwrap();
    assert_eq!(chat_call.1, "Bearer free-token-after-loss");
    drop(relay);
}
