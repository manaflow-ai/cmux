//! Reconnect checkpoint skips and per-mux diagnostic reporters.

use super::*;

/// A machine resume reconnects every hosted terminal at once. Checkpoint
/// capture can lose its consistency race while those reconnects append to
/// the journal, but the skipped optimization is recovered by replaying
/// from the previous boundary. It must stay out of the user-facing status
/// stream even when it repeats or a later successful checkpoint re-arms
/// diagnostic logging.
#[test]
fn reconnect_checkpoint_skip_does_not_emit_status() {
    let mux = test_mux();
    let diagnostics = Arc::new(Mutex::new(Vec::<String>::new()));
    let diagnostics_for_reporter = Arc::clone(&diagnostics);
    assert!(mux.set_diagnostic_reporter(Arc::new(move |message| {
        diagnostics_for_reporter.lock().unwrap().push(message.to_string());
    })));
    assert!(!mux.set_diagnostic_reporter(Arc::new(|_| {})));
    let events = mux.subscribe();
    let skip_statuses = |events: &MuxEventReceiver| {
        events
            .try_iter()
            .filter(|event| {
                matches!(event, MuxEvent::Status(message)
                        if message.contains("reconnect checkpoint"))
            })
            .count()
    };

    let error = anyhow::anyhow!("session changed during checkpoint capture");
    mux.report_skipped_reconnect_checkpoint("term_one", &error);
    mux.report_skipped_reconnect_checkpoint("term_two", &error);
    mux.report_skipped_reconnect_checkpoint("term_one", &error);
    assert_eq!(
        skip_statuses(&events),
        0,
        "recoverable checkpoint skips must not enter the status stream"
    );

    mux.note_reconnect_checkpoint_captured();
    mux.report_skipped_reconnect_checkpoint("term_three", &error);
    assert_eq!(
        skip_statuses(&events),
        0,
        "re-armed diagnostic logging must remain out of the status stream"
    );
    assert_eq!(
            &*diagnostics.lock().unwrap(),
            &vec![
                "skipped terminal term_one reconnect checkpoint (replay starts from the previous boundary): session changed during checkpoint capture".to_string(),
                "skipped terminal term_three reconnect checkpoint (replay starts from the previous boundary): session changed during checkpoint capture".to_string(),
            ]
        );
}

#[test]
fn diagnostic_reporters_are_scoped_to_each_mux_and_first_writer_wins() {
    let first = test_mux();
    let second = test_mux();
    let first_reports = Arc::new(Mutex::new(Vec::<String>::new()));
    let second_reports = Arc::new(Mutex::new(Vec::<String>::new()));

    let first_reports_sink = Arc::clone(&first_reports);
    assert!(first.set_diagnostic_reporter(Arc::new(move |message| {
        first_reports_sink.lock().unwrap().push(message.to_string());
    })));
    assert!(!first.set_diagnostic_reporter(Arc::new(|_| {})));

    let second_reports_sink = Arc::clone(&second_reports);
    assert!(second.set_diagnostic_reporter(Arc::new(move |message| {
        second_reports_sink.lock().unwrap().push(message.to_string());
    })));

    let error = anyhow::anyhow!("checkpoint race");
    first.report_skipped_reconnect_checkpoint("first", &error);
    second.report_skipped_reconnect_checkpoint("second", &error);

    assert_eq!(
            &*first_reports.lock().unwrap(),
            &["skipped terminal first reconnect checkpoint (replay starts from the previous boundary): checkpoint race".to_string()]
        );
    assert_eq!(
            &*second_reports.lock().unwrap(),
            &["skipped terminal second reconnect checkpoint (replay starts from the previous boundary): checkpoint race".to_string()]
        );
}

#[test]
fn diagnostic_reporter_receives_skip_reported_before_installation() {
    let mux = test_mux();
    let diagnostics = Arc::new(Mutex::new(Vec::<String>::new()));
    let error = anyhow::anyhow!("startup checkpoint race");

    mux.report_skipped_reconnect_checkpoint("startup", &error);
    assert!(diagnostics.lock().unwrap().is_empty());

    let diagnostics_for_reporter = Arc::clone(&diagnostics);
    assert!(mux.set_diagnostic_reporter(Arc::new(move |message| {
        diagnostics_for_reporter.lock().unwrap().push(message.to_string());
    })));
    assert_eq!(
            &*diagnostics.lock().unwrap(),
            &["skipped terminal startup reconnect checkpoint (replay starts from the previous boundary): startup checkpoint race".to_string()]
        );
}
