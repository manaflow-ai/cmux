//! ALL-CHATS-ON-DEVICE S5: how a chat opens again. Synthetic temp homes only.
//!
//! - A Claude/Codex chat in the store of a configured profile resumes
//!   through acpmux adopt with that profile (`session/new` params).
//! - A Claude/Codex chat in a store no profile uses (a subrouter account
//!   home, a root the person added) resumes through adopt too, on its
//!   family's profile, with that store as the harness's store (cx-vx54).
//! - Every harness without adopt opens a terminal tab with the resume argv.
//! - A chat whose recorded folder is gone or guarded asks for a folder; it
//!   never falls back to the home folder.
//! - Adopt finds a chat in the store of the profile that resumes it.
//! - An OpenCode chat resumes through adopt too (ACP `session/load`), from
//!   its `opencode.db`, not as a fresh chat in its folder (cx-6edj).

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use acpmux::adopt::HarnessHomes;
use acpmux::chats::ChatSources;
use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::{Message, method};
use acpmux::server::{Origin, serve_connection_with};
use serde_json::{Value, json};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

const CODEX_ID: &str = "0199a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5b";
const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");

struct Home(PathBuf);

impl Drop for Home {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn home(tag: &str) -> Home {
    // Under /tmp, not the temp dir: a worker's temp dir may be on another volume (`/Volumes`),
    // where no chat root is ever listed.
    let base = PathBuf::from("/tmp").join(format!("acpmux-open-{tag}-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&base).unwrap();
    Home(std::fs::canonicalize(&base).unwrap())
}

fn mkdir(path: &Path) -> PathBuf {
    std::fs::create_dir_all(path).unwrap();
    path.to_path_buf()
}

fn config(harnesses: Value) -> Config {
    serde_json::from_value(json!({"harnesses": harnesses})).unwrap()
}

fn homes(h: &Path) -> HarnessHomes {
    HarnessHomes { claude: h.join(".claude"), codex: h.join(".codex") }
}

fn codex_profile(env: &[(&str, &Path)]) -> Value {
    let env: HashMap<&str, String> =
        env.iter().map(|(k, v)| (*k, v.display().to_string())).collect();
    json!({"argv": ["python3", FAKE], "family": "codex", "env": env})
}

fn write_rollout(codex_home: &Path, cwd: &Path) {
    let rollout = codex_home
        .join(format!("sessions/2026/10/02/rollout-2026-10-02T09-00-00-{CODEX_ID}.jsonl"));
    std::fs::create_dir_all(rollout.parent().unwrap()).unwrap();
    let record = json!({"type": "session_meta", "payload": {"id": CODEX_ID, "cwd": cwd, "timestamp": "2026-10-02T09:00:00Z"}});
    // A person's chat has a user message (the index lists no chat without one).
    let prompt = json!({"type": "event_msg", "timestamp": "2026-10-02T09:00:01Z", "payload": {"type": "user_message", "message": "Fix the build"}});
    std::fs::write(&rollout, format!("{record}\n{prompt}\n")).unwrap();
    // Written an hour ago, like a person's earlier chat.
    let hour_ago = std::time::SystemTime::now() - Duration::from_secs(3600);
    std::fs::File::options().write(true).open(&rollout).unwrap().set_modified(hour_ago).unwrap();
}

async fn call(
    tx: &mpsc::Sender<String>,
    rx: &mut mpsc::Receiver<String>,
    id: i64,
    m: &str,
    params: Value,
) -> Value {
    tx.send(Message::request(id, m, params).to_line()).await.unwrap();
    loop {
        let line = tokio::time::timeout(Duration::from_secs(20), rx.recv()).await.unwrap().unwrap();
        let v: Value = serde_json::from_str(&line).unwrap();
        if v.get("id") == Some(&json!(id)) {
            return v;
        }
    }
}

/// The open plan's `sessionNew` params create the adopted session through
/// the profile whose store holds the chat (not the daemon's default store).
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn chat_open_then_session_new_adopts_from_the_profile_store() {
    let h = home("rpc");
    let project = mkdir(&h.0.join("work/api"));
    let alt = mkdir(&h.0.join("codex-alt"));
    write_rollout(&alt, &project);
    let mut cfg = config(json!({"fakecodex": codex_profile(&[("CODEX_HOME", &alt)])}));
    cfg.default_harness = Some("fakecodex".into());
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    hub.set_harness_homes(homes(&h.0)); // the default stores hold nothing
    let mut sources = ChatSources {
        home: h.0.clone(),
        acpmux_home: h.0.join(".acpmux"),
        env: Arc::new(|_| None),
        launch_roots: Vec::new(),
        user_roots: Vec::new(),
    };
    sources.launch_roots = acpmux::chats::launch_roots(&*hub.config.read().await);
    hub.start_chats(sources).await.unwrap();

    let (tx, in_rx) = mpsc::channel(64);
    let (out_tx, mut rx) = mpsc::channel(4096);
    tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, Origin::Local));
    call(
        &tx,
        &mut rx,
        1,
        method::INITIALIZE,
        json!({"protocolVersion": 1, "clientInfo": {"name": "t"}}),
    )
    .await;

