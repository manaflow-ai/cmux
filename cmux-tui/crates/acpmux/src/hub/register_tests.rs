use super::*;
use crate::claude_peers::Peer;

fn peer(pid: u32, socket: &str) -> Peer {
    Peer {
        pid,
        session_id: format!("sid-{pid}"),
        cwd: None,
        entrypoint: Some("claude-desktop".into()),
        kind: Some("interactive".into()),
        name: None,
        version: None,
        socket: Some(PathBuf::from(socket)),
    }
}

#[test]
fn the_nearest_claude_ancestor_with_the_callers_inbox_registers() {
    let live = vec![peer(42, "/s/42.sock"), peer(7, "/s/7.sock")];
    // acpmux (50) under bash (45) under claude 42, itself run inside claude 7's shell.
    let ancestry = [50, 45, 42, 30, 7, 1];
    assert_eq!(nearest_claude(&ancestry, &live, None).map(|p| p.pid), Some(42));
    let inbox = std::path::Path::new("/s/42.sock");
    assert_eq!(nearest_claude(&ancestry, &live, Some(inbox)).map(|p| p.pid), Some(42));
    // An inbox that is not the ancestor's: nothing, never another session.
    let other = std::path::Path::new("/s/99.sock");
    assert_eq!(nearest_claude(&ancestry, &live, Some(other)), None);
    // Not under any listed session: nothing.
    assert_eq!(nearest_claude(&[50, 45, 1], &live, None), None);
}

#[cfg(unix)]
#[tokio::test]
async fn renew_hook_retries_an_unavailable_inbox_but_rejects_the_wrong_owner() {
    let dir = tempfile::tempdir().unwrap();
    let socket = dir.path().join("inbox.sock");
    let claimed = peer(0, socket.to_str().unwrap());
    assert_eq!(prove_claude(&claimed, dir.path(), &socket, true).await.unwrap(), None);
    assert!(prove_claude(&claimed, dir.path(), &socket, false).await.is_err());

    // Once it answers, this process owns the socket. The wrong PID is a hard failure.
    let _listener = tokio::net::UnixListener::bind(&socket).unwrap();
    assert!(!crate::claude_peers::inbox_proof(&socket, claimed.pid).await.unwrap());
    assert!(prove_claude(&claimed, dir.path(), &socket, true).await.is_err());
    let link = dir.path().join("link.sock");
    std::os::unix::fs::symlink(&socket, &link).unwrap();
    let owner = peer(std::process::id(), link.to_str().unwrap());
    assert!(!crate::claude_peers::inbox_proof(&link, owner.pid).await.unwrap());
    assert!(prove_claude(&owner, dir.path(), &link, true).await.is_err());
}

/// A hub with one chat named `name`, registered, its token kept in `home` for this test's
/// own process, started at `started`.
async fn holder(home: &std::path::Path, name: &str, started: u64) -> (Arc<Hub>, Arc<Session>) {
    use crate::config::{Config, StoreMode};
    let mut config = Config::default();
    config.store.mode = StoreMode::Memory;
    let store = crate::store::open(&config.store, std::path::Path::new("/unused")).unwrap();
    let hub = Hub::new(config, store);
    let id = uuid::Uuid::now_v7().to_string();
    let meta: crate::store::SessionMeta = serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": id, "name": name,
        "harness": "claude", "cwd": "/tmp", "status": "idle", "createdAt": 1, "updatedAt": 1
    }))
    .unwrap();
    hub.store.save(&meta).unwrap();
    let session = hub.make_session(meta);
    hub.sessions.lock().unwrap().insert(session.id.clone(), session.clone());
    mark_registered_for_test(&session.id);
    let kept = crate::claude_peers::ChildToken {
        pid: std::process::id(),
        socket: home.join("inbox.sock"),
        token: "t".into(),
        started: Some(started),
    };
    crate::claude_peers::save_token(home, &session.id, &kept).unwrap();
    (hub, session)
}

