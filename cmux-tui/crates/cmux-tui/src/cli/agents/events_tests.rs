//! A wait (`--until` / `--match`) on `agents events` against its answer
//! buffer, without a daemon: what fills it and what does not.

use std::time::Instant;

use serde_json::json;

use super::{Cursor, Poll, parse};

#[test]
fn a_reset_does_not_fill_a_wait_before_its_match() {
    let request = match parse(&["--until", "agent.state", "--limit", "1", "--timeout", "5s"]) {
        Ok(request) => request,
        Err(error) => panic!("{error:?}"),
    };
    let mut poll = Poll::new(&request, Instant::now());
    // An expired cursor's reset comes first and is kept.
    assert!(poll.push("reset", None, json!({"source": "daemon", "reason": "cursor_invalid"})));
    assert!(!poll.full(), "a reset filled the wait");
    // A change that does not match is passed over, not answered.
    assert!(poll.push("workspace", None, json!({"change": "changed", "name": "w"})));
    assert!(!poll.full());
    // The match still fits, and ends the wait.
    assert!(poll.push("agent", None, json!({"change": "state", "state": "idle"})));
    assert!(poll.full());
    let kinds: Vec<_> = poll.events.iter().map(|event| event["kind"].clone()).collect();
    assert_eq!(kinds, [json!("reset"), json!("agent")]);
}

#[test]
fn a_plain_poll_still_fills_at_its_limit() {
    let request = match parse(&["--limit", "1", "--timeout", "5"]) {
        Ok(request) => request,
        Err(error) => panic!("{error:?}"),
    };
    let mut poll = Poll::new(&request, Instant::now());
    assert!(poll.push("reset", None, json!({"source": "daemon", "reason": "cursor_invalid"})));
    assert!(poll.full());
    assert!(!poll.push("agent", None, json!({"change": "state", "state": "idle"})));
}

fn workspace_delta(
    previous: u64,
    revision: u64,
    live: Option<&str>,
    ids: &[&str],
) -> serde_json::Value {
    let mut cursor = json!({"generation": "gen", "revision": revision.to_string()});
    if let Some(live) = live {
        cursor["live"] = json!(live);
    }
    let changes: Vec<_> = ids
        .iter()
        .map(|id| json!({"kind": "upsert", "resource": "workspace", "id": id, "value": {"name": id}}))
        .collect();
    json!({
        "kind": "delta",
        "cursor": cursor,
        "previous_revision": previous.to_string(),
        "revision": revision.to_string(),
        "changes": changes,
    })
}

/// One half of the compatibility pair: this CLI against a daemon with no
/// live position in its cursors (a build before `session-live-cursor-v1`,
/// which ignores the capability). The cursor it sends back has the two
/// fields that daemon knows and no `live`; that daemon refuses an unknown
/// cursor field.
#[test]
fn a_daemon_with_no_live_position_gets_its_two_field_cursor_back() {
    let request = match parse(&["--limit", "10", "--timeout", "5"]) {
        Ok(request) => request,
        Err(error) => panic!("{error:?}"),
    };
    let mut poll = Poll::new(&request, Instant::now());
    let snapshot = json!({
        "kind": "snapshot",
        "reset_reason": "initial",
        "cursor": {"generation": "gen", "revision": "4"},
        "snapshot": {},
    });
    assert!(poll.item(&snapshot));
    assert!(poll.item(&workspace_delta(4, 5, None, &["workspace_a"])));
    assert_eq!(poll.cursor.daemon_param(), Some(json!({"generation": "gen", "revision": "5"})));
    let Some(again) = Cursor::decode(&poll.cursor.encode()) else { panic!("the cursor decodes") };
    assert_eq!(again.daemon_param(), Some(json!({"generation": "gen", "revision": "5"})));

    // A cursor a build before the live position gave still resumes.
    let old = Cursor { seq: 3, ..Cursor::default() }.encode();
    assert!(Cursor::decode(&old).is_some());
    let text = format!(
        "evc1_{}",
        base64::Engine::encode(
            &base64::engine::general_purpose::URL_SAFE_NO_PAD,
            br#"{"s":3,"d":{"g":"gen","r":4,"k":1}}"#
        )
    );
    let Some(old) = Cursor::decode(&text) else { panic!("an older cursor decodes") };
    assert_eq!(old.daemon_param(), Some(json!({"generation": "gen", "revision": "4"})));
}

/// The daemon's live position goes back to it as it came, through the
/// opaque cursor of `agents events`, so the next call gets only the
/// terminals whose live facts changed after this one.
#[test]
fn the_live_position_of_the_daemon_cursor_goes_back_whole() {
    let request = match parse(&["--limit", "2", "--timeout", "5"]) {
        Ok(request) => request,
        Err(error) => panic!("{error:?}"),
    };
    let mut poll = Poll::new(&request, Instant::now());
    let snapshot = json!({
        "kind": "snapshot",
        "reset_reason": "initial",
        "cursor": {"generation": "gen", "revision": "4", "live": "epoch.7"},
        "snapshot": {},
    });
    assert!(poll.item(&snapshot));
    let whole = |live: &str, revision: &str| {
        Some(json!({"generation": "gen", "revision": revision, "live": live}))
    };
    assert_eq!(poll.cursor.daemon_param(), whole("epoch.7", "4"));
    // A live item moves no revision; its cursor has the newer position.
    assert!(poll.item(&workspace_delta(4, 4, Some("epoch.9"), &[])));
    assert_eq!(poll.cursor.daemon_param(), whole("epoch.9", "4"));
    let Some(again) = Cursor::decode(&poll.cursor.encode()) else { panic!("the cursor decodes") };
    assert_eq!(again.daemon_param(), whole("epoch.9", "4"));

    // An answer that fills in the middle of a batch points before the
    // batch, with the live position before it too: the daemon sends the
    // batch again, and the live items after the older position.
    let batch =
        workspace_delta(4, 5, Some("epoch.12"), &["workspace_a", "workspace_b", "workspace_c"]);
    assert!(!poll.item(&batch), "the answer is full at its limit of 2");
    assert_eq!(poll.cursor.daemon_param(), whole("epoch.9", "4"));
    let Some(daemon) = poll.cursor.daemon.as_ref() else { panic!("a daemon cursor") };
    assert_eq!(daemon.skip, 2);
}
