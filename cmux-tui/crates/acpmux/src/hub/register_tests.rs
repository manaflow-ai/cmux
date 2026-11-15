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