/// Leo, 2026-11-25: `acpmux register NAME` takes a name held by a registered chat whose
/// Claude process is gone, renaming the dead holder `NAME-gone-<short>`.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_gone_registered_holder_yields_its_name() {
    let (home, claude_home) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
    let (hub, held) = holder(home.path(), "mango-reg", 1_000).await;
    // No live registry entry has that process start: it is gone.
    hub.yield_name_of_gone(&held, "mango-reg", home.path(), claude_home.path()).await.unwrap();
    let renamed = held.meta().name;
    assert!(renamed.starts_with("mango-reg-gone-"), "{renamed}");
    assert_eq!(renamed.len(), "mango-reg-gone-".len() + 8, "{renamed}");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_live_registered_holder_still_refuses_with_name_taken() {
    let (home, claude_home) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
    // Its process (this test's own) runs, with the start its token names.
    let me = std::process::id();
    let started = crate::adopt_live::pid_start_ms(me).expect("this process's start");
    let (hub, held) = holder(home.path(), "mango-live", started).await;
    let registry = crate::claude_peers::registry(claude_home.path());
    std::fs::create_dir_all(&registry).unwrap();
    let entry = json!({"pid": me, "sessionId": "sid-live", "startedAt": started});
    std::fs::write(registry.join(format!("{me}.json")), entry.to_string()).unwrap();
    assert_eq!(crate::claude_peers::started_at(claude_home.path(), me), Some(started));
    let e = hub
        .yield_name_of_gone(&held, "mango-live", home.path(), claude_home.path())
        .await
        .unwrap_err();
    assert_eq!(e.data.as_ref().unwrap()["reason"], "register.name_taken", "{}", e.message);
    assert_eq!(held.meta().name, "mango-live");
    // Its process runs with no registry entry at all: still taken.
    std::fs::remove_file(registry.join(format!("{me}.json"))).unwrap();
    let e = hub
        .yield_name_of_gone(&held, "mango-live", home.path(), claude_home.path())
        .await
        .unwrap_err();
    assert_eq!(e.data.as_ref().unwrap()["reason"], "register.name_taken", "{}", e.message);
    // Nor does a chat that was never registered yield, gone or not.
    assert!(!registered_chat_gone(false, None, None));
    let kept = crate::claude_peers::ChildToken {
        pid: me,
        socket: home.path().join("inbox.sock"),
        token: "t".into(),
        started: Some(2_000),
    };
    assert!(!registered_chat_gone(false, Some(&kept), None));
    assert!(registered_chat_gone(true, Some(&kept), None));
    assert!(!registered_chat_gone(true, Some(&kept), Some(2_000)));
    // A token with no recorded start proves nothing either way: the name stays.
    let unknown = crate::claude_peers::ChildToken { started: None, ..kept };
    assert!(!registered_chat_gone(true, Some(&unknown), None));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_failed_takeover_leaves_a_gone_incumbents_address_unchanged() {
    let (home, claude_home) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
    let (hub, incumbent) = holder(home.path(), "mango-retry", 1_000).await;
    let id = uuid::Uuid::now_v7().to_string();
    let meta: crate::store::SessionMeta = serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": id, "name": "claimant",
        "harness": "claude", "cwd": "/tmp", "status": "idle", "createdAt": 1, "updatedAt": 1
    }))
    .unwrap();
    hub.store.save(&meta).unwrap();
    let shown = hub.make_session(meta);
    hub.sessions.lock().unwrap().insert(shown.id.clone(), shown.clone());
    mark_registered_for_test(&shown.id);
    crate::claude_peers::save_token(
        home.path(),
        &shown.id,
        &crate::claude_peers::ChildToken {
            pid: std::process::id(),
            socket: home.path().join("claimant.sock"),
            token: "t".into(),
            started: Some(1_000),
        },
    )
    .unwrap();

    let claimed = peer(99, "/s/99.sock");
    let error = hub
        .validate_registered_claim(
            Some(&shown),
            &claimed,
            2_000,
            None,
            &claimed.session_id,
            home.path(),
            claude_home.path(),
        )
        .unwrap_err();
    assert_eq!(error.data.as_ref().unwrap()["reason"], "register.unproven");
    assert_eq!(incumbent.meta().name, "mango-retry");
}

#[test]
fn the_walk_stops_below_this_daemon() {
    let me = std::process::id();
    assert_eq!(below_daemon(vec![50, 45, me, 42, 1]), vec![50, 45]);
    assert_eq!(below_daemon(vec![50, 42, 1]), vec![50, 42, 1]);
}

