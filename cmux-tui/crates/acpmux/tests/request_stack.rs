//! A hub that runs in another process's runtime polls its requests on that runtime's workers, and
//! tokio gives a worker 2 MiB of stack unless the runtime asks for more. The cmux-tui tests run a
//! hub so (`agent_message_launch_credential`, `agent_message_reply_in_place`): on Linux their
//! `session/new` and `session/prompt` aborted with "has overflowed its stack", because a debug
//! build polled each request through 2.1-2.3 MiB of frames (`src/heap_future.rs`). This test
//! serves the same requests on workers of exactly tokio's default stack, whatever
//! `RUST_MIN_STACK` this process has (`support/daemon_env.rs` sets 8 MiB, the daemon's own).
//!
//! The second test sends every request kind `dispatch_request` has an arm for (`request_stack/
//! arms.rs`, with the smallest params each arm accepts) on such a worker; the third keeps that table
//! complete against the source (`request_stack/arms_in_source.rs`), so a new arm is sent at once.

// Unix only until the Windows port runs the daemon (cmux::local_socket).
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
mod request_stack {
    pub mod arms;
    pub mod arms_in_source;
}
// This process runs the stand-in agent (tests/fake_agent.py) in its hub.
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::Message;
use acpmux::server::{Origin, serve_connection_with};
use request_stack::arms::{self, Ask};
use serde_json::{Value, json};
use std::collections::BTreeSet;
use std::time::Duration;
use tokio::sync::mpsc;

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");

/// tokio's worker stack when a runtime names none (tokio `runtime/builder.rs`).
const TOKIO_DEFAULT_WORKER_STACK: usize = 2 << 20;

/// A runtime whose workers have exactly tokio's default stack.
fn small_stack_runtime() -> tokio::runtime::Runtime {
    tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .thread_stack_size(TOKIO_DEFAULT_WORKER_STACK)
        .enable_all()
        .build()
        .unwrap()
}

/// A connection to a new in-process hub of the stand-in agent, served on the runtime's workers.
fn connect() -> Client {
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", FAKE]}},
        "defaultHarness": "fake",
        "permissionPolicy": "approve-all",
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    let (in_tx, in_rx) = mpsc::channel(64);
    let (out_tx, out_rx) = mpsc::channel(4096);
    // Spawned: the connection and its requests run on the 2 MiB workers, not on this test's
    // thread.
    drop(tokio::spawn(serve_connection_with(hub, in_rx, out_tx, Origin::Local)));
    Client(in_tx, out_rx, 0)
}

#[test]
fn a_new_chat_and_its_prompt_are_served_on_a_default_tokio_worker_stack() {
    small_stack_runtime().block_on(async {
        let mut client = connect();
        let session = client.new_session().await;
        let prompt = json!({"sessionId": session,
            "prompt": [{"type": "text", "text": "on a small stack"}]});
        let (reply, text) = client.call("session/prompt", prompt).await;
        assert!(reply.get("error").is_none(), "{reply}");
        assert!(text.contains("on a small stack"), "the agent echoed {text:?}");
    });
}

/// JSON-RPC's invalid params and method not found: the request did not reach the arm's work.
const NOT_REACHED: [i64; 2] = [-32602, -32601];

