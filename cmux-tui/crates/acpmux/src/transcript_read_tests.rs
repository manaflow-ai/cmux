use serde_json::json;

use super::*;

#[test]
fn params_read_the_wire_and_need_a_session_and_a_place() {
    let p = Params::from_value(&json!({
        "sessionId": "coord", "line": 12, "before": 99, "after": 1, "tools": false,
        "maxBytes": 10_000_000, "subagent": "agent-a1", "host": "hb",
    }))
    .unwrap();
    assert_eq!(Params::from_value(&p.to_value()).unwrap(), p);
    let q = p.query("s1");
    assert_eq!(q.session, "s1");
    assert_eq!(q.at, tr::At::Line(12));
    assert_eq!((q.before, q.after, q.tools), (tr::MAX_AROUND, 1, false));
    assert_eq!(q.max_bytes, tr::MAX_BYTES);
    assert_eq!(q.subagent.as_deref(), Some("agent-a1"));

    // A line reads two messages each side by default; a turn only itself.
    let line = Params::from_value(&json!({"harnessSessionId": "s1", "line": 3})).unwrap();
    let q = line.query("s1");
    assert_eq!((q.before, q.after, q.tools, q.max_bytes), (2, 2, true, tr::DEFAULT_MAX_BYTES));
    let turn = Params::from_value(&json!({"harnessSessionId": "s1", "turn": 0})).unwrap();
    let q = turn.query("s1");
    assert_eq!((q.at, q.before, q.after), (tr::At::Turn(0), 0, 0));

    for bad in [
        json!({"line": 1}),
        json!({"sessionId": "s1"}),
        json!({"sessionId": "s1", "line": 1, "turn": 1}),
        json!({"sessionId": "s1", "line": 0}),
        json!({"sessionId": "s1", "line": 1, "host": "all"}),
    ] {
        assert!(Params::from_value(&bad).is_err(), "{bad}");
    }
}

#[test]
fn text_marks_the_messages_asked_for_and_says_what_was_left_out() {
    let answer = json!({
        "host": "cosmic-gray", "sessionId": "s1", "harness": "claude", "file": "s1",
        "subagent": false, "lines": 900, "turns": 40,
        "files": [{"file": "s1", "subagent": false}, {"file": "agent-a1", "subagent": true}],
        "messages": [
            {"line": 11, "turn": 4, "at": null, "role": "user", "text": "Find it.\nPlease.", "anchor": false},
            {"line": 12, "turn": 4, "at": null, "role": "assistant", "text": "Found \"it\".", "anchor": true, "capped": true},
        ],
        "moreBefore": true, "moreAfter": true, "truncated": false, "bytes": 25, "tookMs": 1,
    });
    assert_eq!(
        text(&answer),
        "cosmic-gray/s1  claude  900 lines, 40 turns\n    (earlier messages not shown)\n\n  line 11  turn 4  -  user\n    Find it.\n    Please.\n\n> line 12  turn 4  -  assistant  (the index keeps only its start)\n    Found \"it\".\n\n(later messages not shown)\n(subagent transcripts: agent-a1)\n"
    );
}

#[test]
fn a_read_here_catches_the_session_up_and_answers_the_wire_shape() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("projects/p/s-read-1.jsonl");
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    let lines = [
        json!({"type": "user", "timestamp": "2026-11-18T09:00:00Z", "message": {"content": "where is merge_hold"}}),
        json!({"type": "assistant", "timestamp": "2026-11-18T09:00:01Z",
            "message": {"content": [{"type": "text", "text": "In \"hub/land.rs\".\nLine 40."}]}}),
    ];
    let body: String = lines.iter().map(|l| format!("{l}\n")).collect();
    std::fs::write(&path, body).unwrap();
    let mut roots = ts::Roots::default();
    roots.add_claude(dir.path().join("projects"));

    let at = dir.path().join("index.sqlite");
    let index = ts::Index::open(&at).unwrap();
    let reader = tr::Reader::open(&at).unwrap();
    let read = |p: &Params, session: &str, host: Option<&str>| {
        catch_up(&index, session, &roots)?;
        read_with(&reader, p, session, host, Instant::now())
    };
    let p = Params::from_value(&json!({"harnessSessionId": "s-read-1", "line": 2})).unwrap();
    let v = read(&p, "s-read-1", Some("here")).unwrap();
    assert_eq!(v["host"], "here");
    assert_eq!(v["sessionId"], "s-read-1");
    assert_eq!(v["harness"], "claude");
    assert_eq!(v["lines"], 2);
    let messages = v["messages"].as_array().unwrap();
    assert_eq!(messages.len(), 2);
    assert_eq!(messages[1]["text"], "In \"hub/land.rs\".\nLine 40.");
    assert_eq!(messages[1]["anchor"], true);
    assert_eq!(messages[0]["role"], "user");
    assert_eq!(v["moreBefore"], false);

    let past = Params::from_value(&json!({"harnessSessionId": "s-read-1", "line": 3})).unwrap();
    assert!(matches!(read(&past, "s-read-1", None), Err(Error::NotFound(_))));
    assert!(matches!(read(&p, "s-none", None), Err(Error::NotFound(_))));
}
