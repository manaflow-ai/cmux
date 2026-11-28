//! Where each subagent's own records start in its chat's log, once a read has seen it, so every
//! later page of that subagent (`Hub::events_page` with `EventFilter::of_subagent`) starts there
//! and not at the chat's first line (Leo, ask-4646da8b19, on subagent panes: "these needs to be
//! faster").
//!
//! A subagent pane reads the subagent's newest page, then its older pages forward from the log's
//! start (webviews `direct.ts` `readSubagentLog`); its report card's Show more and the Background
//! tasks panel read it again. Each of those reads passed every line of the chat before the
//! subagent began: a subagent that started late in a long chat cost a byte search of the whole
//! chat on every read. The store seeks to a seq (`store/segment_starts.rs`, `log_line::start_of_seq`),
//! so a read that knows where the subagent starts reads only its span.
//!
//! A start is kept only when a read proved it: a forward read from the log's start found the
//! subagent's first matching record, or a newest-first read ran down to the start with no more
//! left. It is kept with the log's stamp (`store/log_bytes.rs`: a cut, a compaction or a fork's
//! history bumps it), and taken only under the same stamp, so a log whose lines read differently
//! is read whole again. A compaction only drops records, so a kept start stays at or before the
//! subagent's first kept record. Keyed by the page's kinds too: another set of kinds may match an
//! earlier record.
//!
//! At most [`ENTRIES`] starts; a full map is emptied, so the memory is bounded whatever the number
//! of chats and subagents.

use std::collections::HashMap;
use std::sync::Mutex;

/// The most starts kept at once.
pub(crate) const ENTRIES: usize = 4096;

type Key = (String, String, String);

/// Kept starts: (chat, subagent, kinds) to (log stamp, first seq).
#[derive(Default)]
pub(crate) struct SubagentStarts {
    starts: Mutex<HashMap<Key, (u64, u64)>>,
}

impl SubagentStarts {
    /// The kept first seq of `subagent` in chat `session` for pages of `kinds`, if the log's
    /// stamp is still `stamp`.
    pub(crate) fn get(
        &self,
        session: &str,
        subagent: &str,
        kinds: &str,
        stamp: u64,
    ) -> Option<u64> {
        let starts = self.starts.lock().unwrap_or_else(|e| e.into_inner());
        let key = (session.to_owned(), subagent.to_owned(), kinds.to_owned());
        starts.get(&key).filter(|(at, _)| *at == stamp).map(|(_, seq)| *seq)
    }

    /// Keeps `seq` as where `subagent`'s records of `kinds` start, read under `stamp`.
    pub(crate) fn put(&self, session: &str, subagent: &str, kinds: &str, stamp: u64, seq: u64) {
        let mut starts = self.starts.lock().unwrap_or_else(|e| e.into_inner());
        if starts.len() >= ENTRIES {
            starts.clear();
        }
        starts.insert((session.to_owned(), subagent.to_owned(), kinds.to_owned()), (stamp, seq));
    }
}
