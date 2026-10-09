use super::*;

fn report(id: &str, state: ProgramStatusState) -> ProgramStatusEvent {
    ProgramStatusEvent::Report(ProgramStatusReport {
        state,
        kind: None,
        progress: None,
        id: id.into(),
        app: String::new(),
        title: String::new(),
        message: String::new(),
    })
}

fn ids(records: &ProgramStatusRecords) -> Vec<String> {
    records
        .to_json(true)
        .map(|value| {
            value
                .as_array()
                .unwrap()
                .iter()
                .map(|record| record["id"].as_str().unwrap().to_owned())
                .collect()
        })
        .unwrap_or_default()
}

#[test]
fn a_report_replaces_its_record_completely() {
    let mut records = ProgramStatusRecords::default();
    records.apply(
        ProgramStatusEvent::Report(ProgramStatusReport {
            state: ProgramStatusState::Blocked,
            kind: Some(ProgramStatusKind::Permission),
            progress: Some(40),
            id: String::new(),
            app: "terraform".into(),
            title: "Plan".into(),
            message: "Apply?".into(),
        }),
        7,
    );
    let shown = records.to_json(true).unwrap();
    assert_eq!(
        shown,
        json!([{
            "id": "", "state": "blocked", "progress": 40, "kind": "permission",
            "app": "terraform", "title": "Plan", "msg": "Apply?",
            "updated_seq": "1", "updated_at_ms": "7",
        }])
    );
    records.apply(report("", ProgramStatusState::Done), 8);
    let record = records.get("").unwrap();
    assert_eq!(record.state, ProgramStatusState::Done);
    assert_eq!((record.kind, record.progress, record.app.as_deref()), (None, None, None));
    assert_eq!(record.updated_seq, 2);
}

#[test]
fn kind_and_progress_only_stay_on_the_states_that_carry_them() {
    let mut records = ProgramStatusRecords::default();
    records.apply(
        ProgramStatusEvent::Report(ProgramStatusReport {
            state: ProgramStatusState::Done,
            kind: Some(ProgramStatusKind::Auth),
            progress: Some(50),
            id: String::new(),
            app: String::new(),
            title: String::new(),
            message: String::new(),
        }),
        0,
    );
    let record = records.get("").unwrap();
    assert_eq!((record.kind, record.progress), (None, None));
}

#[test]
fn clear_removes_a_record_and_its_descendants_only() {
    let mut records = ProgramStatusRecords::default();
    for id in ["build", "build/test", "build/test/unit", "buildx", "deploy"] {
        records.apply(report(id, ProgramStatusState::Working), 0);
    }
    records.apply(report("build", ProgramStatusState::Clear), 0);
    assert_eq!(ids(&records), ["buildx", "deploy"]);
    records.apply(report("", ProgramStatusState::Clear), 0);
    assert!(records.is_empty());
}

#[test]
fn prompt_start_ends_working_blocked_and_idle_but_keeps_done_and_error() {
    let mut records = ProgramStatusRecords::default();
    records.apply(report("a", ProgramStatusState::Working), 0);
    records.apply(report("b", ProgramStatusState::Blocked), 0);
    records.apply(report("c", ProgramStatusState::Idle), 0);
    records.apply(report("d", ProgramStatusState::Done), 0);
    records.apply(report("e", ProgramStatusState::Error), 0);
    records.apply(ProgramStatusEvent::PromptStart, 0);
    assert_eq!(ids(&records), ["d", "e"]);
}

#[test]
fn an_exited_terminal_shows_only_done_and_error() {
    let mut records = ProgramStatusRecords::default();
    records.apply(report("a", ProgramStatusState::Working), 0);
    assert_eq!(records.to_json(false), None);
    records.apply(report("b", ProgramStatusState::Error), 0);
    let shown = records.to_json(false).unwrap();
    assert_eq!(shown.as_array().unwrap().len(), 1);
    assert_eq!(shown[0]["id"], "b");
}

