use super::*;
use crate::write_journal::browse::{Hit, ListEntry};

#[test]
fn parse_checks_op_machine_and_absolute_paths() {
    assert_eq!(
        parse(&json!({"op": "list", "machine": "vm", "path": "/w"})).unwrap(),
        Ask::List { machine: "vm".into(), path: "/w".into() }
    );
    assert_eq!(
        parse(
            &json!({"op": "search", "machine": "vm", "root": "/w", "query": "fn", "maxHits": 99999})
        )
        .unwrap(),
        Ask::Search {
            machine: "vm".into(),
            root: "/w".into(),
            query: "fn".into(),
            max_hits: MAX_HITS
        }
    );
    for bad in [
        json!({"op": "list", "path": "/w"}),
        json!({"op": "list", "machine": "vm", "path": "w"}),
        json!({"op": "search", "machine": "vm", "root": "/w"}),
        json!({"op": "read", "machine": "vm", "path": "w"}),
        json!({"op": "diff", "machine": "vm"}),
        json!({"op": "chmod", "machine": "vm", "path": "/w"}),
    ] {
        assert!(parse(&bad).is_err(), "{bad}");
    }
}

#[test]
fn replies_say_whether_they_answered() {
    assert_eq!(list_reply(Routed::NotPaused), json!({"answered": false, "reason": "notPaused"}));
    assert_eq!(list_reply(Routed::NeedsMachine(NeedsMachine::Stale))["reason"], json!("stale"));
    assert_eq!(
        list_reply(Routed::Answered(ListOutcome::NeedsMachine(NeedsMachine::MachineOnly)))["reason"],
        json!("machineOnly")
    );
    assert_eq!(
        list_reply(Routed::Answered(ListOutcome::Entries(vec![ListEntry {
            name: "a.rs".into(),
            is_dir: false,
            size: 3
        }]))),
        json!({"answered": true, "found": true, "entries": [{"name": "a.rs", "isDir": false, "size": 3}]})
    );
    assert_eq!(
        search_reply(Routed::Answered(SearchOutcome::Hits {
            hits: vec![Hit { path: "a.rs".into(), line: 2, text: "fn x".into() }],
            truncated: false
        })),
        json!({"answered": true, "truncated": false, "hits": [{"path": "a.rs", "line": 2, "text": "fn x"}]})
    );
}

/// Old and new on the wire: a new client of an old daemon finds no `paused-reads-v1` and
/// never sends the method (it wakes the machine, as before); a new daemon lists it, and an old
/// client that does not know the id ignores it, since ids are opaque strings.
#[test]
fn paused_reads_id_is_listed_by_a_new_daemon_and_absent_from_an_old_one() {
    let new_ids = crate::capabilities::ids();
    assert!(new_ids.contains(&crate::capabilities::PAUSED_READS));
    let old_ids: Vec<&str> =
        new_ids.iter().copied().filter(|id| *id != crate::capabilities::PAUSED_READS).collect();
    let client_sends = |ids: &[&str]| ids.contains(&crate::capabilities::PAUSED_READS);
    assert!(client_sends(&new_ids));
    assert!(!client_sends(&old_ids));
    #[cfg(feature = "hub-carrier")]
    assert_eq!(
        crate::capabilities::PAUSED_READS,
        serde_json::to_value(cmux_remote_protocol::RemoteCapability::PausedReadsV1)
            .unwrap()
            .as_str()
            .unwrap(),
        "acpmux and the cmux protocol name the surface the same"
    );
}

#[test]
fn parse_takes_read_and_diff() {
    assert_eq!(
        parse(&json!({"op": "read", "machine": "vm", "path": "/w/a.rs"})).unwrap(),
        Ask::Read { machine: "vm".into(), path: "/w/a.rs".into() }
    );
    assert_eq!(
        parse(&json!({"op": "diff", "machine": "vm", "root": "/w"})).unwrap(),
        Ask::Diff { machine: "vm".into(), root: "/w".into() }
    );
}

#[test]
fn read_and_diff_replies_say_whether_they_answered() {
    assert_eq!(read_reply(Routed::NotPaused)["reason"], json!("notPaused"));
    assert_eq!(
        read_reply(Routed::Answered(ReadOutcome::Text("hi".into()))),
        json!({"answered": true, "found": true, "text": "hi"})
    );
    assert_eq!(
        read_reply(Routed::Answered(ReadOutcome::NotFound)),
        json!({"answered": true, "found": false})
    );
    assert_eq!(read_reply(Routed::NeedsMachine(NeedsMachine::NotText))["reason"], json!("notText"));
    let captured = diff_reply(Routed::Answered(DiffOutcome::Diff {
        at_pause: PauseDiff::Captured {
            text: "--- a/x\n".into(),
            untracked: vec!["n.txt".into()],
            untracked_truncated: false,
        },
        since_pause: String::new(),
        changed: vec![],
        truncated: false,
    }));
    assert_eq!(captured["answered"], json!(true));
    assert_eq!(captured["atPause"], json!("--- a/x\n"));
    assert_eq!(captured["untrackedAtPause"], json!(["n.txt"]));
    let missing = diff_reply(Routed::Answered(DiffOutcome::Diff {
        at_pause: PauseDiff::Missing("notGit"),
        since_pause: "p".into(),
        changed: vec!["a".into()],
        truncated: false,
    }));
    assert_eq!(missing["atPauseMissing"], json!("notGit"));
    assert!(missing.get("atPause").is_none());
    assert_eq!(missing["changedSincePause"], json!(["a"]));
    assert_eq!(
        diff_reply(Routed::Answered(DiffOutcome::NeedsMachine(NeedsMachine::Stale)))["reason"],
        json!("stale")
    );
}
