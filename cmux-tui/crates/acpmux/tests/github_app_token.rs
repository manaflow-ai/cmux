//! The cmux sign-in the app lends for GitHub App tokens (`src/github_app_token.rs`): only the
//! app's own unix-socket connection, which proved the person, lends it or takes it back, and no
//! answer holds it. With it, a Mac whose `gh` has no keyring login runs a lent action with a
//! token the cmux GitHub App mints for that one repository (a stand-in cmux API on loopback),
//! and with neither login the action fails closed.
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process starts no agent; the `gh` it runs is a stand-in.
const HERMETIC: daemon_env::Process = daemon_env::Process::deny();

use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::{Message, method};
use acpmux::server::{Origin, serve_connection_with};
use futures_util::{SinkExt, StreamExt};
use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Read, Write};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::sync::{mpsc, oneshot};

/// By name, so the same test runs, and fails, on a build from before the lease.
const GITHUB_ACTION: &str = "_acpmux/github_action";
const APP_LEASE: &str = "_acpmux/github_app_lease";
const MINTED: &str = "ghs_minted0123";
const PERSON_KEY: &str = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
const BEARER: &str = "cmux-install-token";

fn hub() -> Arc<Hub> {
    let mut cfg = Config::default();
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

/// A stand-in `gh` with no keyring login: `gh auth status` passes only if a GitHub token from
/// the env reached it (this process sets a decoy `GITHUB_TOKEN`, which must not count as a
/// login). Any other command prints what it was asked and whether the minted token, and only
/// it, reached it.
fn fake_gh() {
    static ONCE: std::sync::Once = std::sync::Once::new();
    ONCE.call_once(|| {
        use std::os::unix::fs::PermissionsExt;
        let bin = std::env::temp_dir().join(format!("ghat-bin-{}", std::process::id()));
        std::fs::create_dir_all(&bin).unwrap();
        let script = format!(
            "#!/bin/sh\n[ \"$1 $2\" = \"auth status\" ] && {{ [ -n \"$GITHUB_TOKEN$GH_TOKEN\" ]; exit $?; }}\n\
             echo \"gh $*\"\n\
             [ \"$GH_TOKEN\" = {MINTED} ] && [ -z \"$GITHUB_TOKEN\" ] && echo token-ok\n\
             case \"$*\" in *leak-fail*) echo \"bad credentials $GH_TOKEN\" >&2; exit 1;; \
             *leak*) echo \"GH_TOKEN=$GH_TOKEN\";; esac\nexit 0\n"
        );
        std::fs::write(bin.join("gh"), script).unwrap();
        std::fs::set_permissions(bin.join("gh"), std::fs::Permissions::from_mode(0o755)).unwrap();
        let path = format!("{}:{}", bin.display(), std::env::var("PATH").unwrap_or_default());
        // SAFETY: under the Once, before this process's tests start a hub or a child.
        unsafe {
            std::env::set_var("PATH", path);
            std::env::set_var("GITHUB_TOKEN", "a-token-gh-must-not-see");
        }
    });
}

/// What the stand-in API was asked: (path, authorization, body) per request.
type Seen = Arc<Mutex<Vec<(String, String, Value)>>>;

/// The cmux API's token route on loopback: answers `answer` and records each request.
fn start_api(answer: (u16, Value), delay: Duration) -> (String, Seen) {
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let origin = format!("http://{}", listener.local_addr().unwrap());
    let seen = Arc::new(Mutex::new(Vec::new()));
    let log = seen.clone();
    std::thread::spawn(move || {
        for mut stream in listener.incoming().flatten() {
            let mut reader = BufReader::new(stream.try_clone().unwrap());
            let mut line = String::new();
            reader.read_line(&mut line).unwrap();
            let path = line.split_whitespace().nth(1).unwrap_or("").to_owned();
            let (mut length, mut auth) = (0usize, String::new());
            loop {
                let mut h = String::new();
                reader.read_line(&mut h).unwrap();
                let h = h.trim_end();
                if h.is_empty() {
                    break;
                }
                let (name, value) = h.split_once(':').unwrap_or((h, ""));
                match name.to_ascii_lowercase().as_str() {
                    "content-length" => length = value.trim().parse().unwrap_or(0),
                    "authorization" => auth = value.trim().to_owned(),
                    _ => {}
                }
            }
            let mut body = vec![0u8; length];
            reader.read_exact(&mut body).unwrap();
            let body = serde_json::from_slice(&body).unwrap_or(Value::Null);
            log.lock().unwrap().push((path, auth, body));
            std::thread::sleep(delay);
            let text = answer.1.to_string();
            let _ = write!(
                stream,
                "HTTP/1.1 {} X\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{text}",
                answer.0,
                text.len()
            );
        }
    });
    (origin, seen)
}

/// A unix-socket client of `hub` (the app's own call), or one from `origin`.
struct C(mpsc::Sender<String>, mpsc::Receiver<String>, i64);

impl C {
    async fn new(hub: &Arc<Hub>, origin: Origin) -> Self {
        Self::open(hub, origin).await.0
    }

    /// A connection that has sent nothing yet.
    fn raw(hub: &Arc<Hub>, origin: Origin) -> Self {
        let (in_tx, in_rx) = mpsc::channel(64);
        let (out_tx, out_rx) = mpsc::channel(4096);
        tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, origin));
        C(in_tx, out_rx, 0)
    }

    async fn open(hub: &Arc<Hub>, origin: Origin) -> (Self, Value) {
        let mut c = Self::raw(hub, origin);
        let init = c
            .call(method::INITIALIZE, json!({"protocolVersion": 1, "clientInfo": {"name": "t"}}))
            .await
            .unwrap();
        (c, init)
    }

    /// The app's own unix-socket connection, which proved the person (`hub/person.rs`).
    async fn app(hub: &Arc<Hub>) -> Self {
        let _ = hub.person.install_spawn_key(PERSON_KEY);
        let (mut c, init) = Self::open(hub, Origin::Local).await;
        let challenge = &init["_meta"]["acpmux"]["personChallenge"];
        let proof = acpmux::hub::person::person_proof(
            PERSON_KEY,
            acpmux::hub::person::TRANSPORT_UNIX,
            challenge["nonce"].as_str().unwrap(),
            challenge["connection"].as_str().unwrap(),
        )
        .unwrap();
        c.call("_acpmux/person_prove", json!({"proof": proof})).await.unwrap();
        c
    }

    async fn call(&mut self, m: &str, params: Value) -> Result<Value, Value> {
        self.2 += 1;
        let id = self.2;
        self.0.send(Message::request(id, m, params).to_line()).await.unwrap();
        loop {
            let line = tokio::time::timeout(Duration::from_secs(30), self.1.recv())
                .await
                .expect("timeout")
                .expect("closed");
            let v: Value = serde_json::from_str(&line).unwrap();
            if v.get("id") == Some(&json!(id)) {
                return match v.get("error") {
                    Some(e) => Err(e.clone()),
                    None => Ok(v["result"].clone()),
                };
            }
        }
    }
}

