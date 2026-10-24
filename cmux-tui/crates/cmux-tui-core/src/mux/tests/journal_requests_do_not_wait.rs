//! A journal request answers without waiting for the journal writer
//! (PL-daemon; perf-lead.md D1: no request waits for the journal writer).
//!
//! The writer is paused before a batch, as a writer busy elsewhere. A
//! producer append (`session.journal.append`, the agent
//! hook) and a frontend observation (`journal-frontend-event`) must still
//! answer: the producer append commits on the request thread, the frontend
//! observation is queued for the writer and not waited for.

use super::*;
use std::sync::mpsc::{SyncSender, sync_channel};

fn persistent_mux(name: &str) -> (Arc<Mux>, std::path::PathBuf) {
    let root = std::env::temp_dir().join(format!(
        "cmux-journal-no-wait-{name}-{}-{}",
        std::process::id(),
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
    ));
    let mux = Mux::open_persistent(name, SurfaceOptions::default(), &root).unwrap();
    (mux, root)
}

/// Pause the writer before a batch (a writer busy elsewhere): a terminal
/// resize event takes it there.
fn pause_writer(mux: &Mux) -> SyncSender<()> {
    let (entered, entered_receiver) = sync_channel(1);
    let (release, release_receiver) = sync_channel(1);
    mux.journal_ingress.install_before_batch_hook_for_test(entered, release_receiver);
    let terminal_id = Arc::new(TerminalPublicId::parse(format!("term_{:032x}", 77)).unwrap());
    mux.journal_terminal_resize(terminal_id, Arc::from("no-wait-generation"), 80, 24, 8, 16);
    entered_receiver.recv_timeout(Duration::from_secs(10)).unwrap();
    release
}

#[test]
fn a_producer_append_answers_while_the_writer_is_paused() {
    let (mux, root) = persistent_mux("producer");
    let release = pause_writer(&mux);
    let ingress = crate::agent_hook_journal_ingress(
        "codex",
        "Stop",
        None,
        serde_json::json!({"session_id":"no-wait-session"}),
    )
    .unwrap();
    let appending = mux.clone();
    let (done, done_receiver) = sync_channel(1);
    let started = Instant::now();
    let appender = std::thread::spawn(move || {
        let result = appending.append_journal_ingress(&ingress, "client_no_wait", "no_wait_1");
        done.send(result.map(|commit| commit.sequence).map_err(|e| e.to_string())).unwrap();
    });
    let answered = done_receiver.recv_timeout(Duration::from_secs(1));
    let waited = started.elapsed();
    release.send(()).unwrap();
    appender.join().unwrap();
    assert!(
        matches!(answered, Ok(Ok(_))),
        "a producer append waited for the paused journal writer ({waited:?}): {answered:?}"
    );
    drop(mux);
    let _ = std::fs::remove_dir_all(root);
}

#[test]
fn a_frontend_observation_answers_while_the_writer_is_paused() {
    let (mux, root) = persistent_mux("frontend");
    let release = pause_writer(&mux);
    let observing = mux.clone();
    let (done, done_receiver) = sync_channel(1);
    let observer = std::thread::spawn(move || {
        let result = observing.journal_frontend_event(
            "client_no_wait".to_string(),
            crate::FrontendJournalEvent::Resize {
                event_id: "no-wait-resize-1".to_string(),
                frontend_projection_id: FrontendProjectionPublicId::parse(format!(
                    "projection_{:032x}",
                    91
                ))
                .unwrap(),
                generation: "no-wait-generation".to_string(),
                cols: 80,
                rows: 24,
                cell_width: 8,
                cell_height: 16,
            },
        );
        done.send(result.map_err(|e| e.to_string())).unwrap();
    });
    let answered = done_receiver.recv_timeout(Duration::from_secs(1));
    release.send(()).unwrap();
    observer.join().unwrap();
    assert!(
        matches!(answered, Ok(Ok(_))),
        "a frontend observation waited for the paused journal writer: {answered:?}"
    );
    drop(mux);
    let _ = std::fs::remove_dir_all(root);
}