    let key = format!("codex:{CODEX_ID}");
    let plan = call(&tx, &mut rx, 2, "_acpmux/chat_open", json!({"key": key})).await;
    let plan = &plan["result"];
    assert_eq!(plan["kind"], "adopt", "{plan}");
    assert_eq!(plan["adopt"]["harness"], "fakecodex");
    // The profile is named freely; the family says what kind of chat it is (View Only needs it).
    assert_eq!(plan["family"], "codex", "{plan}");
    // The chat itself comes with its plan (P-RUST step 2): the app names it without an index copy.
    assert_eq!(plan["chat"]["key"], key, "{plan}");
    assert_eq!(plan["chat"]["harness"], "codex", "{plan}");
    let created = call(&tx, &mut rx, 3, method::SESSION_NEW, plan["sessionNew"].clone()).await;
    assert!(created.get("error").is_none(), "{created}");
    let session = hub.resolve(created["result"]["sessionId"].as_str().unwrap()).unwrap();
    assert_eq!(session.meta().agent_session_id.as_deref(), Some(CODEX_ID));
    assert_eq!(session.meta().cwd, project);

    let unknown = call(&tx, &mut rx, 4, "_acpmux/chat_open", json!({"key": "codex:nope"})).await;
    assert!(unknown["error"].is_object(), "{unknown}");
    let bad = call(&tx, &mut rx, 5, "_acpmux/chat_open", json!({"key": "no-colon"})).await;
    assert!(bad["error"]["message"].as_str().unwrap().contains("key"), "{bad}");
}

/// The reply to one request and the agent text streamed before it.
async fn call_text(
    tx: &mpsc::Sender<String>,
    rx: &mut mpsc::Receiver<String>,
    id: i64,
    m: &str,
    params: Value,
) -> (Value, String) {
    tx.send(Message::request(id, m, params).to_line()).await.unwrap();
    let mut text = String::new();
    loop {
        let line = tokio::time::timeout(Duration::from_secs(20), rx.recv()).await.unwrap().unwrap();
        let v: Value = serde_json::from_str(&line).unwrap();
        if v.get("id") == Some(&json!(id)) {
            return (v, text);
        }
        if let Some(t) = v.pointer("/params/update/content/text").and_then(Value::as_str) {
            text.push_str(t);
        }
    }
}

/// A chat in a store no profile uses (here a root the person added) opens
/// as an adopted session on its family's profile, not as a fresh chat: the
/// harness runs with that store as its CODEX_HOME, found by acpmux in its
/// own index, so the conversation resumes (cx-vx54).
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_chat_in_a_store_no_profile_uses_adopts_with_that_store() {
    let h = home("any-store");
    let project = mkdir(&h.0.join("work/api"));
    let other = mkdir(&h.0.join("subrouter/codex-home"));
    write_rollout(&other, &project);
    let mut cfg = config(json!({"fakecodex": codex_profile(&[])}));
    cfg.default_harness = Some("fakecodex".into());
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    hub.set_harness_homes(homes(&h.0)); // the profile's store (~/.codex) holds nothing
    let sources = ChatSources {
        home: h.0.clone(),
        acpmux_home: h.0.join(".acpmux"),
        env: Arc::new(|_| None),
        launch_roots: Vec::new(),
        user_roots: vec![cmux_chat_index::RootSpec {
            harness: cmux_chat_index::AdapterKind::Codex,
            path: other.clone(),
            label: None,
        }],
    };
    hub.start_chats(sources).await.unwrap();

    let (tx, in_rx) = mpsc::channel(64);
    let (out_tx, mut rx) = mpsc::channel(4096);
    tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, Origin::Local));
    call(
        &tx,
        &mut rx,
        1,
        method::INITIALIZE,
        json!({"protocolVersion": 1, "clientInfo": {"name": "t"}}),
    )
    .await;

    let key = format!("codex:{CODEX_ID}");
    let mut plan = Value::Null;
    for attempt in 0..100 {
        plan = call(&tx, &mut rx, 10 + attempt, "_acpmux/chat_open", json!({"key": key})).await;
        if plan.get("result").is_some() {
            break;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    let plan = &plan["result"];
    assert_eq!(plan["kind"], "adopt", "{plan}");
    assert_eq!(plan["adopt"]["harness"], "fakecodex");
    let created = call(&tx, &mut rx, 200, method::SESSION_NEW, plan["sessionNew"].clone()).await;
    assert!(created.get("error").is_none(), "{created}");
    let id = created["result"]["sessionId"].as_str().unwrap().to_owned();
    let session = hub.resolve(&id).unwrap();
    assert_eq!(session.meta().agent_session_id.as_deref(), Some(CODEX_ID));
    assert_eq!(session.meta().cwd, project);
    let prompt = json!({"sessionId": id, "prompt": [{"type": "text", "text": "env: CODEX_HOME"}]});
    let (reply, text) = call_text(&tx, &mut rx, 201, "session/prompt", prompt).await;
    assert!(reply.get("error").is_none(), "{reply}");
    assert!(text.contains(&format!("CODEX_HOME={}", other.display())), "{text}");

    // A client cannot point an adopt at a store: an id that no index store
    // holds is still refused.
    let stray = json!({"cwd": project, "mcpServers": [], "_meta": {"acpmux": {"harness": "fakecodex",
        "adopt": {"harness": "fakecodex", "agentSessionId": "0199a1b2-c3d4-7e5f-8a9b-000000000000"}}}});
    let refused = call(&tx, &mut rx, 202, method::SESSION_NEW, stray).await;
    assert!(refused["error"].is_object(), "{refused}");
}

const OPENCODE_ID: &str = "ses_6edj0001opencodechat";

/// Runs `script` (Python, `sqlite3` imported) with the database path as `db`.
fn sqlite(db: &Path, script: &str) {
    std::fs::create_dir_all(db.parent().expect("parent")).expect("dirs");
    let code =
        format!("import sqlite3, sys\ndb = sqlite3.connect(sys.argv[1])\n{script}\ndb.commit()\n");
    let status = std::process::Command::new("python3")
        .args(["-c", &code])
        .arg(db)
        .status()
        .expect("python3");
    assert!(status.success(), "sqlite fixture {}", db.display());
}

/// An OpenCode 1.2+ chat (`session`, `message`, `part`) in `<data>/opencode/opencode.db`.
fn write_opencode(h: &Path, cwd: &Path) {
    let db = h.join(".local/share/opencode/opencode.db");
    let rows = json!({
        "session": [OPENCODE_ID, "Name the CLI", cwd, 1_759_395_600_000_i64, 1_759_395_605_000_i64],
        "message": ["msg_1", OPENCODE_ID, json!({"role": "user"}).to_string()],
        "part": ["prt_1", "msg_1", OPENCODE_ID, json!({"type": "text", "text": "Name the CLI"}).to_string()],
    });
    let script = format!(
        "import json\nrows = json.loads({rows:?})\n\
         db.execute('create table session (id text primary key, parent_id text, title text, directory text, time_created integer, time_updated integer, time_archived integer)')\n\
         db.execute('create table message (id text primary key, session_id text, data text)')\n\
         db.execute('create table part (id text primary key, message_id text, session_id text, data text)')\n\
         db.execute('insert into session values (?, null, ?, ?, ?, ?, null)', rows['session'])\n\
         db.execute('insert into message values (?, ?, ?)', rows['message'])\n\
         db.execute('insert into part values (?, ?, ?, ?)', rows['part'])",
        rows = rows.to_string(),
    );
    sqlite(&db, &script);
}

/// An OpenCode chat from All chats resumes over ACP (`session/load` with its id, in its
/// folder) on the opencode profile; it used to open a fresh chat in its folder.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_opencode_chat_opens_by_adopting_it_over_acp() {
    let h = home("opencode");
    let project = mkdir(&h.0.join("work/cli"));
    write_opencode(&h.0, &project);
    let mut cfg = config(json!({"fopencode": {"argv": ["python3", FAKE], "family": "opencode"}}));
    cfg.default_harness = Some("fopencode".into());
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    hub.set_harness_homes(homes(&h.0));
    let mut sources = ChatSources {
        home: h.0.clone(),
        acpmux_home: h.0.join(".acpmux"),
        env: Arc::new(|_| None),
        launch_roots: Vec::new(),
        user_roots: Vec::new(),
    };
    sources.launch_roots = acpmux::chats::launch_roots(&*hub.config.read().await);
    hub.start_chats(sources).await.unwrap();

    let (tx, in_rx) = mpsc::channel(64);
    let (out_tx, mut rx) = mpsc::channel(4096);
    tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, Origin::Local));
    let init = json!({"protocolVersion": 1, "clientInfo": {"name": "t"}});
    call(&tx, &mut rx, 1, method::INITIALIZE, init).await;

    let key = format!("opencode:{OPENCODE_ID}");
    let plan = call(&tx, &mut rx, 2, "_acpmux/chat_open", json!({"key": key})).await;
    let plan = &plan["result"];
    assert_eq!(plan["kind"], "adopt", "{plan}");
    assert_eq!(plan["adopt"]["harness"], "fopencode", "{plan}");
    let created = call(&tx, &mut rx, 3, method::SESSION_NEW, plan["sessionNew"].clone()).await;
    assert!(created.get("error").is_none(), "{created}");
    let session = hub.resolve(created["result"]["sessionId"].as_str().unwrap()).unwrap();
    assert_eq!(session.meta().agent_session_id.as_deref(), Some(OPENCODE_ID));
    assert_eq!(session.meta().cwd, project);
}

