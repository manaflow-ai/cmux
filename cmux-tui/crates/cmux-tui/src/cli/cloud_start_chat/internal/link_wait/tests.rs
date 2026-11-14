use super::*;
use std::os::unix::net::UnixListener;

/// A daemon on a socket that answers `identify` and `agent-session-attach` (the page), then pushes `pushed`.
fn daemon(
    capabilities: &[&str],
    page: Value,
    pushed: Vec<Value>,
) -> (tempfile::TempDir, std::path::PathBuf) {
    serve(capabilities, page, json!({"events": [], "hasMore": false}), pushed)
}

/// A daemon whose attach page has more and whose every `agent-session-events` page is `events`.
fn daemon_paging(events: Value) -> (tempfile::TempDir, std::path::PathBuf) {
    serve(&[ATTACH], json!({"events": [], "hasMore": true}), events, vec![])
}

fn serve(
    capabilities: &[&str],
    page: Value,
    events: Value,
    pushed: Vec<Value>,
) -> (tempfile::TempDir, std::path::PathBuf) {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("link.sock");
    let listener = UnixListener::bind(&path).unwrap();
    let capabilities: Vec<String> = capabilities.iter().map(|name| (*name).to_owned()).collect();
    std::thread::spawn(move || {
        let (stream, _) = listener.accept().unwrap();
        let mut writer = stream.try_clone().unwrap();
        let mut lines = BufReader::new(stream);
        let mut line = String::new();
        while lines.read_line(&mut line).unwrap_or(0) > 0 {
            let request: Value = serde_json::from_str(line.trim()).unwrap();
            line.clear();
            let id = request["id"].clone();
            let data = match request["cmd"].as_str() {
                Some("identify") => json!({"capabilities": capabilities}),
                Some("agent-session-attach") => page.clone(),
                Some("agent-session-events") => events.clone(),
                _ => json!({}),
            };
            writeln!(writer, "{}", json!({"id": id, "ok": true, "data": data})).unwrap();
            if request["cmd"] == "agent-session-attach" {
                for push in &pushed {
                    writeln!(writer, "{push}").unwrap();
                }
            }
        }
    });
    (dir, path)
}

#[test]
fn the_turn_ends_at_its_turn_end_with_every_record_after_the_seq() {
    let record =
        |seq: u64, dir: &str, kind: &str| json!({"seq": seq, "dir": dir, "kind": kind, "msg": {}});
    let page = json!({"events": [record(1, "mux", "user_message"), record(2, "in", "notification")], "hasMore": false});
    let pushed = vec![
        json!({"event": "agent-session-record", "surface": 7, "record": record(2, "in", "notification")}),
        json!({"event": "agent-session-record", "surface": 7, "record": record(3, "mux", "turn_end")}),
        json!({"event": "agent-session-record", "surface": 7, "record": record(4, "mux", "user_message")}),
    ];
    let (_dir, path) = daemon(&[ATTACH], page, pushed);
    let answer = observe(&path, 7, 0, Duration::from_secs(5)).unwrap();
    assert_eq!(answer["ended"], "turn_end");
    assert_eq!(answer["last_seq"], 3);
    let seqs: Vec<u64> =
        answer["records"].as_array().unwrap().iter().map(|r| r["seq"].as_u64().unwrap()).collect();
    assert_eq!(seqs, [1, 2, 3], "each record once, none after the turn's end");
}

#[test]
fn a_permission_ends_the_wait_and_a_quiet_link_times_out() {
    let (_dir, path) = daemon(
        &[ATTACH],
        json!({"events": [], "hasMore": false}),
        vec![json!({"event": "agent-session-permission", "surface": 7, "request": {}})],
    );
    assert_eq!(observe(&path, 7, 0, Duration::from_secs(5)).unwrap()["ended"], "permission");
    let (_dir, path) = daemon(&[ATTACH], json!({"events": [], "hasMore": false}), vec![]);
    assert_eq!(observe(&path, 7, 0, Duration::from_millis(200)).unwrap()["ended"], "timeout");
}

#[test]
fn a_failed_turn_ends_the_wait_without_a_turn_end() {
    let record = |seq: u64, kind: &str, msg: Value| json!({"seq": seq, "dir": "mux", "kind": kind, "msg": msg});
    let page = json!({"events": [record(1, "user_message", json!({}))], "hasMore": false});
    let pushed = vec![json!({"event": "agent-session-record", "surface": 7,
                                 "record": record(2, "turn_error", json!({"error": "agent process closed"}))})];
    let (_dir, path) = daemon(&[ATTACH], page, pushed);
    let answer = observe(&path, 7, 0, Duration::from_secs(5)).unwrap();
    assert_eq!(
        (answer["ended"].as_str(), answer["last_seq"].as_u64()),
        (Some("turn_end"), Some(2))
    );
    let failed = record(3, "turn_result", json!({"status": "failed", "error": "e"}));
    assert_eq!(turn_ended(&failed), Some(Some(&json!({"status": "failed", "error": "e"}))));
    assert_eq!(turn_ended(&record(3, "turn_result", json!({"status": "completed"}))), None);
}

#[test]
fn pages_follow_the_attach_and_pushes_during_them_are_kept() {
    let record = |seq: u64, kind: &str| json!({"seq": seq, "dir": "mux", "kind": kind, "msg": {}});
    // The attach answers one page with more; the fake's events answer is empty with no more, then the pushes.
    let page = json!({"events": [record(1, "user_message")], "hasMore": true});
    let pushed = vec![
        json!({"event": "agent-session-record", "surface": 7, "record": record(2, "turn_end")}),
    ];
    let (_dir, path) = daemon(&[ATTACH], page, pushed);
    let answer = observe(&path, 7, 0, Duration::from_secs(5)).unwrap();
    assert_eq!(
        answer["ended"], "turn_end",
        "the push that came while the page was asked ends the wait"
    );
    assert_eq!(answer["last_seq"], 2);
}

#[test]
fn a_permission_pending_at_the_attach_ends_the_wait() {
    let page =
        json!({"session": {"pending": [{"permissionId": "p1"}]}, "events": [], "hasMore": false});
    let (_dir, path) = daemon(&[ATTACH], page, vec![]);
    assert_eq!(observe(&path, 7, 0, Duration::from_secs(5)).unwrap()["ended"], "permission");
    let page = json!({"session": {"pending": []}, "events": [], "hasMore": false});
    let (_dir, path) = daemon(&[ATTACH], page, vec![]);
    assert_eq!(observe(&path, 7, 0, Duration::from_millis(200)).unwrap()["ended"], "timeout");
}

#[test]
fn a_replay_page_that_cannot_advance_hands_the_turn_to_exec() {
    // The attach page has more; the fake's events answer reads nothing, again with more.
    let (_dir, path) = daemon_paging(json!({"events": [], "hasMore": true}));
    assert!(matches!(observe(&path, 7, 0, Duration::from_secs(5)), Err(Failure::Link(_))));
}

#[test]
fn a_daemon_without_attach_is_refused_before_any_attach() {
    let (_dir, path) = daemon(&["workspace-registry-v1"], json!({}), vec![]);
    assert!(observe(&path, 7, 0, Duration::from_secs(5)).is_err());
    assert!(observe(Path::new("/nonexistent/link.sock"), 7, 0, Duration::from_secs(1)).is_err());
}