#[test]
fn the_record_updated_longest_ago_goes_first_at_the_limit() {
    let mut records = ProgramStatusRecords::default();
    for index in 0..MAX_RECORDS {
        records.apply(report(&format!("r{index}"), ProgramStatusState::Working), 0);
    }
    // Refresh r0 so r1 is now the oldest.
    records.apply(report("r0", ProgramStatusState::Working), 0);
    records.apply(report("new", ProgramStatusState::Working), 0);
    assert_eq!(records.len(), MAX_RECORDS);
    assert!(records.get("r0").is_some());
    assert!(records.get("r1").is_none());
    assert!(records.get("new").is_some());
    // Replacing an existing record at the limit evicts nothing.
    records.apply(report("r2", ProgramStatusState::Done), 0);
    assert_eq!(records.len(), MAX_RECORDS);
}

#[test]
fn shown_text_drops_invisible_formatting_and_caps_length() {
    // A right-to-left override would reverse the rest of a notification.
    assert_eq!(shown_text("ok\u{202E}gnp.exe\u{200B}", 100), "okgnp.exe");
    assert_eq!(shown_text("a\u{2066}b\u{2069}c\u{FEFF}", 100), "abc");
    assert_eq!(shown_text("安全です", 2), "安全");
    let mut records = ProgramStatusRecords::default();
    records.apply(
        ProgramStatusEvent::Report(ProgramStatusReport {
            state: ProgramStatusState::Done,
            kind: None,
            progress: None,
            id: String::new(),
            app: String::new(),
            title: "\u{200B}".into(),
            message: "x".repeat(MAX_MESSAGE_CHARS + 10),
        }),
        0,
    );
    let record = records.get("").unwrap();
    assert_eq!(record.title, None, "text that is only invisible characters is absent");
    assert_eq!(record.message.as_ref().unwrap().chars().count(), MAX_MESSAGE_CHARS);
}

#[test]
fn each_visible_change_is_taken_once() {
    let mut records = ProgramStatusRecords::default();
    assert!(!records.take_change());
    records.apply(report("", ProgramStatusState::Working), 0);
    assert!(records.take_change());
    assert!(!records.take_change());
    // Nothing to end and nothing to clear: no change.
    records.apply(report("missing", ProgramStatusState::Clear), 0);
    records.apply(report("", ProgramStatusState::Done), 0);
    records.take_change();
    records.apply(ProgramStatusEvent::PromptStart, 0);
    assert!(!records.take_change());
}

fn report_with_app(id: &str, state: ProgramStatusState, app: &str) -> ProgramStatusEvent {
    ProgramStatusEvent::Report(ProgramStatusReport {
        state,
        kind: None,
        progress: None,
        id: id.into(),
        app: app.into(),
        title: String::new(),
        message: String::new(),
    })
}

fn shown_apps(records: &ProgramStatusRecords) -> Vec<(String, Value)> {
    records
        .to_json(true)
        .unwrap()
        .as_array()
        .unwrap()
        .iter()
        .map(|record| (record["id"].as_str().unwrap().to_owned(), record["app"].clone()))
        .collect()
}

/// The specification: "A record without app takes it from its nearest
/// ancestor that has one" (the deploy example's regions show app=deploy).
/// The parent does not have to exist, and a record's own app wins.
#[test]
fn a_record_without_app_takes_the_nearest_ancestors_app() {
    let mut records = ProgramStatusRecords::default();
    records.apply(report_with_app("", ProgramStatusState::Working, "deploy"), 0);
    records.apply(report("us-east", ProgramStatusState::Working), 0);
    records.apply(report_with_app("eu", ProgramStatusState::Working, "kubectl"), 0);
    records.apply(report("eu/west/pod", ProgramStatusState::Blocked), 0);
    records.apply(report_with_app("own", ProgramStatusState::Done, "make"), 0);
    assert_eq!(
        shown_apps(&records),
        vec![
            ("".to_owned(), json!("deploy")),
            ("eu".to_owned(), json!("kubectl")),
            ("eu/west/pod".to_owned(), json!("kubectl")),
            ("own".to_owned(), json!("make")),
            ("us-east".to_owned(), json!("deploy")),
        ]
    );

    // Without any ancestor app the record has none.
    let mut records = ProgramStatusRecords::default();
    records.apply(report("lonely/child", ProgramStatusState::Working), 0);
    assert_eq!(shown_apps(&records), vec![("lonely/child".to_owned(), Value::Null)]);
}