/// A stand-in for the added machine: it answers the Mac's handshake, then asks it for `action`
/// once and hands back the Mac's whole answer.
async fn lane_asking(action: Value) -> (u16, oneshot::Receiver<Value>) {
    use tokio_tungstenite::tungstenite::Message as Ws;
    let l = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = l.local_addr().unwrap().port();
    let (tx, rx) = oneshot::channel();
    tokio::spawn(async move {
        let (tcp, _) = l.accept().await.unwrap();
        let mut ws = tokio_tungstenite::accept_async(tcp).await.unwrap();
        let mut tx = Some(tx);
        while let Some(Ok(Ws::Text(text))) = ws.next().await {
            let v: Value = serde_json::from_str(&text).unwrap();
            if v["id"] == "lane-1" {
                let _ = tx.take().map(|tx| tx.send(v));
                continue;
            }
            let Ok(Message::Request { id, method: m, .. }) = Message::parse(&text) else {
                continue;
            };
            let result = match m.as_str() {
                method::INITIALIZE => json!({"protocolVersion": 1,
                    "_meta": {"acpmux": {"version": "0", "build": "t", "origin": "peer"}}}),
                method::MUX_WATCH => json!({"sessions": []}),
                _ => json!({}),
            };
            let mut lines = vec![Message::ok(id, result).to_line()];
            if m == method::MUX_WATCH {
                let mut action = action.clone();
                let wait = action.get("deadlineMs").and_then(Value::as_u64).unwrap_or(90_000);
                action["deadlineMs"] = json!(acpmux::store::now_ms() + wait);
                lines.push(Message::request(json!("lane-1"), GITHUB_ACTION, action).to_line());
            }
            for line in lines {
                ws.send(Ws::Text(line.trim_end().to_owned().into())).await.unwrap();
            }
        }
    });
    (port, rx)
}

