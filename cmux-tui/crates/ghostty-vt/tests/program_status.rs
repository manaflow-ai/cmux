//! OSC 7501 program status through libghostty-vt (ghostty-next PR 29).

use std::sync::{Arc, Mutex};

use ghostty_vt::{
    Callbacks, ProgramStatusEvent, ProgramStatusKind, ProgramStatusReport, ProgramStatusState,
    Terminal,
};

struct Harness {
    term: Terminal,
    events: Arc<Mutex<Vec<ProgramStatusEvent>>>,
    written: Arc<Mutex<Vec<u8>>>,
}

impl Harness {
    fn new(with_program_status: bool) -> Self {
        let events = Arc::new(Mutex::new(Vec::new()));
        let written = Arc::new(Mutex::new(Vec::new()));
        let callbacks = Callbacks {
            on_pty_write: Some(Box::new({
                let written = written.clone();
                move |bytes: &[u8]| written.lock().unwrap().extend_from_slice(bytes)
            })),
            on_program_status: with_program_status.then(|| {
                let events = events.clone();
                Box::new(move |event| events.lock().unwrap().push(event))
                    as ghostty_vt::ProgramStatusFn
            }),
            ..Callbacks::default()
        };
        Self { term: Terminal::new(40, 5, 10_000, callbacks).unwrap(), events, written }
    }

    fn take_events(&self) -> Vec<ProgramStatusEvent> {
        std::mem::take(&mut *self.events.lock().unwrap())
    }

    fn take_written(&self) -> Vec<u8> {
        std::mem::take(&mut *self.written.lock().unwrap())
    }
}

fn report(state: ProgramStatusState) -> ProgramStatusReport {
    ProgramStatusReport {
        state,
        kind: None,
        progress: None,
        id: String::new(),
        app: String::new(),
        title: String::new(),
        message: String::new(),
    }
}

/// The shell example from the decision: a working report with progress.
#[test]
fn working_report_with_progress_reaches_the_owner() {
    let mut harness = Harness::new(true);
    harness.term.vt_write(b"\x1b]7501;state=working:progress=40\x1b\\");
    assert_eq!(
        harness.take_events(),
        vec![ProgramStatusEvent::Report(ProgramStatusReport {
            progress: Some(40),
            ..report(ProgramStatusState::Working)
        })]
    );
    assert!(harness.take_written().is_empty(), "a report is never echoed to the program");
}

#[test]
fn blocked_report_decodes_every_field() {
    let mut harness = Harness::new(true);
    // "Plan" and "Apply?"
    harness.term.vt_write(
        b"\x1b]7501;state=blocked:kind=permission:progress=40:id=a/b:app=terraform:title=UGxhbg==:msg=QXBwbHk/\x07",
    );
    assert_eq!(
        harness.take_events(),
        vec![ProgramStatusEvent::Report(ProgramStatusReport {
            state: ProgramStatusState::Blocked,
            kind: Some(ProgramStatusKind::Permission),
            progress: Some(40),
            id: "a/b".into(),
            app: "terraform".into(),
            title: "Plan".into(),
            message: "Apply?".into(),
        })]
    );
}

#[test]
fn support_query_is_answered_only_with_an_owner() {
    let mut without = Harness::new(false);
    without.term.vt_write(b"\x1b]7501;?\x1b\\\x1b]7501;state=idle\x1b\\");
    assert!(without.take_written().is_empty());
    assert!(without.take_events().is_empty());

    let mut with = Harness::new(true);
    with.term.vt_write(b"\x1b]7501;?\x1b\\");
    assert_eq!(with.take_written(), b"\x1b]7501;?\x1b\\");
    assert!(with.take_events().is_empty());
}

/// Reports and prompt starts arrive in stream order, so a report sent before
/// a prompt is removed by it and one sent after is kept.
#[test]
fn prompt_start_and_reset_arrive_in_stream_order() {
    let mut harness = Harness::new(true);
    harness
        .term
        .vt_write(b"\x1b]7501;state=working\x1b\\\x1b]133;A\x07$ \x1b]7501;state=done\x1b\\\x1bc");
    assert_eq!(
        harness.take_events(),
        vec![
            ProgramStatusEvent::Report(report(ProgramStatusState::Working)),
            ProgramStatusEvent::PromptStart,
            ProgramStatusEvent::Report(report(ProgramStatusState::Done)),
            ProgramStatusEvent::Report(report(ProgramStatusState::Clear)),
        ]
    );
}

#[test]
fn invalid_reports_are_dropped_by_the_parser() {
    let mut harness = Harness::new(true);
    // No state, an unknown state, text that is not base64, and text that
    // decodes to a control character ("a\nb").
    harness.term.vt_write(b"\x1b]7501;progress=4\x1b\\");
    harness.term.vt_write(b"\x1b]7501;state=sleeping\x1b\\");
    harness.term.vt_write(b"\x1b]7501;state=done:msg=a\x1b\\");
    harness.term.vt_write(b"\x1b]7501;state=done:msg=YQpi\x1b\\");
    assert!(harness.take_events().is_empty());
}
