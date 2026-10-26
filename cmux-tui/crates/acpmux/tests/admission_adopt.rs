//! Adopts of one conversation at this host's lane cap (`hub/admission.rs`): an
//! adopt of a conversation a session holds attaches there and starts nothing, so
//! concurrent adopts of one conversation converge on one session, never a refusal
//! for the duplicates that lost the race for the one lane. A conversation is its
//! id and its harness family, as `new_session` matches it: a Codex adopt of an id a
//! Claude session holds is a new session, and the cap applies to it.
//!
//! Stand-in agents (fake_agent.py). One test function: HOME and FLEET_ORIGIN are
//! read from this process's environment.

#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use acpmux::adopt::HarnessHomes;
use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::Message;
use acpmux::server::{Origin, serve_connection_with};
use serde_json::{Value, json};
use std::path::Path;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");

fn hub() -> Arc<Hub> {
    hub_gated(None)
}

fn hub_gated(folder_gate: Option<acpmux::config::folder_profiles::FolderGate>) -> Arc<Hub> {
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {
            "fakecodex": {"argv": ["python3", FAKE], "family": "codex"},
            "fakeclaude": {"argv": ["python3", FAKE], "family": "claude"},
            "brokencodex": {"argv": ["/nonexistent/acpmux-test-agent"], "family": "codex"},
        },
        "defaultHarness": "fakecodex",
        "permissionPolicy": "approve-all",
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    cfg.folder_gate = folder_gate;
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

/// One `session/new` on a connection of its own: its reply.
async fn new_session(hub: &Arc<Hub>, params: Value) -> Value {
    request(hub, "session/new", params).await
}

/// One request `m` on a connection of its own: its reply.
async fn request(hub: &Arc<Hub>, m: &str, params: Value) -> Value {
    let (in_tx, in_rx) = mpsc::channel(64);
    let (out_tx, mut out_rx) = mpsc::channel(4096);
    tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, Origin::Local));
    in_tx.send(Message::request(1, m, params).to_line()).await.unwrap();
    loop {
        let line =
            tokio::time::timeout(Duration::from_secs(30), out_rx.recv()).await.unwrap().unwrap();
        let v: Value = serde_json::from_str(&line).unwrap();
        if v.get("id") == Some(&json!(1)) {
            return v;
        }
    }
}

/// HOME under `root`, with a fleet registry that gives this host room for one session.
fn at_the_cap_of_one(root: &Path) {
    let home = root.join("home");
    let registry = home.join(".ssh/config.d/fleet-registry.json");
    std::fs::create_dir_all(registry.parent().unwrap()).unwrap();
    let machines = json!({"machines": {"test-box": {"lanes": {"max_lanes": 1}}}});
    std::fs::write(&registry, machines.to_string()).unwrap();
    // SAFETY: one test function in this binary, its scenarios run one after
    // another, each before its sessions start.
    unsafe {
        std::env::set_var("HOME", &home);
        std::env::set_var("ACPMUX_HOME", root.join("acpmux"));
        std::env::set_var("CMUX_NEXT_CONFIG_FILE", root.join("cmux-next.json"));
        std::env::set_var("FLEET_ORIGIN", "test-box");
        std::env::remove_var("FLEET_REGISTRY");
    }
}

/// Writes a Codex rollout of conversation `chat` recorded in `project`.
fn codex_rollout(root: &Path, chat: &str, project: &Path) {
    let rollout =
        root.join(format!("codex/sessions/2026/10/02/rollout-2026-10-02T09-00-00-{chat}.jsonl"));
    std::fs::create_dir_all(rollout.parent().unwrap()).unwrap();
    let record = json!({"type": "session_meta", "payload": {"id": chat, "cwd": project}});
    std::fs::write(&rollout, format!("{record}\n")).unwrap();
}

