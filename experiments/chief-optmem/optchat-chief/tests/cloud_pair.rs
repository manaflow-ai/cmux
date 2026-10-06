//! `optchat-chief cloud pair`: the brain host pairs like a cmux server
//! (plans/cmux-next/server.md 6.2). It proves its install key to
//! `POST /v1/pair/begin`, shows the code, waits on `GET /v1/pair/wait`
//! (WebSocket) until the user approves it in the app ("Server > Add
//! Server…"), then finds the chief the app placed on its install.

use std::io::Write as _;
use std::net::TcpListener;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use optchat_chief::cloud::auth::{Http, InstallFile, verify};
use optchat_chief::cloud::pair::{
    self, PairOptions, Waited, begin_proof, fingerprint_words, jwk_thumbprint, placed_chief,
    wait_url,
};
use serde_json::{Value, json};
use tungstenite::handshake::server::{Request, Response};
use tungstenite::protocol::CloseFrame;
use tungstenite::protocol::frame::coding::CloseCode;
use tungstenite::{Message, accept_hdr};

const INSTALL: &str = "inst_01PAIRED";
const CHIEF: &str = "agent_01CHIEFPLACED";
const OTHER: &str = "agent_01CHIEFDEFAULT";

// ---------------------------------------------------------------- pure parts

#[test]
fn the_thumbprint_is_rfc7638_over_the_required_members() {
    // RFC 7638 section 3.1 uses RSA; this vector is the P-256 key of RFC 7517 A.1
    // with its thumbprint computed over {"crv","kty","x","y"} in that order.
    let jwk = json!({"kty": "EC", "crv": "P-256",
        "x": "MKBCTNIcKUSDii11ySs3526iDZ8AiTo7Tu6KPAqv7D4",
        "y": "4Etl6SRW2YiLUrN5vfvVHuhp7x8PxltmWWlbbM4IFyM", "use": "enc", "kid": "1"});
    assert_eq!(
        jwk_thumbprint(&jwk).unwrap(),
        "cn-I_WNMClehiVp51i_0VpOENW1upEerA8sEam5hn-s"
    );
    assert!(jwk_thumbprint(&json!({"kty": "EC"})).is_err());
}

#[test]
fn the_begin_proof_is_the_message_the_worker_checks() {
    assert_eq!(
        begin_proof("staging", "THUMB", "WG=", 1_700_000_000_000),
        "cmux-pair-begin\nstaging\nTHUMB\nWG=\n1700000000000"
    );
}

#[test]
fn fingerprint_words_match_the_app() {
    // The app's PairingWords: SHA-256 of the 32 thumbprint bytes, 4 x 11 bits into BIP-39.
    let words = fingerprint_words("cn-I_WNMClehiVp51i_0VpOENW1upEerA8sEam5hn-s").unwrap();
    assert_eq!(words.len(), 4);
    assert!(words.iter().all(|w| !w.is_empty()));
    assert!(fingerprint_words("not base64url!").is_none());
    assert!(fingerprint_words("AAAA").is_none(), "only 32-byte thumbprints");
}

#[test]
fn the_wait_url_follows_the_api_scheme() {
    assert_eq!(
        wait_url("https://cloud-api-staging.cmux.dev", "7KQ4M2XD").unwrap(),
        "wss://cloud-api-staging.cmux.dev/v1/pair/wait?code=7KQ4M2XD"
    );
    assert_eq!(
        wait_url("http://127.0.0.1:9", "7KQ4M2XD").unwrap(),
        "ws://127.0.0.1:9/v1/pair/wait?code=7KQ4M2XD"
    );
    assert!(wait_url("ftp://x", "7KQ4M2XD").is_err());
}

#[test]
fn a_new_install_has_a_wireguard_key() {
    let file = InstallFile::generate("https://api.example.test").unwrap();
    let public = file.wg_public().unwrap();
    assert_eq!(public.len(), 44);
    assert!(public.ends_with('='));
    assert!(
        public[..43]
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '+' || c == '/')
    );
    // The private key is stored; the public key is derived from it, so it is stable.
    assert!(file.wg_private.is_some());
    assert_eq!(file.wg_public().unwrap(), public);
}