/// What the Mac answers a machine it lends GitHub to.
async fn mac_answers(app: &mut C, name: &str, action: Value) -> Value {
    let (port, answer) = lane_asking(action).await;
    let add = json!({"name": name, "url": format!("ws://127.0.0.1:{port}"), "token": "tok",
        "githubBroker": true, "wait": true});
    app.call("_acpmux/peer_add", add).await.unwrap();
    tokio::time::timeout(Duration::from_secs(30), answer).await.expect("the Mac answered").unwrap()
}

#[tokio::test]
async fn with_no_keyring_login_the_mac_runs_a_lent_action_with_an_app_token_for_that_repo() {
    fake_gh();
    let reply = json!({"token": MINTED, "expires_at": "2099-01-01T00:00:00Z", "repo": "o/r",
        "permissions": {"metadata": "read", "issues": "write"}, "token_id": "0123456789abcdef"});
    let (origin, seen) = start_api((200, reply), Duration::ZERO);
    let a = hub();
    let mut app = C::app(&a).await;
    let lease = json!({"seq": 1, "origin": origin, "bearer": BEARER,
        "team": "team_0123456789abcdef0123", "expiresAtMs": acpmux::store::now_ms() + 600_000});
    assert_eq!(app.call(APP_LEASE, lease).await.unwrap(), json!({"lent": true}));

    let comment = json!({"sessionId": "s-1", "action": "comment", "repo": "o/r", "issue": 7,
        "body": "hi"});
    let v = mac_answers(&mut app, "added", comment).await;
    assert_eq!(v["result"]["source"], "app", "{v}");
    assert_eq!(v["result"]["output"], "gh issue comment 7 --body=hi --repo=o/r\ntoken-ok\n", "{v}");
    let text = v.to_string();
    assert!(!text.contains(MINTED) && !text.contains(BEARER), "nothing secret goes back: {text}");

    let seen = seen.lock().unwrap();
    assert_eq!(seen.len(), 1, "one token, for this one action");
    let (path, auth, body) = &seen[0];
    assert_eq!(path, "/v1/integrations/github/token");
    assert_eq!(auth, &format!("Bearer {BEARER}"));
    assert_eq!(body["repo"], "o/r");
    assert_eq!(body["team"], "team_0123456789abcdef0123");
    assert_eq!(body["permissions"]["issues"], "write");
    assert!(body["permissions"].get("contents").is_none(), "{body}");
}

#[tokio::test]
async fn with_neither_login_the_action_fails_closed_and_says_to_connect_github() {
    fake_gh();
    let a = hub();
    let mut app = C::app(&a).await;
    let read = json!({"action": "read", "repo": "o/r"});
    let v = mac_answers(&mut app, "unlent", read.clone()).await;
    assert_eq!(v["error"]["data"]["reason"], "github.not_connected", "{v}");
    let message = v["error"]["message"].as_str().unwrap_or_default();
    assert!(message.contains("connect GitHub in cmux Settings"), "{v}");

    // Only the app's own unix-socket connection lends a sign-in: not its pane over the
    // WebSocket, nor another process on the socket that did not prove the person.
    let mut other = C::new(&a, Origin::Local).await;
    let lease = json!({"seq": 1, "origin": "https://cloud-api.cmux.dev", "bearer": BEARER,
        "team": "team_0", "expiresAtMs": acpmux::store::now_ms() + 600_000});
    let e = other.call(APP_LEASE, lease.clone()).await.unwrap_err();
    assert!(e["message"].as_str().unwrap_or("").contains("only from the cmux app"), "{e}");
    let mut pane = C::new(&a, Origin::LocalApp).await;
    assert!(pane.call(APP_LEASE, lease.clone()).await.is_err());
    let v = mac_answers(&mut app, "still-unlent", read).await;
    assert_eq!(v["error"]["data"]["reason"], "github.not_connected", "{v}");
}

