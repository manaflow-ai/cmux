//! Red team for per-chat secrets (`chat_secrets.rs`, hq RFD sandboxing-and-lockdown).
//!
//! Leo, 2026-11-25: "security/sandboxing... how will that work? what about if someone wants to
//! lock down a vm? lock down their app?"
//!
//! Two chats on one daemon. The person gives chat A a secret. Chat B's agent (fake_claude) hunts
//! for it every way it has: its own environment, the machine-wide secrets file, `secret_run`
//! with A's session and with guessed refs, planting or clearing values over the unix socket, and
//! sending whatever it found to an outside host (a listener standing in for one). It never has
//! the value. The value never reaches disk (ACPMUX_HOME, the store, `~/.config/cmux`), and it
//! expires after its TTL.
//!
//! One test function: the hub reads this process's environment, which every test of a binary
//! shares.

// Unix only until the Windows port runs the daemon (cmux::local_socket).
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use acpmux::config::Config;
use acpmux::hub::Hub;
use acpmux::rpc::Message;
use acpmux::server::{Origin, serve_connection_with};
use serde_json::{Value, json};
use std::io::Read;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

const FAKE_CLAUDE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_claude.py");
const PERSON_KEY: &str = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
const NAME: &str = "CMUX_REDTEAM_TOKEN_X";
// Not a CMUX_ name: those are refused (asserted below). This one is allowed.
const ALLOWED: &str = "REDTEAM_TOKEN";

struct Client(mpsc::Sender<String>, mpsc::Receiver<String>, i64);

fn client(hub: &Arc<Hub>, origin: Origin) -> Client {
    let (in_tx, in_rx) = mpsc::channel(64);
    let (out_tx, out_rx) = mpsc::channel(4096);
    tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, origin));
    Client(in_tx, out_rx, 0)
}

impl Client {
    async fn call_text(&mut self, m: &str, params: Value) -> (Value, String) {
        self.2 += 1;
        let id = self.2;
        self.0.send(Message::request(id, m, params).to_line()).await.unwrap();
        let mut text = String::new();
        loop {
            let line = tokio::time::timeout(Duration::from_secs(30), self.1.recv())
                .await
                .unwrap()
                .unwrap();
            let v: Value = serde_json::from_str(&line).unwrap();
            if v.get("id") == Some(&json!(id)) {
                return (v, text);
            }
            if let Some(t) = v.pointer("/params/update/content/text").and_then(Value::as_str) {
                text.push_str(t);
            }
        }
    }

    async fn call(&mut self, m: &str, params: Value) -> Value {
        self.call_text(m, params).await.0
    }

    async fn new_session(&mut self, cwd: &Path) -> String {
        let params =
            json!({"cwd": cwd, "mcpServers": [], "_meta": {"acpmux": {"harness": "fakeclaude"}}});
        let reply = self.call("session/new", params).await;
        assert!(reply.get("error").is_none(), "{reply}");
        reply["result"]["sessionId"].as_str().unwrap().to_owned()
    }

    async fn ask(&mut self, session: &str, text: &str) -> String {
        let prompt = json!({"sessionId": session, "prompt": [{"type": "text", "text": text}]});
        let (reply, said) = self.call_text("session/prompt", prompt).await;
        assert!(reply.get("error").is_none(), "{reply}");
        said
    }

    /// The app's handshake: `initialize`, then the proof of [`PERSON_KEY`].
    async fn become_person(&mut self) {
        let init = self
            .call("initialize", json!({"protocolVersion": 1, "clientInfo": {"name": "test"}}))
            .await;
        let challenge = &init["result"]["_meta"]["acpmux"]["personChallenge"];
        let proof = acpmux::hub::person::person_proof(
            PERSON_KEY,
            acpmux::hub::person::TRANSPORT_UNIX,
            challenge["nonce"].as_str().expect("a person challenge"),
            challenge["connection"].as_str().unwrap(),
        )
        .unwrap();
        let r = self.call("_acpmux/person_prove", json!({"proof": proof})).await;
        assert_eq!(r["result"]["person"], json!(true), "{r}");
    }
}

fn hub(root: &Path) -> Arc<Hub> {
    let cfg: Config = serde_json::from_value(json!({
        "harnesses": {
            "fakeclaude": {"argv": ["python3", FAKE_CLAUDE], "kind": "claude-stdio",
                "env": {"CLAUDE_CONFIG_DIR": root.join("claude")}},
        },
        "defaultHarness": "fakeclaude",
        "permissionPolicy": "approve-all",
    }))
    .unwrap();
    // A store on disk, so the scan below would see a value written into a record.
    let store = acpmux::store::open(&cfg.store, &root.join("home")).unwrap();
    let hub = Hub::new(cfg, store);
    hub.person.install_spawn_key(PERSON_KEY).unwrap();
    hub
}

