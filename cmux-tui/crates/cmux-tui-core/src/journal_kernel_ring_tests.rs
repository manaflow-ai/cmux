//! The live journal ring is small and a reader behind it misses nothing
//! (soak lead 2026-10-28: the daemon grew ~4.4 MB/h toward a 128 MiB ring
//! cap; Chrome keeps bounded in-memory history and pages the rest).

use std::path::PathBuf;
use std::sync::Arc;
use std::time::{Duration, Instant};

use serde_json::json;

use super::{JOURNAL_FANOUT_BYTE_CAPACITY, SharedJournalRead};
use crate::mux::ProviderWorkspaceState;
use crate::workspace_registry::WorkspaceRegistry;
use crate::{Mux, SurfaceOptions};

/// The most the live ring may hold: a few MiB, not 128.
const RING_BYTE_BOUND: usize = 8 * 1024 * 1024;

struct Root(PathBuf);

impl Drop for Root {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn open(session: &str) -> (Root, Arc<Mux>) {
    let root =
        Root(std::env::temp_dir().join(format!(
            "cmux-journal-ring-{session}-{}",
            crate::workspace_registry::new_uuid_v4()
        )));
    let registry = WorkspaceRegistry::open(&root.0, session).unwrap();
    let mux = Mux::from_workspace_registry(
        session.to_owned(),
        SurfaceOptions::default(),
        registry,
        ProviderWorkspaceState::default(),
        true,
    )
    .unwrap();
    (root, mux)
}

/// Agent turns: hook records with ~8 KiB each of prompt and reply text, as a
/// long agent session writes them.
fn append_agent_turns(mux: &Arc<Mux>, terminal: &str, turns: usize) {
    let prompt = "p".repeat(8 * 1024);
    let reply = "r".repeat(8 * 1024);
    for turn in 0..turns {
        let ingress = crate::agent_hooks::agent_hook_journal_ingress(
            "claude",
            "Stop",
            Some(terminal),
            json!({ "session_id": "ring", "prompt": format!("{turn} {prompt}"), "last_assistant_message": reply }),
        )
        .unwrap();
        let key = format!("ring-{}", crate::workspace_registry::new_uuid_v4());
        mux.append_journal_ingress(&ingress, "test", &key).unwrap();
    }
}

/// Pages from 0 through `head` the way a journal stream does: the ring
/// while its cursor is inside it, a SQLite reader of its own after a Gap,
/// and the ring again once the reader caught up past the ring's start.
/// Returns every sequence, in the order it got them.
fn read_all(mux: &Arc<Mux>, head: u64) -> Vec<u64> {
    let mut cursor = 0;
    let mut seen = Vec::new();
    let mut reader = None;
    while cursor < head {
        // Back to the ring as soon as it covers the next record.
        if reader.is_some()
            && let SharedJournalRead::Page(page) = mux.shared_journal_after(cursor, 1)
            && page.records.first().is_some_and(|doc| doc.record.sequence == cursor + 1)
        {
            reader = None;
        }
        let page: Vec<u64> = match (reader.is_none(), mux.shared_journal_after(cursor, 256)) {
            (true, SharedJournalRead::Page(page)) => {
                page.records.iter().map(|doc| doc.record.sequence).collect()
            }
            _ => {
                let reader =
                    reader.get_or_insert_with(|| mux.session_journal_reader().unwrap().unwrap());
                reader.after(cursor, 256).unwrap().records.iter().map(|r| r.sequence).collect()
            }
        };
        let Some(&last) = page.last() else { break };
        seen.extend(page);
        cursor = last;
    }
    seen
}

#[test]
fn the_live_ring_stays_small_and_a_reader_behind_it_gets_every_record_in_order() {
    let (_root, mux) = open("ring-small");
    assert!(mux.shared_journal_enabled(), "a file-backed session has the shared journal");
    let surface = mux.new_workspace(None, None).unwrap();
    let terminal = surface.terminal_public_id().cloned().unwrap();
    // ~33 KB resident budget each: 600 turns are far past a few MiB.
    append_agent_turns(&mux, terminal.as_str(), 600);
    let head = mux.session_journal_head().unwrap();
    // The tailer publishes asynchronously: wait for it to reach the head.
    let deadline = Instant::now() + Duration::from_secs(20);
    loop {
        if let SharedJournalRead::Page(page) = mux.shared_journal_after(head.saturating_sub(1), 1)
            && page.records.last().is_some_and(|doc| doc.record.sequence == head)
        {
            break;
        }
        assert!(Instant::now() < deadline, "the shared journal never reached the head {head}");
        std::thread::sleep(Duration::from_millis(20));
    }

    let (records, bytes) = mux.shared_journal_handle().ring_for_test();
    assert!(
        bytes <= RING_BYTE_BOUND && JOURNAL_FANOUT_BYTE_CAPACITY <= RING_BYTE_BOUND,
        "the live ring holds {bytes} bytes in {records} records (cap {JOURNAL_FANOUT_BYTE_CAPACITY}); \
         it must stay within {RING_BYTE_BOUND}"
    );

    let seen = read_all(&mux, head);
    let expected: Vec<u64> = (1..=head).collect();
    assert_eq!(seen.len(), expected.len(), "a reader behind the ring missed records");
    assert_eq!(seen, expected, "a reader behind the ring got records out of order");
    mux.shutdown();
}