const MUSE_ID: &str = "019a5b7e-1c2d-7e3f-8a9b-0c1d2e3f4a5b";

/// Muse Code's `session-index.db` in `<data>/muse`, in the shape Muse 1.4
/// writes: a person's chat, a subagent child of it and a worker that never
/// got a prompt. Only the person's chat is listed.
fn write_muse(h: &Path, cwd: &Path) {
    let db = h.join(".local/share/muse/session-index.db");
    let rows = json!([
        [
            MUSE_ID,
            null,
            null,
            "Ship the parser\nwith tests",
            cwd,
            1_759_395_600_000_000_i64,
            1_759_395_605_000_000_i64,
            2,
            null,
            "root"
        ],
        [
            "019a5b7e-0000-7000-8000-00000000c1d0",
            null,
            null,
            "check the tests",
            cwd,
            1_759_395_601_000_000_i64,
            1_759_395_602_000_000_i64,
            1,
            MUSE_ID,
            "subagent"
        ],
        [
            "019a5b7e-0000-7000-8000-0000000003b5",
            null,
            null,
            null,
            cwd,
            1_759_395_601_000_000_i64,
            1_759_395_602_000_000_i64,
            0,
            null,
            "root"
        ],
    ]);
    let script = format!(
        "import json\nrows = json.loads({rows:?})\n\
         db.execute('create table sessions (session_id text primary key, session_name text, title text, first_user_prompt text, workspace_root text, created_at_us integer, updated_at_us integer, prompt_count integer, msp_parent_session_id text, msp_kind text, git_branch text, search_text text)')\n\
         db.executemany('insert into sessions values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, null, null)', rows)",
        rows = rows.to_string(),
    );
    sqlite(&db, &script);
}

