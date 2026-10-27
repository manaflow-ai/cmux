//! Earlier indeterminate receipts on the request path: `drain_unsettled`
//! waits for the journal writer, a `journal_wait` noted at its caller.

use cmux_threads::sync::mpsc::sync_channel;
use std::time::Duration;

use super::*;
use crate::request_path::{BlockingKind, RequestPathMode, RequestPathScope, RequestPathStats};

fn journal_wait_lines(stats: &RequestPathStats) -> Vec<(&'static str, u32)> {
    stats
        .sites()
        .into_iter()
        .filter(|noted| noted.kind == BlockingKind::JournalWait)
        .map(|noted| (noted.site.file(), noted.site.line()))
        .collect()
}

#[test]
fn drain_unsettled_notes_a_journal_wait_for_an_unanswered_receipt() {
    let registry = WorkspaceRegistry::in_memory("drain-unsettled-wait").expect("registry");
    let (answer, receipt) = sync_channel(1);
    registry.connection.hold_unsettled(PendingRegistryReceipt::for_test(receipt), None);
    let writer = std::thread::spawn(move || {
        std::thread::sleep(Duration::from_millis(5));
        answer.send(Err("rolled back".to_string())).expect("answer");
    });
    let stats = RequestPathStats::new(RequestPathMode::RECORD);
    let _scope = RequestPathScope::enter(&stats);
    let line = line!() + 1;
    registry.connection.drain_unsettled().expect("the receipt arrived");
    writer.join().expect("writer");
    assert_eq!(journal_wait_lines(&stats), [(file!(), line)]);
}

#[test]
fn drain_unsettled_notes_nothing_for_an_answered_receipt() {
    let registry = WorkspaceRegistry::in_memory("drain-unsettled-answered").expect("registry");
    let (answer, receipt) = sync_channel(1);
    answer.send(Err("rolled back".to_string())).expect("answer");
    registry.connection.hold_unsettled(PendingRegistryReceipt::for_test(receipt), None);
    let stats = RequestPathStats::new(RequestPathMode::RECORD);
    let _scope = RequestPathScope::enter(&stats);
    registry.connection.drain_unsettled().expect("already answered");
    registry.connection.drain_unsettled().expect("nothing left to wait for");
    assert_eq!(stats.count(BlockingKind::JournalWait), 0);
}
