//! A teammate through the Cloud carrier, end to end (`server/carrier.rs`, `docs/carrier-roles.md`):
//! a real hub running a stand-in Claude agent, the real carrier socket (`carrier::bind` and
//! `carrier::serve`), and a WebSocket over it whose upgrade carries the attested
//! `x-acpmux-carrier` header. The owner, through the same socket, starts two chats, A and B; the
//! teammate's header grants A only.
//!
//! - A prompt, a page of events and a cancel on A go through, and the prompt runs under the
//!   header's author whatever author the request named.
//! - The same verbs on B, and every verb outside the teammate's allowlist (a session start, a
//!   load, the session list, a permission answer, a method no acpmux has yet, and every other
//!   method `rpc::method` lists, read from its source), are refused with
//!   JSON-RPC code -32003 (`carrier::NOT_A_TEAMMATE_VERB`) and `data.reason:
//!   "carrier.team_refused"`.
//!
//! The unit tests beside `carrier.rs` hold `admit` and `serve_attested` to the whole matrix; this
//! file checks that the socket a session host dials really applies them.

// The carrier socket is a unix socket.
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::{Message, method};
use acpmux::server::carrier;
use futures_util::{SinkExt, StreamExt};
use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;
use tokio_tungstenite::tungstenite::Message as Frame;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
const WAIT: Duration = Duration::from_secs(30);
const REFUSED: &str = "carrier.team_refused";