/// A Muse Code chat from All chats lists with its first prompt as the title and opens
/// `muse resume <id>` in a terminal tab in its own folder (Muse resumes per workspace).
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_muse_chat_lists_and_opens_muse_resume_in_its_folder() {
    let h = home("muse");
    let project = mkdir(&h.0.join("work/parser"));
    write_muse(&h.0, &project);
    let mut cfg = config(json!({"fake": {"argv": ["python3", FAKE]}}));
    cfg.default_harness = Some("fake".into());
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    hub.set_harness_homes(homes(&h.0));
    let sources = ChatSources {
        home: h.0.clone(),
        acpmux_home: h.0.join(".acpmux"),
        env: Arc::new(|_| None),
        launch_roots: Vec::new(),
        user_roots: Vec::new(),
    };
    hub.start_chats(sources).await.unwrap();

    let (tx, in_rx) = mpsc::channel(64);
    let (out_tx, mut rx) = mpsc::channel(4096);
    tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, Origin::Local));
    let init = json!({"protocolVersion": 1, "clientInfo": {"name": "t"}});
    call(&tx, &mut rx, 1, method::INITIALIZE, init).await;

    let listed = call(&tx, &mut rx, 2, "_acpmux/chats", json!({"harness": "muse"})).await;
    let chats = listed["result"]["chats"].as_array().expect("chats").clone();
    let key = format!("muse:{MUSE_ID}");
    assert_eq!(
        chats.iter().map(|chat| chat["key"].as_str().unwrap_or_default()).collect::<Vec<_>>(),
        [key.as_str()],
        "{listed}"
    );
    assert_eq!(chats[0]["title"], "Ship the parser", "{listed}");
    assert_eq!(chats[0]["cwd"], json!(project), "{listed}");

    let plan = call(&tx, &mut rx, 3, "_acpmux/chat_open", json!({"key": key})).await;
    let plan = &plan["result"];
    assert_eq!(plan["kind"], "terminal", "{plan}");
    assert_eq!(plan["terminal"]["argv"], json!(["muse", "resume", MUSE_ID]), "{plan}");
    assert_eq!(plan["cwd"], json!(project), "{plan}");
}