#[test]
fn the_placed_chief_wins_and_default_is_only_a_fallback() {
    let list = json!({"chiefs": [
        {"id": OTHER, "is_default": true, "archived_at": null, "main_conversation": "conv_D", "brain_place": null},
        {"id": CHIEF, "is_default": false, "archived_at": null, "main_conversation": "conv_P",
         "brain_place": {"host": "host_01X", "install": INSTALL}},
    ], "tombstones": []});
    assert_eq!(placed_chief(&list, INSTALL, false).unwrap()["id"], CHIEF);
    assert_eq!(placed_chief(&list, INSTALL, true).unwrap()["id"], CHIEF);
    assert!(placed_chief(&list, "inst_other", false).is_none());
    assert_eq!(placed_chief(&list, "inst_other", true).unwrap()["id"], OTHER);
    // An archived chief never counts, and a backend without brain_place falls back.
    let old = json!({"chiefs": [
        {"id": CHIEF, "is_default": false, "archived_at": "2026-10-01T00:00:00.000Z", "main_conversation": "conv_P",
         "brain_place": {"host": "host_01X", "install": INSTALL}},
        {"id": OTHER, "is_default": true, "archived_at": null, "main_conversation": "conv_D"},
    ]});
    assert!(placed_chief(&old, INSTALL, false).is_none());
    assert_eq!(placed_chief(&old, INSTALL, true).unwrap()["id"], OTHER);
}

// ---------------------------------------------------------------- the flow

/// The Worker: health, begin (checks the proof), the token routes and chief.list.
struct FakeApi {
    calls: Mutex<Vec<(String, Value)>>,
    /// chief.list replies, one per read (the last repeats).
    lists: Mutex<Vec<Value>>,
}

impl FakeApi {
    fn new(lists: Vec<Value>) -> Arc<FakeApi> {
        Arc::new(FakeApi {
            calls: Mutex::new(Vec::new()),
            lists: Mutex::new(lists),
        })
    }
}

impl Http for FakeApi {
    fn get(&self, url: &str) -> Result<Value, String> {
        self.calls
            .lock()
            .unwrap()
            .push((url.to_owned(), Value::Null));
        if url.ends_with("/v1/health") {
            Ok(json!({"ok": true, "environment": "staging", "version": "0.1.0"}))
        } else {
            Err(format!("unexpected GET {url}"))
        }
    }

    fn post(&self, url: &str, body: &Value, _bearer: Option<&str>) -> Result<Value, String> {
        self.calls
            .lock()
            .unwrap()
            .push((url.to_owned(), body.clone()));
        if url.ends_with("/v1/pair/begin") {
            let thumb = jwk_thumbprint(&body["public_jwk"])?;
            let proof = begin_proof(
                "staging",
                &thumb,
                body["wg_public_key"].as_str().unwrap(),
                body["issued_at"].as_u64().unwrap(),
            );
            if !verify(
                &body["public_jwk"],
                &proof,
                body["signature"].as_str().unwrap(),
            ) {
                return Err("HTTP 403: proof of possession failed".into());
            }
            Ok(json!({"code": "7KQ4M2XD", "display": "7KQ4-M2XD", "expires_at": now_ms() + 600_000,
                "collect_secret": "NONCE.MAC", "thumbprint": thumb,
                "verification_uri": "http://localhost:3010/pair?c=7KQ4M2XD"}))
        } else if url.ends_with("/v1/auth/challenge") {
            Ok(
                json!({"nonce": "n", "message_prefix": format!("cmux-auth-v1\nstaging\n{}\n", body["install"].as_str().unwrap())}),
            )
        } else if url.ends_with("/v1/auth/token") {
            assert!(
                body.get("agent").is_none(),
                "chief.list runs with the install token, not a chief token"
            );
            Ok(json!({"access_token": "jwt-install", "expires_at": now_ms() + 600_000}))
        } else if url.ends_with("/v1/read") && body["op"] == "chief.list" {
            let mut lists = self.lists.lock().unwrap();
            let next = if lists.len() > 1 {
                lists.remove(0)
            } else {
                lists[0].clone()
            };
            Ok(json!({"value": next}))
        } else {
            Err(format!("unexpected POST {url}"))
        }
    }
}

fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_millis() as u64
}