/// A record that starts waiting on the user (`blocked`, worded by `kind`) or
/// fails (`error`) posts one terminal notification on the record's terminal:
/// the record's title, else its (inherited) app, names the program; the body
/// is the record's message. A report that keeps the state and kind (a
/// progress update, a new message) posts nothing new; `working`, `done`,
/// `idle` and `clear` post nothing. A real PTY: the test runtime's
/// placeholder surfaces never run their command.
#[cfg(unix)]
#[test]
fn blocked_and_error_records_post_one_terminal_notification_each() {
    use crate::{Mux, MuxEvent, NotificationLevel, NotificationSource, SurfaceOptions};
    use std::time::{Duration, Instant};
    // Each step sleeps well past the terminal's notification spacing (1 s,
    // and 5 s for a repeat of the same text) so a missing notification is
    // the daemon's choice, not the rate limit's.
    let script = concat!(
        "s() { printf '\\033]7501;%s\\033\\\\' \"$1\"; sleep 2; }; ",
        // "Apply 3 to add, 1 to change, 0 to destroy?"
        "s 'state=blocked:kind=permission:app=terraform:msg=QXBwbHkgMyB0byBhZGQsIDEgdG8gY2hhbmdlLCAwIHRvIGRlc3Ryb3k/'; ",
        "sleep 5; ",
        // The same wait with progress and a new message: no new notification.
        "s 'state=blocked:kind=permission:app=terraform:msg=U3RpbGwgd2FpdGluZw:progress=50'; ",
        // Blocked and cleared in one chunk: the alert is withdrawn.
        "printf '\\033]7501;state=blocked:id=gone\\033\\\\\\033]7501;state=clear:id=gone\\033\\\\'; sleep 2; ",
        "s 'state=working:app=deploy'; ",
        "s 'state=blocked:kind=auth:id=eu-west'; ",
        "s 'state=error:id=build:title=QnVpbGQ=:msg=ZXhpdCAy'; ",
        "s 'state=done:app=deploy'; ",
        "s 'state=idle'; ",
        "s 'state=clear'; ",
        "printf '\\033]9;end\\007'; exec cat",
    );
    let mux = Mux::new(
        "program-status-notifications",
        SurfaceOptions {
            command: Some(vec!["/bin/sh".into(), "-c".into(), script.into()]),
            ..SurfaceOptions::default()
        },
    );
    let events = mux.subscribe();
    let surface = mux.new_workspace(None, Some((40, 6))).unwrap();
    let deadline = Instant::now() + Duration::from_secs(60);
    let mut notes = Vec::new();
    while notes.last().map(|(title, ..): &(String, String, NotificationLevel)| title.as_str())
        != Some("end")
    {
        let remaining = deadline.saturating_duration_since(Instant::now());
        assert!(!remaining.is_zero(), "notifications so far: {notes:?}");
        if let Ok(MuxEvent::Notification(note)) = events.recv_timeout(remaining) {
            assert_eq!(note.surface, Some(surface.id), "{note:?}");
            assert_eq!(note.source, NotificationSource::Terminal, "{note:?}");
            notes.push((note.title, note.body, note.level));
        }
    }
    assert_eq!(
        notes,
        vec![
            (
                "terraform needs approval".to_owned(),
                "Apply 3 to add, 1 to change, 0 to destroy?".to_owned(),
                NotificationLevel::Warning,
            ),
            ("deploy needs sign-in".to_owned(), String::new(), NotificationLevel::Warning),
            ("Build failed".to_owned(), "exit 2".to_owned(), NotificationLevel::Error),
            ("end".to_owned(), String::new(), NotificationLevel::Info),
        ]
    );
    mux.shutdown();
}
