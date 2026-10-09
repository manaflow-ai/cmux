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

/// A record that starts waiting on the user (`blocked`, worded by `kind`),
/// fails (`error`) or finishes (`done`, cx-kxa2) posts one terminal
/// notification on the record's terminal: the record's title, else its
/// (inherited) app, names the program; the body is the record's message. A
/// report that keeps the state and kind (a progress update, a new message)
/// posts nothing new; `working`, `idle` and `clear` post nothing. The client
/// shows a `done` only for a terminal the user cannot see. A real PTY: the test runtime's
/// placeholder surfaces never run their command.
#[cfg(unix)]
#[test]
fn blocked_error_and_done_records_post_one_terminal_notification_each() {
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
            ("deploy is done".to_owned(), String::new(), NotificationLevel::Info),
            ("end".to_owned(), String::new(), NotificationLevel::Info),
        ]
    );
    mux.shutdown();
}