/// Review of the App token at d8a663b: the deadline was checked before `gh auth status` and the
/// mint, so a slow mint could start `gh` after the machine had stopped waiting.
#[tokio::test]
async fn an_action_whose_login_took_past_its_deadline_starts_no_gh() {
    fake_gh();
    let reply = json!({"token": MINTED, "repo": "o/r", "permissions": {"issues": "write"}});
    let (origin, seen) = start_api((200, reply), Duration::from_secs(3));
    let a = hub();
    let mut app = C::app(&a).await;
    let lease = json!({"seq": 1, "origin": origin, "bearer": BEARER, "team": "team_0",
        "expiresAtMs": acpmux::store::now_ms() + 600_000});
    app.call(APP_LEASE, lease).await.unwrap();
    // Due 62 s out: in time on arrival (`gh` gets 60 s), not once the 3 s mint is done.
    let comment = json!({"sessionId": "s-1", "action": "comment", "repo": "o/r", "issue": 7,
        "body": "hi", "deadlineMs": 62_000});
    let v = mac_answers(&mut app, "late", comment).await;
    assert_eq!(v["error"]["data"]["reason"], "github.expired", "{v}");
    assert_eq!(v["error"]["data"]["source"], "app", "{v}");
    assert_eq!(seen.lock().unwrap().len(), 1, "it was minted, then not used");
}

/// Review of the App token at 926bfb4: a `gh` that printed its token (an env dump, an error
/// that echoes it) sent it back to the added machine.
#[tokio::test]
async fn a_token_gh_prints_never_goes_back() {
    fake_gh();
    let reply = json!({"token": MINTED, "repo": "o/r", "permissions": {"issues": "write"}});
    let (origin, _) = start_api((200, reply), Duration::ZERO);
    let a = hub();
    let mut app = C::app(&a).await;
    let lease = json!({"seq": 1, "origin": origin, "bearer": BEARER, "team": "team_0",
        "expiresAtMs": acpmux::store::now_ms() + 600_000});
    app.call(APP_LEASE, lease).await.unwrap();
    for body in ["leak", "leak-fail"] {
        let comment = json!({"sessionId": "s-1", "action": "comment", "repo": "o/r", "issue": 7,
            "body": body});
        let v = mac_answers(&mut app, body, comment).await;
        let text = v.to_string();
        assert!(!text.contains(MINTED) && !text.contains("ghs_"), "{text}");
        assert!(text.contains("[redacted]"), "{text}");
    }
}

/// Review of the App token at a57885c: a failed mint lost `source`, and Cloud's own words (which
/// could hold a token) went on to the machine.
#[tokio::test]
async fn a_failed_mint_says_it_tried_the_app_and_passes_on_none_of_clouds_words() {
    fake_gh();
    let refusal = json!({"error": {"code": "integration.not_found",
        "message": "no connection for ghs_reflected0123 / Bearer cmux-install-token"}});
    let (origin, _) = start_api((404, refusal), Duration::ZERO);
    let a = hub();
    let mut app = C::app(&a).await;
    let lease = json!({"seq": 1, "origin": origin, "bearer": BEARER, "team": "team_0",
        "expiresAtMs": acpmux::store::now_ms() + 600_000});
    app.call(APP_LEASE, lease).await.unwrap();
    let read = json!({"action": "read", "repo": "o/r"});
    let v = mac_answers(&mut app, "refused", read).await;
    assert_eq!(v["error"]["data"]["reason"], "github.not_connected", "{v}");
    assert_eq!(v["error"]["data"]["source"], "app", "{v}");
    let text = v.to_string();
    assert!(!text.contains("ghs_") && !text.contains(BEARER), "{text}");
}