/// A short scratch directory (a unix socket path has a length cap) with a `work` folder chats
/// start in.
fn scratch() -> PathBuf {
    let d = std::env::temp_dir().join(format!("act-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&d);
    std::fs::create_dir_all(d.join("work")).unwrap();
    std::fs::canonicalize(&d).unwrap()
}

/// A memory hub whose one harness is the stand-in agent as a Claude-family adapter, so a
/// teammate's prompt runs in Claude's `default` mode (the strictest asking modes).
fn hub(d: &Path) -> Arc<Hub> {
    let _ = HERMETIC;
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fclaude": {
            "argv": ["python3", FAKE], "family": "claude",
            // A teammate's prompt reaches the agent behind a line naming its author.
            "env": {"FAKE_UNTIL_CANCEL_IN": "until-cancel"},
        }},
        "defaultHarness": "fclaude",
        "permissionPolicy": "ask",
        "webRoots": [d.join("work")],
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

type Ws = tokio_tungstenite::WebSocketStream<tokio::net::UnixStream>;

/// One WebSocket over the carrier socket, its upgrade carrying `header` as the session host
/// writes it from the carrier grant.
struct Carrier {
    ws: Ws,
    next: i64,
    /// Notifications read while waiting for an answer.
    seen: Vec<Value>,
}

impl Carrier {
    async fn connect(socket: &Path, header: &Value) -> Self {
        let stream = tokio::net::UnixStream::connect(socket).await.unwrap();
        let mut req = "ws://carrier/".into_client_request().unwrap();
        req.headers_mut().insert(carrier::HEADER, header.to_string().parse().unwrap());
        let (ws, _) = tokio_tungstenite::client_async(req, stream).await.unwrap();
        let mut c = Carrier { ws, next: 0, seen: Vec::new() };
        let hello = c.call(method::INITIALIZE, json!({"protocolVersion": 1})).await;
        assert!(hello.get("result").is_some(), "{hello}");
        c
    }

    async fn frame(&mut self) -> Value {
        loop {
            let frame = tokio::time::timeout(WAIT, self.ws.next())
                .await
                .unwrap_or_else(|_| {
                    let seen: Vec<String> = (self.seen.iter())
                        .map(|v| v.to_string().chars().take(300).collect())
                        .collect();
                    panic!("no frame from the carrier socket; read before: {seen:#?}")
                })
                .expect("the carrier socket closed")
                .unwrap();
            if let Frame::Text(t) = frame {
                return serde_json::from_str(&t).unwrap();
            }
        }
    }

    async fn send(&mut self, m: &str, params: Value) -> i64 {
        self.next += 1;
        let line = Message::request(self.next, m, params).to_line();
        self.ws.send(Frame::Text(line.trim_end().to_owned().into())).await.unwrap();
        self.next
    }

    /// The answer to request `id`, keeping the notifications and other answers read on the way:
    /// one read while waiting for another request's answer is taken from those first.
    async fn answer(&mut self, id: i64) -> Value {
        if let Some(i) = self.seen.iter().position(|v| is_answer(v, id)) {
            return self.seen.remove(i);
        }
        loop {
            let v = self.frame().await;
            if is_answer(&v, id) {
                return v;
            }
            self.seen.push(v);
        }
    }

    /// Read frames until the answers to every one of `ids` are among those read.
    async fn read_answers(&mut self, ids: &[i64]) {
        while !ids.iter().all(|id| self.seen.iter().any(|v| is_answer(v, *id))) {
            let v = self.frame().await;
            self.seen.push(v);
        }
    }

    async fn call(&mut self, m: &str, params: Value) -> Value {
        let id = self.send(m, params).await;
        self.answer(id).await
    }

    /// The first notification, read now or later, whose params satisfy `pred`.
    async fn wait_for(&mut self, pred: impl Fn(&Value) -> bool) -> Value {
        if let Some(i) = self.seen.iter().position(|v| pred(&v["params"])) {
            return self.seen.remove(i);
        }
        loop {
            let v = self.frame().await;
            if v.get("method").is_some() && pred(&v["params"]) {
                return v;
            }
            self.seen.push(v);
        }
    }
}

fn is_answer(v: &Value, id: i64) -> bool {
    v.get("id") == Some(&json!(id)) && v.get("method").is_none()
}

/// Every method name in `rpc::method`, read from its source as `carrier_tests.rs`'s
/// `every_method` reads it, so a method added later is swept here too.
fn every_method() -> Vec<String> {
    let src = include_str!(concat!(env!("CARGO_MANIFEST_DIR"), "/src/rpc.rs"));
    let start = src.find("pub mod method").expect("rpc.rs has a method module");
    let end = start + src[start..].find("\n}\n").expect("the method module ends");
    let mut out = Vec::new();
    for line in src[start..end].lines() {
        let line = line.trim();
        if let Some(rest) = line.strip_prefix("pub const ")
            && let Some((_, value)) = rest.split_once("= \"")
            && let Some(name) = value.strip_suffix("\";")
        {
            out.push(name.to_owned());
        }
    }
    assert!(out.len() > 200, "read {} methods from rpc.rs", out.len());
    out
}

fn prompt(chat: &str, text: &str) -> Value {
    json!({"sessionId": chat, "prompt": [{"type": "text", "text": text}]})
}

/// Assert `reply` is the carrier's refusal of a teammate's request.
fn assert_team_refused(what: &str, reply: &Value) {
    assert_eq!(reply["error"]["code"], json!(carrier::NOT_A_TEAMMATE_VERB), "{what}: {reply}");
    assert_eq!(reply["error"]["data"]["reason"], REFUSED, "{what}: {reply}");
}

#[tokio::test]
async fn a_teammate_granted_chat_a_works_a_and_is_refused_b_and_every_other_verb() {
    let d = scratch();
    let hub = hub(&d);
    let socket = carrier::socket_path(&d.join("home"));
    let listener = carrier::bind(&socket).await.unwrap();
    tokio::spawn(carrier::serve(hub.clone(), listener));

    // The owner, through the same socket, starts chats A and B in Claude's `default` mode.
    let mut owner =
        Carrier::connect(&socket, &json!({"vmk": "owner", "sub": "u_owner", "team": "t_1"})).await;
    let mut chats = Vec::new();
    for name in ["chat-a", "chat-b"] {
        let r = owner
            .call(
                method::SESSION_NEW,
                json!({"cwd": d.join("work"), "mcpServers": [], "_meta": {"acpmux": {"name": name}}}),
            )
            .await;
        let id = r["result"]["sessionId"].as_str().unwrap_or_else(|| panic!("{r}")).to_owned();
        let r = owner.call("session/set_mode", json!({"sessionId": id, "modeId": "default"})).await;
        assert!(r.get("error").is_none(), "{r}");
        chats.push(id);
    }
    let (a, b) = (chats[0].clone(), chats[1].clone());

    // The teammate's grant names chat A only.
    let header =
        json!({"vmk": "team", "sub": "u_mate", "team": "t_1", "chats": [a], "name": "Ada"});
    let mut mate = Carrier::connect(&socket, &header).await;
    // It attaches to A, and hears its turns from here on.
    let r = mate.call("_acpmux/attach", json!({"sessionId": a})).await;
    assert!(r.get("result").is_some(), "a teammate's attach on its chat: {r}");

    // On A: a prompt whose request names another author runs under the header's.
    let mut forged = prompt(&a, "hello from ada");
    forged["_meta"] = json!({"acpmux": {"author": {"id": "user_u_owner", "name": "Owner"}}});
    let r = mate.call(method::SESSION_PROMPT, forged).await;
    assert!(r.get("error").is_none(), "a teammate's prompt on its chat: {r}");
    // The prompt ran, recorded under the header's person, never the author the request named.
    let r = mate.call("_acpmux/events", json!({"sessionId": a, "limit": 200})).await;
    let events = r["result"]["events"].as_array().unwrap_or_else(|| panic!("{r}"));
    let said = events
        .iter()
        .find(|e| e["kind"] == "user_message" && e["msg"]["text"] == "hello from ada")
        .unwrap_or_else(|| panic!("the teammate's prompt never ran on chat A: {r}"));
    let provenance = &said["msg"]["_meta"]["provenance"];
    assert_eq!(provenance["from"], "user_u_mate", "{said}");
    assert_eq!(provenance["fromName"], "Ada", "{said}");
    assert_eq!(provenance["transport"], "carrier", "{said}");
    let text = r.to_string();
    assert!(!text.contains("user_u_owner") && !text.contains("\"Owner\""), "{r}");
    assert!(events.iter().any(|e| e["kind"] == "turn_end"), "{r}");

    // A cancel on A stops its running turn.
    mate.seen.clear();
    let running = mate.send(method::SESSION_PROMPT, prompt(&a, "until-cancel")).await;
    // The agent streams "running" once the turn is under way.
    mate.wait_for(|p| {
        let p = p.to_string();
        p.contains("agent_message_chunk") && p.contains("running")
    })
    .await;
    let cancel = mate.send(method::SESSION_CANCEL, json!({"sessionId": a})).await;
    // Both answers are read before either is asked for, so each is taken from those already read,
    // whichever came first (the prompt's may come before the cancel's).
    mate.read_answers(&[cancel, running]).await;
    let r = mate.answer(cancel).await;
    assert!(r.get("error").is_none(), "a teammate's cancel on its chat: {r}");
    let r = mate.answer(running).await;
    assert_eq!(r["result"]["stopReason"], "cancelled", "{r}");

    // The same verbs on B.
    for (m, params) in [
        (method::SESSION_PROMPT, prompt(&b, "hi")),
        ("_acpmux/events", json!({"sessionId": b, "limit": 50})),
        (method::SESSION_CANCEL, json!({"sessionId": b})),
        ("_acpmux/attach", json!({"sessionId": b})),
    ] {
        let r = mate.call(m, params).await;
        assert_team_refused(&format!("{m} on chat B"), &r);
    }

    // Verbs outside the allowlist, on chat A or none.
    for (m, params) in [
        (method::SESSION_NEW, json!({"cwd": d.join("work"), "mcpServers": []})),
        ("session/load", json!({"sessionId": a, "cwd": d.join("work"), "mcpServers": []})),
        ("session/fork", json!({"sessionId": a, "cwd": d.join("work"), "mcpServers": []})),
        ("session/list", json!({})),
        ("_acpmux/sessions", json!({})),
        ("_acpmux/watch", json!({"enabled": true})),
        (
            "_acpmux/permission_respond",
            json!({"sessionId": a, "permissionId": "p1", "optionId": "allow_once"}),
        ),
        ("session/set_mode", json!({"sessionId": a, "modeId": "bypassPermissions"})),
        // A method no acpmux has yet is refused too.
        ("_acpmux/some_future_verb", json!({"sessionId": a})),
    ] {
        let r = mate.call(m, params).await;
        assert_team_refused(m, &r);
    }

    // Every other method acpmux has, as `rpc::method` lists it, on chat A: only the teammate's
    // verbs (`carrier::team_allows`) are allowed, the rest refused.
    let methods = every_method();
    let allowed: Vec<&str> =
        methods.iter().map(String::as_str).filter(|m| carrier::team_allows(m)).collect();
    let mut want = vec![
        method::INITIALIZE,
        method::MUX_ATTACH,
        method::MUX_INFO,
        method::MUX_EVENTS,
        method::MUX_ATTACHMENT,
        method::SESSION_PROMPT,
        method::SESSION_CANCEL,
        method::MUX_DETACH,
    ];
    let mut got = allowed.clone();
    got.sort_unstable();
    got.dedup();
    want.sort_unstable();
    assert_eq!(got, want, "the teammate's verbs: docs/carrier-roles.md");
    let refused: Vec<&String> = methods.iter().filter(|m| !carrier::team_allows(m)).collect();
    assert!(refused.len() > 200, "{} refused methods", refused.len());
    for m in refused {
        let params = json!({"sessionId": a, "cwd": d.join("work"), "mcpServers": []});
        let r = mate.call(m, params).await;
        assert_team_refused(m, &r);
    }

    // The refusals left the teammate's connection up: A still answers.
    let r = mate.call("_acpmux/events", json!({"sessionId": a, "limit": 1})).await;
    assert!(r.get("error").is_none(), "{r}");
    // And B never ran the teammate's prompt.
    let r = owner.call("_acpmux/events", json!({"sessionId": b, "limit": 200})).await;
    assert!(r["result"]["events"].is_array(), "{r}");
    assert!(!r.to_string().contains("u_mate"), "chat B heard from the teammate: {r}");
    let _ = std::fs::remove_dir_all(&d);
}