/// What an "outside host" received: one listener, every connection's bytes.
fn outside_host() -> (u16, Arc<std::sync::Mutex<Vec<u8>>>) {
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    let got = Arc::new(std::sync::Mutex::new(Vec::new()));
    let sink = got.clone();
    std::thread::spawn(move || {
        for conn in listener.incoming().flatten() {
            let mut buf = Vec::new();
            let mut conn = conn;
            let _ = conn.read_to_end(&mut buf);
            sink.lock().unwrap().extend(buf);
        }
    });
    (port, got)
}

fn take(got: &std::sync::Mutex<Vec<u8>>) -> String {
    String::from_utf8_lossy(&std::mem::take(&mut *got.lock().unwrap())).into_owned()
}

/// Every file under `dir` whose bytes hold `needle`.
fn files_holding(dir: &Path, needle: &[u8]) -> Vec<PathBuf> {
    let mut hits = Vec::new();
    let Ok(entries) = std::fs::read_dir(dir) else { return hits };
    for entry in entries.flatten() {
        let path = entry.path();
        let Ok(kind) = entry.file_type() else { continue };
        if kind.is_dir() {
            hits.extend(files_holding(&path, needle));
        } else if kind.is_file()
            && let Ok(bytes) = std::fs::read(&path)
            && bytes.windows(needle.len()).any(|w| w == needle)
        {
            hits.push(path);
        }
    }
    hits
}

fn error_of(reply: &Value) -> String {
    reply.get("error").map(|e| e.to_string()).unwrap_or_default()
}