#[test]
fn every_request_kind_of_dispatch_request_is_served_on_a_default_tokio_worker_stack() {
    small_stack_runtime().block_on(async {
        let mut client = connect();
        let session = client.new_session().await;
        let prompt = json!({"sessionId": session, "prompt": [{"type": "text", "text": "hello"}]});
        let (reply, _) = client.call("session/prompt", prompt).await;
        assert!(reply.get("error").is_none(), "{reply}");
        let cwd = std::env::temp_dir().to_string_lossy().into_owned();
        let mut wrong = Vec::new();
        for (method, ask) in arms::table() {
            let (params, why) = match ask {
                Ask::Run(params) => (params, None),
                Ask::Any(params, why) => (params, Some(why)),
                Ask::Skip(why) => {
                    eprintln!("request_stack: {method} not sent: {why}");
                    continue;
                }
            };
            // A request that ends or deletes a chat gets a new one of its own.
            let text = params.to_string();
            let own = if text.contains("$T") { client.new_session().await } else { String::new() };
            let text = text
                .replace("$S", &session)
                .replace("$T", &own)
                .replace("$CWD", &cwd)
                .replace("$FAKE", FAKE);
            let params: Value = serde_json::from_str(&text).unwrap();
            // Before the request: a stack overflow aborts the process, and nextest shows this.
            let expect = match why {
                None => "reaches its work".to_owned(),
                Some(why) => format!("any reply: {why}"),
            };
            eprintln!("request_stack: {method} {params} ({expect})");
            match client.reply(method, params).await {
                None => wrong.push(format!("{method}: no reply in {REPLY_WAIT:?} ({expect})")),
                Some(reply) => {
                    let code = reply.pointer("/error/code").and_then(Value::as_i64);
                    if why.is_none() && code.is_some_and(|code| NOT_REACHED.contains(&code)) {
                        wrong.push(format!("{method}: did not reach its work: {reply}"));
                    }
                }
            }
        }
        assert!(wrong.is_empty(), "requests that went wrong:\n{}", wrong.join("\n"));
    });
}

#[test]
fn the_table_names_every_request_kind_of_dispatch_request() {
    let in_source = request_stack::arms_in_source::methods();
    let mut in_table = BTreeSet::new();
    for (method, _) in arms::table() {
        assert!(in_table.insert(method.to_owned()), "{method} is in arms.rs twice");
    }
    let missing: Vec<_> = in_source.difference(&in_table).collect();
    let stale: Vec<_> = in_table.difference(&in_source).collect();
    assert!(
        missing.is_empty() && stale.is_empty(),
        "request_stack/arms.rs and dispatch_request disagree. Add each new arm to arms.rs with the \
         smallest params it accepts (or a reason to skip it); remove each arm that is gone.\n\
         missing: {missing:?}\nstale: {stale:?}"
    );
}

/// How long a request of the table may take to answer: the 30 s that `Client::call` gives one
/// line, so a row that starts the stand-in agent on a loaded fleet host does not fail at random.
const REPLY_WAIT: Duration = Duration::from_secs(30);

struct Client(mpsc::Sender<String>, mpsc::Receiver<String>, i64);

impl Client {
    /// A new chat of the stand-in agent.
    async fn new_session(&mut self) -> String {
        let (reply, _) =
            self.call("session/new", json!({"cwd": std::env::temp_dir(), "mcpServers": []})).await;
        assert!(reply.get("error").is_none(), "{reply}");
        reply["result"]["sessionId"].as_str().unwrap().to_owned()
    }

    /// The reply to one request, or None after [`REPLY_WAIT`].
    async fn reply(&mut self, method: &str, params: Value) -> Option<Value> {
        tokio::time::timeout(REPLY_WAIT, self.call(method, params))
            .await
            .ok()
            .map(|(reply, _)| reply)
    }

    /// The reply to one request, and the agent text streamed before it.
    async fn call(&mut self, method: &str, params: Value) -> (Value, String) {
        self.2 += 1;
        let id = self.2;
        self.0.send(Message::request(id, method, params).to_line()).await.unwrap();
        let mut text = String::new();
        loop {
            let line = tokio::time::timeout(Duration::from_secs(30), self.1.recv())
                .await
                .unwrap()
                .unwrap();
            let value: Value = serde_json::from_str(&line).unwrap();
            if value.get("id") == Some(&json!(id)) {
                return (value, text);
            }
            if let Some(t) = value.pointer("/params/update/content/text").and_then(Value::as_str) {
                text.push_str(t);
            }
        }
    }
}