/// One PairingDO wait socket on 127.0.0.1: checks the code and the collect
/// subprotocol, answers `cmux.pair.v1`, then sends `frames` and closes with `close`.
fn serve_wait(frames: Vec<Value>, close: Option<u16>) -> (String, std::thread::JoinHandle<String>) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let api = format!("http://{}", listener.local_addr().unwrap());
    let handle = std::thread::spawn(move || {
        let (stream, _) = listener.accept().unwrap();
        let seen = Arc::new(Mutex::new(String::new()));
        let seen_cb = seen.clone();
        let mut ws = accept_hdr(stream, move |req: &Request, mut resp: Response| {
            let protocols = req
                .headers()
                .get("Sec-WebSocket-Protocol")
                .and_then(|v| v.to_str().ok())
                .unwrap_or("")
                .to_owned();
            *seen_cb.lock().unwrap() = format!("{} {}", req.uri(), protocols);
            resp.headers_mut()
                .insert("Sec-WebSocket-Protocol", "cmux.pair.v1".parse().unwrap());
            Ok(resp)
        })
        .unwrap();
        for f in frames {
            ws.send(Message::text(f.to_string())).unwrap();
        }
        if let Some(code) = close {
            let _ = ws.close(Some(CloseFrame {
                code: CloseCode::from(code),
                reason: "".into(),
            }));
            // Drain until the peer acknowledges the close.
            while ws.read().is_ok() {}
        } else {
            while ws.read().is_ok() {}
        }
        let out = seen.lock().unwrap().clone();
        out
    });
    (api, handle)
}

fn paired_frame() -> Value {
    json!({"t": "paired", "host": "host_01BRAIN", "team": "team_1", "user": "user_1", "install": INSTALL})
}

#[test]
fn the_wait_socket_sends_the_collect_secret_and_returns_the_pairing() {
    let (api, server) = serve_wait(
        vec![
            json!({"t": "pending", "expires_at": now_ms() + 60_000}),
            paired_frame(),
        ],
        Some(1000),
    );
    let waited = pair::wait(&api, "7KQ4M2XD", "NONCE.MAC", now_ms() + 10_000).unwrap();
    match waited {
        Waited::Paired(p) => {
            assert_eq!(p.install, INSTALL);
            assert_eq!(p.host, "host_01BRAIN");
            assert_eq!(p.team, "team_1");
            assert_eq!(p.user, "user_1");
        }
        other => panic!("expected paired, got {other:?}"),
    }
    let seen = server.join().unwrap();
    assert!(seen.contains("/v1/pair/wait?code=7KQ4M2XD"), "{seen}");
    assert!(seen.contains("cmux.pair.v1"), "{seen}");
    assert!(seen.contains("collect.NONCE.MAC"), "{seen}");
}

#[test]
fn a_refused_frame_or_close_4403_is_refused() {
    let (api, server) = serve_wait(vec![json!({"t": "refused"})], Some(4403));
    assert!(matches!(
        pair::wait(&api, "7KQ4M2XD", "S", now_ms() + 10_000).unwrap(),
        Waited::Refused
    ));
    server.join().unwrap();
    let (api, server) = serve_wait(vec![], Some(4403));
    assert!(matches!(
        pair::wait(&api, "7KQ4M2XD", "S", now_ms() + 10_000).unwrap(),
        Waited::Refused
    ));
    server.join().unwrap();
}

#[test]
fn a_code_that_runs_out_is_expired() {
    // The server keeps the socket open with only "pending": the deadline ends the wait.
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let api = format!("http://{}", listener.local_addr().unwrap());
    let server = std::thread::spawn(move || {
        let (stream, _) = listener.accept().unwrap();
        let mut ws = accept_hdr(stream, |_: &Request, mut resp: Response| {
            resp.headers_mut()
                .insert("Sec-WebSocket-Protocol", "cmux.pair.v1".parse().unwrap());
            Ok(resp)
        })
        .unwrap();
        ws.send(Message::text(json!({"t": "pending", "expires_at": 1}).to_string()))
            .unwrap();
        while ws.read().is_ok() {}
    });
    let started = std::time::Instant::now();
    assert!(matches!(
        pair::wait(&api, "7KQ4M2XD", "S", now_ms() + 1_500).unwrap(),
        Waited::Expired
    ));
    assert!(started.elapsed() < Duration::from_secs(10));
    drop(server);
}