#[tokio::test]
async fn another_chat_never_gets_a_chat_secret_and_it_never_reaches_disk() {
    let root =
        std::env::temp_dir().join(format!("acpmux-chat-secrets-it-{}", uuid::Uuid::now_v7()));
    let (folder_a, folder_b) = (root.join("a"), root.join("b"));
    for d in [&folder_a, &folder_b, &root.join("home"), &root.join("claude")] {
        std::fs::create_dir_all(d).unwrap();
    }
    let home = PathBuf::from(std::env::var_os("HOME").expect("the hermetic HOME"));
    // SAFETY: the only test in this binary; set before any session starts.
    unsafe {
        std::env::set_var("ACPMUX_HOME", root.join("home"));
    }
    // A fresh value per run: no other file on this machine can hold it.
    let value = format!("redteam-{}", uuid::Uuid::now_v7().simple());
    let hub = hub(&root);
    let mut person = client(&hub, Origin::Local);
    person.become_person().await;
    // The agents' own connection: the unix socket, not the person.
    let mut agent = client(&hub, Origin::Local);
    let (port, outside) = outside_host();

    let a = person.new_session(&folder_a).await;
    let b = person.new_session(&folder_b).await;
    // Both agents are running before the secret arrives.
    assert_eq!(person.ask(&a, &format!("env: {ALLOWED}")).await, format!("{ALLOWED}="));
    assert_eq!(person.ask(&b, &format!("env: {ALLOWED}")).await, format!("{ALLOWED}="));

    // An agent on the unix socket can neither plant a value in a chat nor clear one.
    let planted = agent
        .call("_acpmux/chat_secrets_set", json!({"sessionId": b, "secrets": {ALLOWED: "planted"}}))
        .await;
    assert!(error_of(&planted).contains("person"), "{planted}");
    let cleared = agent.call("_acpmux/chat_secrets_clear", json!({"sessionId": a})).await;
    assert!(error_of(&cleared).contains("person"), "{cleared}");
    // Loader and cmux names are refused, naming the name and never the value.
    let refused = person
        .call("_acpmux/chat_secrets_set", json!({"sessionId": a, "secrets": {NAME: value}}))
        .await;
    assert!(error_of(&refused).contains(NAME), "{refused}");
    assert!(!refused.to_string().contains(&value), "a refusal echoed the value");

    // The person gives A the secret: A's running agent restarts on it.
    let set = person
        .call("_acpmux/chat_secrets_set", json!({"sessionId": a, "secrets": {ALLOWED: value}}))
        .await;
    assert!(set.get("error").is_none(), "{set}");
    assert_eq!(set["result"]["names"], json!([ALLOWED]), "{set}");
    assert!(!set.to_string().contains(&value), "the reply carried the value");
    assert!(matches!(set["result"]["applied"].as_str(), Some("now" | "nextStart")), "{set}");

    // B does not have it in its environment.
    assert_eq!(person.ask(&b, &format!("env: {ALLOWED}")).await, format!("{ALLOWED}="));

    // B's agent, prompt-injected, hunts for it and sends what it finds out.
    let said: Value =
        serde_json::from_str(&person.ask(&b, &format!("exfil-probe {ALLOWED} {port}")).await)
            .unwrap();
    assert_eq!(said["env"], json!(false), "{said}");
    tokio::time::sleep(Duration::from_millis(200)).await;
    let sent = take(&outside);
    assert!(sent.starts_with("env="), "the probe reached the outside host: {sent:?}");
    assert!(!sent.contains(&value), "B sent A's secret out");
    // The positive control: the same probe in A does find and send it, so the listener works.
    let said: Value =
        serde_json::from_str(&person.ask(&a, &format!("exfil-probe {ALLOWED} {port}")).await)
            .unwrap();
    assert_eq!(said["env"], json!(true), "{said}");
    tokio::time::sleep(Duration::from_millis(200)).await;
    assert!(take(&outside).contains(&value), "A's own probe did not reach the listener");

    // B's agent spends refs it guesses, against A's chat and its own: nothing runs with it.
    for (session, secret_ref) in [(&a, ALLOWED), (&a, "ref-0"), (&b, ALLOWED), (&a, a.as_str())] {
        let run = agent
            .call(
                "_acpmux/secret_run",
                json!({"sessionId": session, "secretRef": secret_ref, "env": ALLOWED,
                       "argv": ["sh", "-c", format!("printf %s \"${ALLOWED}\"")]}),
            )
            .await;
        assert!(run.get("error").is_some(), "a guessed ref ran: {run}");
        assert!(!run.to_string().contains(&value), "secret_run answered the value");
    }
    // The list answers names and time left, never the value, to anyone who names the chat.
    let listed = agent.call("_acpmux/chat_secrets_list", json!({"sessionId": a})).await;
    assert_eq!(listed["result"]["secrets"][0]["name"], json!(ALLOWED), "{listed}");
    assert!(!listed.to_string().contains(&value), "list answered the value");
    let listed_b = agent.call("_acpmux/chat_secrets_list", json!({"sessionId": b})).await;
    assert_eq!(listed_b["result"]["secrets"], json!([]), "{listed_b}");

    // Never on disk: the daemon's home (store, records, logs), the machine secrets folder, the
    // chats' folders, their Claude home and the agents' HOME.
    // (Before A's agent says it in its chat below: what an agent says is its transcript's.)
    for dir in [root.clone(), home.clone(), home.join(".config").join("cmux")] {
        let hits = files_holding(&dir, value.as_bytes());
        assert!(hits.is_empty(), "the value reached disk: {hits:?}");
    }
    // A's own agent has it.
    assert_eq!(person.ask(&a, &format!("env: {ALLOWED}")).await, format!("{ALLOWED}={value}"));

    // It expires: a value with a 1 s TTL is gone from the list and from the next start.
    let short = person
        .call(
            "_acpmux/chat_secrets_set",
            json!({"sessionId": b, "secrets": {"REDTEAM_SHORT": "short-lived"}, "ttlSeconds": 1}),
        )
        .await;
    assert!(short.get("error").is_none(), "{short}");
    assert_eq!(person.ask(&b, "env: REDTEAM_SHORT").await, "REDTEAM_SHORT=short-lived");
    tokio::time::sleep(Duration::from_millis(1500)).await;
    let gone = person.call("_acpmux/chat_secrets_list", json!({"sessionId": b})).await;
    assert_eq!(gone["result"]["secrets"], json!([]), "{gone}");
    // The next start (another value set restarts B) no longer carries it.
    let next = person
        .call(
            "_acpmux/chat_secrets_set",
            json!({"sessionId": b, "secrets": {"REDTEAM_OTHER": "o"}}),
        )
        .await;
    assert!(next.get("error").is_none(), "{next}");
    assert_eq!(person.ask(&b, "env: REDTEAM_SHORT").await, "REDTEAM_SHORT=");

    // Clearing A drops it from the next start too.
    let cleared = person.call("_acpmux/chat_secrets_clear", json!({"sessionId": a})).await;
    assert_eq!(cleared["result"]["cleared"], json!(1), "{cleared}");
    assert_eq!(person.ask(&a, &format!("env: {ALLOWED}")).await, format!("{ALLOWED}="));

    let _ = std::fs::remove_dir_all(&root);
}
