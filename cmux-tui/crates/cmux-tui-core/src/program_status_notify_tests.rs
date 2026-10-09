use std::time::{Duration, Instant};

use ghostty_vt::{ProgramStatusEvent, ProgramStatusKind, ProgramStatusReport, ProgramStatusState};

use crate::mux::{Mux, MuxEvent, NotificationLevel, NotificationSource};
use crate::program_status::ProgramStatusRecords;
use crate::surface::SurfaceOptions;

fn report(
    id: &str,
    state: ProgramStatusState,
    kind: Option<ProgramStatusKind>,
    message: &str,
) -> ProgramStatusEvent {
    ProgramStatusEvent::Report(ProgramStatusReport {
        state,
        kind,
        progress: None,
        id: id.into(),
        app: "claude".into(),
        title: "Deploy".into(),
        message: message.into(),
    })
}

fn notices(
    records: &mut ProgramStatusRecords,
) -> Vec<(String, ProgramStatusState, Option<ProgramStatusKind>, Option<String>)> {
    records
        .take_notices()
        .into_iter()
        .map(|notice| (notice.id, notice.state, notice.kind, notice.message))
        .collect()
}

#[test]
fn blocked_error_and_done_each_notify_once_per_change() {
    let mut records = ProgramStatusRecords::default();
    records.apply(report("", ProgramStatusState::Working, None, ""), 1);
    assert!(notices(&mut records).is_empty(), "working never notifies");
    records.apply(
        report("", ProgramStatusState::Blocked, Some(ProgramStatusKind::Permission), "Run rm?"),
        2,
    );
    assert_eq!(
        notices(&mut records),
        vec![(
            "".into(),
            ProgramStatusState::Blocked,
            Some(ProgramStatusKind::Permission),
            Some("Run rm?".into())
        )]
    );
    // The same report again (a replay, a program that re-sends it): nothing.
    records.apply(
        report("", ProgramStatusState::Blocked, Some(ProgramStatusKind::Permission), "Run rm?"),
        3,
    );
    assert!(notices(&mut records).is_empty());
    // A new question while still blocked is a new thing to answer.
    records.apply(
        report("", ProgramStatusState::Blocked, Some(ProgramStatusKind::Question), "Which env?"),
        4,
    );
    assert_eq!(notices(&mut records).len(), 1);
    records.apply(report("", ProgramStatusState::Error, None, "exit 1"), 5);
    records.apply(report("child", ProgramStatusState::Done, None, ""), 6);
    let posted = notices(&mut records);
    assert_eq!(posted.len(), 2, "{posted:?}");
    assert_eq!(posted[0].1, ProgramStatusState::Error);
    assert_eq!((posted[1].0.as_str(), posted[1].1), ("child", ProgramStatusState::Done));
    records.apply(report("", ProgramStatusState::Idle, None, ""), 7);
    assert!(notices(&mut records).is_empty(), "idle never notifies");
}

#[test]
fn pending_notices_stay_bounded() {
    let mut records = ProgramStatusRecords::default();
    for index in 0..100 {
        records.apply(report(&index.to_string(), ProgramStatusState::Done, None, ""), index);
    }
    assert!(records.take_notices().len() <= 16);
}

#[test]
fn an_unattached_terminal_posts_osc_7501_notifications_to_the_ledger() {
    let mux = Mux::new(
        "program-status-notify-test",
        SurfaceOptions {
            command: Some(vec![
                "/bin/sh".to_string(),
                "-c".to_string(),
                "printf '\\033]7501;state=working\\033\\\\'; \
                 printf '\\033]7501;state=blocked:kind=permission:app=claude:title=RGVwbG95:msg=UnVuIHJtPw==\\033\\\\'; \
                 printf '\\033]7501;state=blocked:kind=permission:app=claude:title=RGVwbG95:msg=UnVuIHJtPw==\\033\\\\'; \
                 printf '\\033]7501;state=error:app=claude:title=RGVwbG95:msg=ZXhpdCAx\\033\\\\'; exec cat"
                    .to_string(),
            ]),
            ..SurfaceOptions::default()
        },
    );
    let events = mux.subscribe();
    let surface = mux.new_workspace(None, Some((20, 4))).unwrap();
    let deadline = Instant::now() + Duration::from_secs(20);
    let mut notes = Vec::new();
    while notes.len() < 2 {
        let remaining = deadline.saturating_duration_since(Instant::now());
        assert!(!remaining.is_zero(), "program status notifications missing: {notes:?}");
        if let Ok(MuxEvent::Notification(note)) = events.recv_timeout(remaining) {
            notes.push(note);
        }
    }
    // Nothing more: the repeated blocked report posted no second notification.
    std::thread::sleep(Duration::from_millis(500));
    while let Ok(event) = events.try_recv() {
        if let MuxEvent::Notification(note) = event {
            notes.push(note);
        }
    }
    let summary = notes
        .iter()
        .map(|note| {
            (note.title.as_str(), note.body.as_str(), note.level, note.source, note.surface)
        })
        .collect::<Vec<_>>();
    assert_eq!(
        summary,
        vec![
            (
                "Deploy",
                "Run rm?",
                NotificationLevel::Warning,
                NotificationSource::Terminal,
                Some(surface.id)
            ),
            (
                "Deploy",
                "exit 1",
                NotificationLevel::Error,
                NotificationSource::Terminal,
                Some(surface.id)
            ),
        ]
    );
    mux.shutdown();
}
