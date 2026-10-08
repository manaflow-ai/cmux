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
fn each_visible_change_stays_pending_until_published() {
    let mut records = ProgramStatusRecords::default();
    assert!(records.pending_change().is_none());
    records.apply(report("", ProgramStatusState::Working), 0);
    let revision = records.pending_change().unwrap().0;
    assert!(records.pending_change().is_some(), "a failed resource commit must be retryable");
    records.mark_change_published(revision);
    assert!(records.pending_change().is_none());
    // Nothing to end and nothing to clear: no change.
    records.apply(report("missing", ProgramStatusState::Clear), 0);
    records.apply(report("", ProgramStatusState::Done), 0);
    let revision = records.pending_change().unwrap().0;
    records.mark_change_published(revision);
    records.apply(ProgramStatusEvent::PromptStart, 0);
    assert!(records.pending_change().is_none());
}