fn adopt_of(harness: &str, chat: &str) -> Value {
    json!({"mcpServers": [], "_meta": {"acpmux":
        {"harness": harness, "adopt": {"agentSessionId": chat}}}})
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn adopts_at_the_cap() {
    concurrent_adopts_of_one_conversation_at_the_cap_get_the_one_session().await;
    an_adopt_of_an_id_another_family_holds_is_admitted_like_a_new_session().await;
    an_adopt_whose_holder_ends_before_the_create_is_admitted_like_a_new_session().await;
    adopts_waiting_on_one_that_fails_before_its_session_are_admitted_again().await;
    an_adopt_with_a_harness_only_its_worktree_has_starts_there().await;
}

async fn an_adopt_with_a_harness_only_its_worktree_has_starts_there() {
    let root = std::env::temp_dir().join(format!("acpmux-admwtfp-{}", uuid::Uuid::now_v7()));
    at_the_cap_of_one(&root);
    let gate = acpmux::config::folder_profiles::FolderGate {
        enable_record: root.join("acpmux/harness-enable.json"),
        trust: acpmux::trust::Paths {
            claude_json: root.join("claude.json"),
            codex_config: root.join("config.toml"),
            record: root.join("acpmux/trust.json"),
            agent_home: None,
            cmux_worktrees: None,
        },
    };
    let project = root.join("project");
    std::fs::create_dir_all(&project).unwrap();
    git(&project, &["init", "-q"]);
    git(&project, &["commit", "-q", "--allow-empty", "-m", "first"]);
    // Worktree lane-y is there already, and only it has the folder profile `fp`.
    let worktree = root.join("home/.cmux/worktrees/project/lane-y");
    git(&project, &["worktree", "add", "-q", "-b", "cmux/lane-y", &worktree.to_string_lossy()]);
    folder_profile(&worktree, "codex");
    let hub = hub_gated(Some(gate.clone()));
    hub.set_harness_homes(HarnessHomes { claude: root.join("claude"), codex: root.join("codex") });
    trust_and_enable(&hub, &gate, &worktree);
    let chat = uuid::Uuid::now_v7().to_string();
    codex_rollout(&root, &chat, &project);
    let mut adopt = adopt_of("fp", &chat);
    adopt["cwd"] = json!(project);
    adopt["_meta"]["acpmux"]["worktree"] = json!({"name": "lane-y"});
    let r = new_session(&hub, adopt).await;
    let id = r["result"]["sessionId"].as_str().unwrap_or_else(|| panic!("{r}"));
    let session = hub.resolve(id).unwrap();
    assert_eq!(session.meta().family.as_deref(), Some("codex"), "{r}");
    assert!(worktree.exists(), "{r}");

    let _ = std::fs::remove_dir_all(&root);
}

async fn adopts_waiting_on_one_that_fails_before_its_session_are_admitted_again() {
    let root = std::env::temp_dir().join(format!("acpmux-admfail-{}", uuid::Uuid::now_v7()));
    at_the_cap_of_one(&root);
    let project = root.join("project");
    std::fs::create_dir_all(&project).unwrap();
    let chat = uuid::Uuid::now_v7().to_string();
    codex_rollout(&root, &chat, &project);
    let hub = hub();
    hub.set_harness_homes(HarnessHomes { claude: root.join("claude"), codex: root.join("codex") });
    // A Codex harness whose agent never starts: every create fails after its
    // admission and before it makes a session.
    let adopt = adopt_of("brokencodex", &chat);
    // One adopt holds the one lane and fails; those that waited on it find the
    // lane free again, and fail as it did, never refused for room.
    let replies = futures::future::join_all(
        (0..8).map(|_| tokio::spawn(new_session_owned(hub.clone(), adopt.clone()))),
    )
    .await;
    let replies: Vec<Value> = replies.into_iter().map(Result::unwrap).collect();
    for r in &replies {
        assert!(r.get("error").is_some(), "{replies:#?}");
        assert_ne!(r["error"]["data"]["reason"], "admission_refused", "{replies:#?}");
    }
    assert!(hub.sessions().is_empty(), "{replies:#?}");

    let _ = std::fs::remove_dir_all(&root);
}

async fn concurrent_adopts_of_one_conversation_at_the_cap_get_the_one_session() {
    let root = std::env::temp_dir().join(format!("acpmux-admadopt-{}", uuid::Uuid::now_v7()));
    at_the_cap_of_one(&root);
    // One Codex conversation recorded in a project folder.
    let project = root.join("project");
    std::fs::create_dir_all(&project).unwrap();
    let chat = uuid::Uuid::now_v7().to_string();
    codex_rollout(&root, &chat, &project);

    let hub = hub();
    hub.set_harness_homes(HarnessHomes { claude: root.join("claude"), codex: root.join("codex") });
    let adopt = adopt_of("fakecodex", &chat);
    let replies = futures::future::join_all(
        (0..8).map(|_| tokio::spawn(new_session_owned(hub.clone(), adopt.clone()))),
    )
    .await;
    let replies: Vec<Value> = replies.into_iter().map(Result::unwrap).collect();
    for r in &replies {
        assert!(r.get("error").is_none(), "every adopt gets the one session: {replies:#?}");
    }
    let ids: std::collections::HashSet<&str> =
        replies.iter().filter_map(|r| r["result"]["sessionId"].as_str()).collect();
    assert_eq!(ids.len(), 1, "one session: {replies:#?}");

    let _ = std::fs::remove_dir_all(&root);
}

async fn an_adopt_of_an_id_another_family_holds_is_admitted_like_a_new_session() {
    let root = std::env::temp_dir().join(format!("acpmux-admfam-{}", uuid::Uuid::now_v7()));
    at_the_cap_of_one(&root);
    let project = root.join("project");
    std::fs::create_dir_all(&project).unwrap();
    let hub = hub();
    hub.set_harness_homes(HarnessHomes { claude: root.join("claude"), codex: root.join("codex") });
    // A Claude-family session takes the one lane and holds conversation id X.
    let new =
        json!({"cwd": project, "mcpServers": [], "_meta": {"acpmux": {"harness": "fakeclaude"}}});
    let r = new_session(&hub, new).await;
    let id = r["result"]["sessionId"].as_str().unwrap_or_else(|| panic!("{r}")).to_owned();
    let session = hub.resolve(&id).unwrap();
    let chat = session.meta().agent_session_id.unwrap_or_else(|| panic!("no agent id: {r}"));
    // A Codex conversation with the same id: adopting it starts a Codex session,
    // so it needs room, and there is none.
    codex_rollout(&root, &chat, &project);
    let r = new_session(&hub, adopt_of("fakecodex", &chat)).await;
    assert_eq!(r["error"]["data"]["reason"], "admission_refused", "{r}");
    let codex =
        hub.sessions().iter().filter(|s| s.meta().family.as_deref() == Some("codex")).count();
    assert_eq!(codex, 0, "no Codex session past the cap: {r}");

    let _ = std::fs::remove_dir_all(&root);
}

async fn an_adopt_whose_holder_ends_before_the_create_is_admitted_like_a_new_session() {
    let root = std::env::temp_dir().join(format!("acpmux-admgone-{}", uuid::Uuid::now_v7()));
    at_the_cap_of_one(&root);
    let project = root.join("project");
    std::fs::create_dir_all(&project).unwrap();
    let chat = uuid::Uuid::now_v7().to_string();
    codex_rollout(&root, &chat, &project);
    let hub = hub();
    hub.set_harness_homes(HarnessHomes { claude: root.join("claude"), codex: root.join("codex") });
    let r = new_session(&hub, adopt_of("fakecodex", &chat)).await;
    let holder = r["result"]["sessionId"].as_str().unwrap_or_else(|| panic!("{r}")).to_owned();
    // The disk goes under its floor: no new session may start.
    let flag = root.join("home/.cache/worktree-reclaim/under-floor");
    std::fs::create_dir_all(flag.parent().unwrap()).unwrap();
    std::fs::write(&flag, "").unwrap();
    // An adopt finds the conversation held (it would attach, admitting nothing),
    // and is held there while the holder is purged.
    // SAFETY: one test function in this binary; no session reads it concurrently.
    unsafe { std::env::set_var("ACPMUX_TEST_ADOPT_ATTACH_DELAY_MS", "1500") };
    let adopt = tokio::spawn(new_session_owned(hub.clone(), adopt_of("fakecodex", &chat)));
    tokio::time::sleep(Duration::from_millis(300)).await;
    let r = request(&hub, "_acpmux/kill", json!({"sessionId": holder, "purge": true})).await;
    assert!(r.get("error").is_none(), "{r}");
    let r = adopt.await.unwrap();
    unsafe { std::env::remove_var("ACPMUX_TEST_ADOPT_ATTACH_DELAY_MS") };
    // Its create is a new session now: refused under the floor, not made.
    assert_eq!(r["error"]["data"]["reason"], "admission_refused", "{r}");
    assert_eq!(r["error"]["data"]["why"], "under_floor", "{r}");
    assert!(hub.sessions().is_empty(), "no session past the floor: {r}");

    let _ = std::fs::remove_dir_all(&root);
}

fn git(dir: &Path, args: &[&str]) {
    let out = std::process::Command::new("git")
        .args(args)
        .current_dir(dir)
        .env("GIT_AUTHOR_NAME", "t")
        .env("GIT_AUTHOR_EMAIL", "t@example.com")
        .env("GIT_COMMITTER_NAME", "t")
        .env("GIT_COMMITTER_EMAIL", "t@example.com")
        .output()
        .unwrap();
    assert!(out.status.success(), "git {args:?}: {}", String::from_utf8_lossy(&out.stderr));
}

/// A folder profile `fp` of `family` (the stand-in agent) in `folder`.
fn folder_profile(folder: &Path, family: &str) {
    let dir = acpmux::config::folder_profiles::profile_dir(folder);
    std::fs::create_dir_all(&dir).unwrap();
    let text = format!(
        "schema = 1\nid = \"fp\"\nfamily = \"{family}\"\ncommand = \"python3\"\nargs = [{FAKE:?}]\n"
    );
    std::fs::write(dir.join("fp.toml"), text).unwrap();
}

/// Trusts `folder` and enables its folder profile `fp` as its bytes are now.
fn trust_and_enable(
    hub: &Arc<Hub>,
    gate: &acpmux::config::folder_profiles::FolderGate,
    folder: &Path,
) {
    use acpmux::config::folder_profiles as fp;
    acpmux::trust::set(&gate.trust, &folder.to_string_lossy(), "trusted").unwrap();
    let cfg = hub.config.try_read().unwrap().clone();
    let sha = fp::load_one(&cfg, gate, folder, "fp").and_then(|p| p.sha256).expect("sha256");
    fp::enable(&cfg, gate, folder, "fp", &sha).unwrap();
}

async fn new_session_owned(hub: Arc<Hub>, params: Value) -> Value {
    new_session(&hub, params).await
}