#[test]
fn pair_begins_waits_and_stores_the_install_and_the_placed_chief() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("cloud/install.json");
    let (api, server) = serve_wait(vec![paired_frame()], Some(1000));
    let unplaced = json!({"chiefs": [{"id": OTHER, "is_default": true, "archived_at": null,
        "main_conversation": "conv_D", "brain_place": null}]});
    let placed = json!({"chiefs": [
        {"id": OTHER, "is_default": true, "archived_at": null, "main_conversation": "conv_D", "brain_place": null},
        {"id": CHIEF, "is_default": false, "archived_at": null, "main_conversation": "conv_P",
         "brain_place": {"host": "host_01BRAIN", "install": INSTALL}}]});
    let http = FakeApi::new(vec![unplaced, placed]);
    let mut out = Vec::new();
    let summary = pair::pair(
        http.clone(),
        &path,
        &api,
        &PairOptions {
            name: Some("cmux-lawrence".into()),
            default_fallback: false,
            wait_chief: Duration::from_secs(5),
            poll: Duration::from_millis(10),
        },
        &mut out,
    )
    .unwrap();
    server.join().unwrap();
    let printed = String::from_utf8(out).unwrap();
    assert!(printed.contains("7KQ4-M2XD"), "{printed}");
    assert!(
        !printed.contains("NONCE.MAC"),
        "the collect secret is never printed"
    );
    assert!(summary.contains(CHIEF), "{summary}");

    let file = InstallFile::load(&path).unwrap();
    assert_eq!(file.install.as_deref(), Some(INSTALL));
    assert_eq!(file.user.as_deref(), Some("user_1"));
    assert_eq!(file.host.as_deref(), Some("host_01BRAIN"));
    assert_eq!(file.team.as_deref(), Some("team_1"));
    assert_eq!(file.chief.as_deref(), Some(CHIEF));
    assert_eq!(file.conversation.as_deref(), Some("conv_P"));
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(
            std::fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o600
        );
    }

    let calls = http.calls.lock().unwrap();
    let begin = calls
        .iter()
        .find(|(u, _)| u.ends_with("/v1/pair/begin"))
        .unwrap();
    let info = &begin.1["info"];
    assert_eq!(info["name"], "cmux-lawrence");
    assert!(matches!(info["platform"].as_str(), Some("macos" | "linux")));
    assert!(matches!(info["arch"].as_str(), Some("aarch64" | "x86_64")));
    assert!(
        info["cmux_version"]
            .as_str()
            .unwrap()
            .starts_with("optchat-chief/")
    );
    assert!(begin.1["public_jwk"].get("d").is_none());
    assert_eq!(begin.1["wg_public_key"], file.wg_public().unwrap());
}

#[test]
fn pair_falls_back_to_the_default_chief_only_when_asked() {
    let list = json!({"chiefs": [{"id": OTHER, "is_default": true, "archived_at": null,
        "main_conversation": "conv_D"}]});
    let opts = |fallback| PairOptions {
        name: None,
        default_fallback: fallback,
        wait_chief: Duration::from_millis(50),
        poll: Duration::from_millis(10),
    };

    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("install.json");
    let (api, server) = serve_wait(vec![paired_frame()], Some(1000));
    let err = pair::pair(
        FakeApi::new(vec![list.clone()]),
        &path,
        &api,
        &opts(false),
        &mut std::io::sink(),
    )
    .unwrap_err();
    server.join().unwrap();
    assert!(err.contains("no chief"), "{err}");
    // Paired is kept even when no chief was placed yet: `cloud pair` again resumes at the chief step.
    let file = InstallFile::load(&path).unwrap();
    assert_eq!(file.install.as_deref(), Some(INSTALL));
    assert!(file.chief.is_none());

    let summary = pair::pair(
        FakeApi::new(vec![list]),
        &path,
        &api,
        &opts(true),
        &mut std::io::sink(),
    )
    .unwrap();
    assert!(summary.contains(OTHER), "{summary}");
    assert_eq!(
        InstallFile::load(&path).unwrap().conversation.as_deref(),
        Some("conv_D")
    );
}

#[test]
fn pair_refuses_an_install_that_already_has_a_chief() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("install.json");
    let mut file = InstallFile::generate("https://api.example.test").unwrap();
    file.install = Some(INSTALL.into());
    file.chief = Some(CHIEF.into());
    file.save(&path).unwrap();
    let err = pair::pair(
        FakeApi::new(vec![json!({"chiefs": []})]),
        &path,
        "https://api.example.test",
        &PairOptions::default(),
        &mut std::io::sink(),
    )
    .unwrap_err();
    assert!(err.contains("paired already"), "{err}");
    let _ = std::io::stdout().flush();
}
