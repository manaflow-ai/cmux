use std::sync::Arc;
use std::sync::mpsc::sync_channel;
use std::time::Instant;

use super::*;
use crate::Mux;
use crate::journal_ingress::{
    JOURNAL_TERMINAL_QUEUE_CAPACITY, JournalIngressEvent, JournalIngressSender,
};
use crate::resource::TerminalPublicId;

#[test]
fn the_retry_schedule_runs_from_one_second_to_a_minute() {
    let mut delay = RETRY_INITIAL;
    let mut seen = vec![delay.as_secs()];
    for _ in 0..8 {
        delay = next_retry_delay(delay, RETRY_MAX);
        seen.push(delay.as_secs());
    }
    assert_eq!(seen, [1, 2, 4, 8, 16, 32, 60, 60, 60]);
}

#[test]
fn a_full_disk_is_told_from_a_store_error() {
    use std::io::{Error, ErrorKind};
    let sqlite = |code| rusqlite::Error::SqliteFailure(rusqlite::ffi::Error::new(code), None);
    let full = || sqlite(rusqlite::ffi::SQLITE_FULL);
    assert!(is_disk_full(&anyhow::Error::from(full()).context("append session journal")));
    assert!(!is_disk_full(&sqlite(rusqlite::ffi::SQLITE_CONSTRAINT).into()));
    assert!(!is_disk_full(&anyhow::anyhow!("database or disk is full")));
    // Also wrapped in another io::Error, whose `source()` skips the payload.
    let mut wrapped = vec![Error::from(ErrorKind::StorageFull), Error::other(full())];
    #[cfg(unix)]
    wrapped.extend([libc::ENOSPC, libc::EDQUOT].map(Error::from_raw_os_error));
    for error in wrapped.into_iter().map(Error::other) {
        let text = error.to_string();
        assert!(is_disk_full(&anyhow::Error::from(error).context("write")), "{text}");
    }
    assert!(!is_disk_full(&Error::other(Error::from(ErrorKind::NotFound)).into()));
}

#[test]
fn a_background_event_is_dropped_not_blocked_while_the_disk_is_full() {
    let (sender, _receivers) = JournalIngressSender::new(true);
    sender.state.disk_full.full.store(true, Ordering::Release);
    let terminal_id = Arc::new(term(31));
    let event = || JournalIngressEvent::TerminalOutput {
        terminal_id: terminal_id.clone(),
        generation: Arc::from("disk-full-generation"),
        occurred_at_ms: 1,
        bytes: b"x".to_vec(),
    };
    for _ in 0..JOURNAL_TERMINAL_QUEUE_CAPACITY {
        sender.send(event());
    }
    assert_eq!(sender.state.disk_full.dropped.load(Ordering::Relaxed), 0);
    // The queue is full and nothing drains it: this returned only by
    // dropping the event (before, it waited for room forever).
    sender.send(event());
    assert_eq!(sender.state.disk_full.dropped.load(Ordering::Relaxed), 1);
}

#[test]
fn answering_waiters_drains_a_bounded_amount_while_producers_refill() {
    let (sender, receivers) = JournalIngressSender::new(true);
    let receivers = receivers.unwrap();
    let terminal_id = Arc::new(term(33));
    let event = move || JournalIngressEvent::TerminalOutput {
        terminal_id: terminal_id.clone(),
        generation: Arc::from("refill-generation"),
        occurred_at_ms: 1,
        bytes: b"x".to_vec(),
    };
    // A waiter queued behind the background events.
    let (completion, result) = sync_channel(1);
    let barrier = QueuedJournalEvent {
        event: JournalIngressEvent::TerminalBarrier,
        completion: Some(super::super::JournalIngressCompletion::Durable {
            sender: completion,
            deadline: Instant::now() + Duration::from_secs(30),
            commit_fence: Arc::default(),
        }),
    };
    let terminal = sender.terminal_sender.as_ref().unwrap().clone();
    terminal.try_send(barrier).ok().unwrap();
    let stop = Arc::new(AtomicBool::new(false));
    let refill = {
        let (stop, sender) = (stop.clone(), terminal);
        std::thread::spawn(move || {
            while !stop.load(Ordering::Acquire) {
                let queued = QueuedJournalEvent { event: event(), completion: None };
                let _ = sender.try_send(queued);
            }
        })
    };
    let (mut batch, mut pending) = (Vec::new(), VecDeque::new());
    let started = Instant::now();
    DiskFullRetry::new().answer_waiters(&receivers, &mut batch, &mut pending, "full");
    let elapsed = started.elapsed();
    stop.store(true, Ordering::Release);
    refill.join().unwrap();
    assert!(elapsed < Duration::from_secs(1), "{elapsed:?}");
    assert!(batch.len() <= KEEP_MAX && batch.iter().all(|queued| queued.completion.is_none()));
    assert_eq!(result.try_recv().expect("the waiter is answered").unwrap_err(), "full");
}

#[test]
fn a_full_disk_pauses_the_journal_writer_until_there_is_room() {
    let id = crate::workspace_registry::new_uuid_v4();
    let root = std::env::temp_dir().join(format!("cmux-journal-disk-full-{id}"));
    let mux = Mux::open_persistent("disk-full", crate::SurfaceOptions::default(), &root).unwrap();
    let (failed, failed_receiver) = sync_channel(1);
    mux.install_journal_failure_notifier_for_test(failed);
    mux.flush_terminal_journal().unwrap();
    // The database may not grow: a commit that needs a page fails with
    // SQLITE_FULL, as on a full disk.
    mux.set_registry_max_page_count_for_test(None).unwrap();
    let (terminal_id, generation) = (Arc::new(term(32)), Arc::<str>::from("disk-full"));
    let while_full = vec![b'f'; 1024 * 1024];
    mux.journal_terminal_output(terminal_id.clone(), generation.clone(), while_full.clone());
    // A barrier sent before the writer holds the output, and one after,
    // are answered at once; the writer does not stop.
    for _ in 0..2 {
        let started = Instant::now();
        let error = mux.flush_terminal_journal().unwrap_err().to_string();
        assert!(error.contains("out of disk space"), "{error}");
        assert!(started.elapsed() < Duration::from_secs(1), "{:?}", started.elapsed());
    }
    assert!(mux.journal_disk_full_for_test() && failed_receiver.try_recv().is_err());
    // Room again: a refused waiter wakes the writer, whose next try
    // commits the kept output; new output follows it.
    mux.set_registry_max_page_count_for_test(Some(1 << 30)).unwrap();
    let deadline = Instant::now() + Duration::from_secs(5);
    while mux.journal_disk_full_for_test() {
        assert!(Instant::now() < deadline, "the writer did not resume once there was room");
        let _ = mux.flush_terminal_journal();
        std::thread::sleep(Duration::from_millis(20));
    }
    mux.journal_terminal_output(terminal_id, generation, b"after".to_vec());
    mux.flush_terminal_journal().unwrap();
    let records = mux.session_journal_after(0, 1024).unwrap().records.into_iter();
    let output = records.filter_map(|record| record.terminal_output).collect::<Vec<_>>();
    assert_eq!(output.concat(), [while_full, b"after".to_vec()].concat());
    assert!(failed_receiver.try_recv().is_err() && !mux.daemon_shutdown_requested());
    drop(mux);
    std::fs::remove_dir_all(root).unwrap();
}

fn term(index: u128) -> TerminalPublicId {
    TerminalPublicId::parse(format!("term_{index:032x}")).unwrap()
}