/// Review of the App token at 1f49357: a token broader than the action asked for was used.
#[tokio::test]
async fn a_token_broader_than_its_action_is_never_used() {
    fake_gh();
    let broad = json!({"token": MINTED, "repo": "o/r",
        "permissions": {"issues": "write", "contents": "write"}});
    let (origin, _) = start_api((200, broad), Duration::ZERO);
    let a = hub();
    let mut app = C::app(&a).await;
    let lease = json!({"seq": 1, "origin": origin, "bearer": BEARER, "team": "team_0",
        "expiresAtMs": acpmux::store::now_ms() + 600_000});
    app.call(APP_LEASE, lease).await.unwrap();
    let comment = json!({"sessionId": "s-1", "action": "comment", "repo": "o/r", "issue": 7,
        "body": "hi"});
    let v = mac_answers(&mut app, "broad", comment).await;
    assert_eq!(v["error"]["data"]["code"], "invalid_reply", "{v}");
    assert!(!v.to_string().contains("token-ok"), "gh never ran with it: {v}");
}

/// Review of the App token at 15a905b: a token minted with a sign-in that was cleared (a
/// sign-out) while it was minted was still used.
#[tokio::test]
async fn a_token_minted_across_a_sign_out_is_never_used() {
    fake_gh();
    let reply = json!({"token": MINTED, "repo": "o/r", "permissions": {"issues": "write"}});
    let (origin, seen) = start_api((200, reply), Duration::from_secs(3));
    let a = hub();
    let mut app = C::app(&a).await;
    let mut signing_out = C::app(&a).await;
    let lease = json!({"seq": 1, "origin": origin, "bearer": BEARER, "team": "team_0",
        "expiresAtMs": acpmux::store::now_ms() + 600_000});
    app.call(APP_LEASE, lease).await.unwrap();
    let comment = json!({"sessionId": "s-1", "action": "comment", "repo": "o/r", "issue": 7,
        "body": "hi"});
    // The sign-out lands while the 3 s mint runs.
    let sign_out = async {
        tokio::time::sleep(Duration::from_millis(1500)).await;
        signing_out.call(APP_LEASE, json!({"seq": 2, "clear": true})).await.unwrap()
    };
    let (v, cleared) = tokio::join!(mac_answers(&mut app, "signed-out", comment), sign_out);
    assert_eq!(cleared, json!({"lent": false}));
    assert_eq!(v["error"]["data"]["code"], "lease_changed", "{v}");
    assert!(!v.to_string().contains("token-ok"), "gh never ran with it: {v}");
    assert_eq!(seen.lock().unwrap().len(), 1, "it was minted, then not used");
}

#[tokio::test]
async fn only_the_apps_own_connection_lends_its_sign_in_and_no_answer_holds_it() {
    let a = hub();
    let mut app = C::app(&a).await;
    let lend = |seq: u64| {
        json!({"seq": seq, "origin": "https://cloud-api.cmux.dev", "bearer": BEARER,
            "team": "team_0123456789abcdef0123", "expiresAtMs": acpmux::store::now_ms() + 600_000})
    };
    assert_eq!(app.call(APP_LEASE, lend(5)).await.unwrap(), json!({"lent": true}));

    // Not another process on the socket that did not prove the person, nor the app's pane, a
    // page or a peer over the WebSocket: none of them lends a sign-in or takes it back.
    let mut other = C::new(&a, Origin::Local).await;
    let e = other.call(APP_LEASE, lend(6)).await.unwrap_err();
    assert!(e["message"].as_str().unwrap_or("").contains("only from the cmux app"), "{e}");
    let clear = json!({"seq": 6, "clear": true});
    assert!(other.call(APP_LEASE, clear.clone()).await.is_err());
    for origin in [Origin::LocalApp, Origin::Web, Origin::Peer] {
        let mut c = C::raw(&a, origin);
        let e = c.call(APP_LEASE, lend(6)).await.unwrap_err();
        assert!(
            e["message"].as_str().unwrap_or("").contains("only over the local unix socket"),
            "{e}"
        );
        assert!(c.call(APP_LEASE, clear.clone()).await.is_err(), "{origin:?}");
    }

    // The app's own lend still holds, and an older call changes nothing.
    let stale = app.call(APP_LEASE, lend(4)).await.unwrap();
    assert_eq!(stale, json!({"lent": true, "stale": true, "seq": 5}));
    assert!(!stale.to_string().contains(BEARER));
    assert_eq!(app.call(APP_LEASE, clear).await.unwrap(), json!({"lent": false}));
    assert_eq!(app.call(APP_LEASE, lend(5)).await.unwrap()["stale"], true, "a late lend");
}
