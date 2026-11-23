use super::*;
use crate::config::{Config, StoreMode};
use crate::store::MemoryStore;

fn hub() -> Arc<Hub> {
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py")]}},
        "defaultHarness": "fake",
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    Hub::new(cfg, Box::new(MemoryStore::default()))
}

fn scratch(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("acpmux-auto-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

fn pending(name: &str, socket: &str, token: &str, age: u64) -> Pending {
    Pending {
        code: "c0de".into(),
        started: 7,
        socket: PathBuf::from(socket),
        token: token.into(),
        name: name.into(),
        at: Instant::now().checked_sub(Duration::from_secs(age)).unwrap_or_else(Instant::now),
    }
}

fn answer(step: Step) -> Value {
    match step {
        Step::Answer(v) => v,
        Step::Go(_) => panic!("expected an answer, got a step to prove"),
    }
}

/// A send from an unregistered chat asks for the first step on every send; a code still
/// waiting for its echo there is found, so no second one is delivered.
#[test]
fn a_waiting_code_is_found_by_its_inbox_and_token_until_it_expires() {
    let sock = Path::new("/tmp/cc-socks/1.sock");
    let mut codes = HashMap::new();
    codes.insert(1, pending("claude-desktop-03214b87", "/tmp/cc-socks/1.sock", "tok", 5));
    assert_eq!(pending_name(&codes, sock, "tok").as_deref(), Some("claude-desktop-03214b87"));
    assert_eq!(pending_name(&codes, sock, "other"), None, "another token");
    assert_eq!(pending_name(&codes, Path::new("/tmp/cc-socks/2.sock"), "tok"), None);
    let old = CODE_TTL.as_secs() + 1;
    codes.insert(1, pending("claude-desktop-03214b87", "/tmp/cc-socks/1.sock", "tok", old));
    assert_eq!(pending_name(&codes, sock, "tok"), None, "expired: a new code goes");
}

/// A chat registered with the caller's inbox and token answers at once, with its name; a
/// restarted process (a new token) is not taken for it.
#[tokio::test]
async fn a_chat_registered_with_the_callers_token_is_answered_with_no_proof() {
    let home = scratch("registered");
    let hub = hub();
    let cwd = Some(home.clone());
    let session =
        hub.new_session(crate::hub::NewRequest { cwd, ..Default::default() }).await.unwrap();
    session.meta.lock().unwrap().name = "desktop-zoe".into();
    mark_registered_for_test(&session.id);
    let sock = home.join("inbox.sock");
    let kept = crate::claude_peers::ChildToken {
        pid: 42,
        socket: sock.clone(),
        token: "tok-registered".into(),
        started: Some(7),
    };
    crate::claude_peers::save_token(&home, &session.id, &kept).unwrap();
    let v = answer(hub.auto_answer(&home, &sock, "tok-registered"));
    assert_eq!(v, json!({"registered": true, "name": "desktop-zoe"}));
    assert!(
        matches!(hub.auto_answer(&home, &sock, "tok-after-restart"), Step::Go(_)),
        "a new token proves again"
    );
}

/// Repro: two sends at once both missed the waiting-code check and both delivered a code
/// (the second replacing the first). The first reserves the step; the second is told a code
/// is coming; once the first is done another may go.
#[test]
fn two_sends_at_once_start_one_step() {
    let hub = hub();
    let (home, sock) = (scratch("race"), Path::new("/tmp/cc-socks/race.sock"));
    let first = hub.auto_answer(&home, sock, "tok-race");
    assert!(matches!(first, Step::Go(_)));
    let second = answer(hub.auto_answer(&home, sock, "tok-race"));
    assert_eq!(second, json!({"pending": true, "resent": false}));
    assert!(matches!(hub.auto_answer(&home, sock, "tok-other"), Step::Go(_)), "own key");
    drop(first);
    assert!(matches!(hub.auto_answer(&home, sock, "tok-race"), Step::Go(_)), "released");
}

/// A failure (an unsigned process, a chat with no transcript yet, a taken name) is kept for
/// its inbox and token, so the next sends neither prove again nor warn again.
#[test]
fn a_failure_is_answered_again_without_a_new_proof() {
    let hub = hub();
    let (home, sock) = (scratch("failed"), Path::new("/tmp/cc-socks/failed.sock"));
    let Step::Go(step) = hub.auto_answer(&home, sock, "tok-failed") else { panic!() };
    step.failed("register.unproven: process 42 is not signed as Claude Code");
    drop(step);
    let v = answer(hub.auto_answer(&home, sock, "tok-failed"));
    assert_eq!(v["repeat"], true, "{v}");
    assert!(v["failed"].as_str().unwrap().contains("not signed"), "{v}");
}

/// The answer comes before any proof: a caller no Claude Code process runs (pid 1 here,
/// which the proof would refuse as `register.no_session`) is told of its waiting code.
#[tokio::test]
async fn an_automatic_step_with_a_waiting_code_is_answered_before_the_proof() {
    let hub = hub();
    let sock = "/tmp/cc-socks/early.sock";
    PENDING
        .lock()
        .unwrap()
        .insert(900_101, pending("claude-desktop-0badc0de", sock, "tok-early", 1));
    let req = |auto| RegisterRequest {
        name: "claude-desktop-0badc0de".into(),
        socket: Some(PathBuf::from(sock)),
        token: Some("tok-early".into()),
        code: None,
        auto,
        renew: false,
    };
    let v = hub.register_caller(1, req(true)).await.unwrap();
    assert_eq!(v, json!({"pending": true, "resent": false, "name": "claude-desktop-0badc0de"}));
    let err = hub.register_caller(1, req(false)).await.unwrap_err();
    assert!(err.message.contains("no Claude Code session"), "typed register proves: {err:?}");
    PENDING.lock().unwrap().remove(&900_101);
}

fn own(name: &str, registered: bool, watched: bool) -> Option<Own> {
    Some(Own { name: name.into(), registered, watched })
}

/// Repro: after a Claude Code restart (a new token) the registered chat `desktop-zoe` got a
/// code for `claude-desktop-<id8>`, and finishing it renamed the chat, breaking its address.
/// A chat with a name is registered under that name; a chat the bridge reaches gets no code.
#[test]
fn a_chat_with_a_name_keeps_it_and_one_the_bridge_reaches_gets_no_code() {
    let none = |_: &str| false;
    let asked = "claude-desktop-03214b87";
    let p = plan(asked, own("desktop-zoe", true, true), false, none);
    assert_eq!(p, Plan::Code("desktop-zoe".into()), "registered, restarted");
    let p = plan(asked, own("desktop-zoe", true, true), true, none);
    assert_eq!(p, Plan::Code("desktop-zoe".into()), "registered needs its token, bridge or not");
    let p = plan(asked, own("my-folder", false, true), true, none);
    assert_eq!(p, Plan::Reachable(Some("my-folder".into())), "the bridge lists it");
    let p = plan(asked, own("my-folder", false, true), false, none);
    assert_eq!(p, Plan::Code("my-folder".into()), "listed before, setting off now");
    assert_eq!(plan(asked, None, true, none), Plan::Reachable(None), "listed on its next scan");
    assert_eq!(plan(asked, None, false, none), Plan::Code(asked.into()));
    let taken = |name: &str| name == asked;
    assert_eq!(plan(asked, None, false, taken), Plan::Taken, "another session's name");
    let p = plan(asked, own(asked, false, false), false, taken);
    assert_eq!(p, Plan::Code(asked.into()), "its own name is not taken from it");
}

/// Repro: an older daemon ignores `auto` and delivers a code on every send; the CLI asks
/// only a daemon that lists the feature (`cli/reply_address.rs`).
#[tokio::test]
async fn initialize_lists_the_automatic_register_feature() {
    let hub = hub();
    let (input, incoming) = tokio::sync::mpsc::channel(8);
    let (output, mut outgoing) = tokio::sync::mpsc::channel(8);
    let task = tokio::spawn(crate::server::serve_connection(hub.clone(), incoming, output));
    let hello = crate::rpc::Message::request(1, "initialize", json!({"protocolVersion": 1}));
    input.send(hello.to_line()).await.unwrap();
    // timeout: Test-only deadline detects a missing reply; no user request is cancelled.
    let line =
        tokio::time::timeout(Duration::from_secs(10), outgoing.recv()).await.unwrap().unwrap();
    drop(input);
    task.abort();
    let reply: Value = serde_json::from_str(&line).unwrap();
    let features = reply["result"]["_meta"]["acpmux"]["features"].as_array().unwrap();
    assert!(features.iter().any(|f| f == AUTO_FEATURE), "{reply}");
}