/// The second step takes only the code delivered to that same process, for the same name,
/// inbox, token and start, and each code once (repro: a process echoing a guessed or replayed
/// code, or another session's).
#[test]
fn a_register_code_is_taken_once_and_only_from_its_own_process() {
    let put = |pid: u32| {
        let pending = Pending {
            code: "c0de".into(),
            started: 7,
            socket: PathBuf::from("/tmp/cc-socks/1.sock"),
            token: "tok".into(),
            name: "desktop-zoe".into(),
            at: std::time::Instant::now(),
        };
        PENDING.lock().unwrap().insert(pid, pending);
    };
    let sock = std::path::Path::new("/tmp/cc-socks/1.sock");
    put(900_001);
    assert!(take_code(900_001, "c0de", 7, sock, "tok", "desktop-zoe").is_ok());
    assert!(take_code(900_001, "c0de", 7, sock, "tok", "desktop-zoe").is_err(), "once");
    put(900_002);
    assert!(take_code(900_002, "guess", 7, sock, "tok", "desktop-zoe").is_err());
    assert!(
        take_code(900_002, "c0de", 7, sock, "tok", "desktop-zoe").is_err(),
        "a miss uses it up"
    );
    put(900_003);
    assert!(take_code(900_004, "c0de", 7, sock, "tok", "desktop-zoe").is_err(), "another process");
    assert!(take_code(900_003, "c0de", 8, sock, "tok", "desktop-zoe").is_err(), "a later process");
    put(900_005);
    assert!(take_code(900_005, "c0de", 7, sock, "tok", "other-name").is_err());
    put(900_006);
    assert!(take_code(900_006, "c0de", 7, sock, "other", "desktop-zoe").is_err());
}

#[test]
fn an_automatic_code_says_why_it_came_and_where_replies_go() {
    let text = code_text("claude-desktop-03214b87", "c0de", &Why::Send("cosmic-gray".into()));
    assert!(text.contains("its receiver cannot answer you"), "{text}");
    assert!(text.contains("acpmux register claude-desktop-03214b87 --code c0de"), "{text}");
    assert!(text.contains("replies reach cosmic-gray/claude-desktop-03214b87"), "{text}");
    let asked = code_text("desktop-zoe", "c0de", &Why::Asked);
    assert!(asked.contains("acpmux register desktop-zoe --code c0de"), "{asked}");
    assert!(!asked.contains("acpmux send"), "{asked}");
}

#[test]
fn auto_is_the_first_step_only() {
    let first = json!({"name": "claude-desktop-0321", "socket": "/s", "token": "t", "auto": true});
    assert!(RegisterRequest::from_params(&first).unwrap().auto);
    let manual = json!({"name": "desktop-zoe", "socket": "/s", "token": "t"});
    assert!(!RegisterRequest::from_params(&manual).unwrap().auto);
    let both = json!({"name": "desktop-zoe", "token": "t", "auto": true, "code": "c0de"});
    assert!(RegisterRequest::from_params(&both).is_err());
}

/// Repro (Leo, 2026-11-20, of a terminal coordinator restarted with `--resume`: "isn't one I
/// can message through acpmux"): the restarted process handed acpmux no token, so sends
/// waited on `bridge.registration_stale` until a person ran `acpmux register` in it.
#[test]
fn only_a_registered_chat_resumed_for_its_own_conversation_renews() {
    assert!(renewable(true, Some("6e0bad7d"), "6e0bad7d"));
    assert!(!renewable(false, Some("6e0bad7d"), "6e0bad7d"), "never registered");
    assert!(!renewable(true, None, "6e0bad7d"), "a launch that names no conversation");
    assert!(!renewable(true, Some("other"), "6e0bad7d"), "another conversation");
}

#[test]
fn renew_takes_no_code() {
    let renew =
        json!({"name": "claude-code-6e0bad7d", "socket": "/s", "token": "t", "renew": true});
    assert!(RegisterRequest::from_params(&renew).unwrap().renew);
    let both = json!({"name": "claude-code-6e0bad7d", "token": "t", "renew": true, "code": "c"});
    assert!(RegisterRequest::from_params(&both).is_err());
}

#[test]
fn a_tag_alone_never_registers_a_chat() {
    assert!(!with_registered(|set| set.contains("never-registered-chat")));
    mark_registered_for_test("chat-registered-in-test");
    assert!(with_registered(|set| set.contains("chat-registered-in-test")));
}

#[test]
fn a_request_needs_a_valid_name_and_a_one_line_token() {
    assert!(RegisterRequest::from_params(&json!({})).is_err());
    assert!(RegisterRequest::from_params(&json!({"name": ""})).is_err());
    let bad = json!({"name": "desktop-zoe", "token": "a\nb"});
    assert!(RegisterRequest::from_params(&bad).is_err());
    let ok = json!({"name": "desktop-zoe", "socket": "/tmp/cc-socks/1.sock", "token": "t"});
    let req = RegisterRequest::from_params(&ok).unwrap();
    assert_eq!(req.name, "desktop-zoe");
    assert_eq!(req.socket.as_deref(), Some(std::path::Path::new("/tmp/cc-socks/1.sock")));
    assert_eq!(req.token.as_deref(), Some("t"));
}
