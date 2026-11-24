//! The last few `_acpmux/events` replies, kept while their chat's log is unchanged
//! (cmuxterm-hq#13733, CMUX-672: idle CPU, RAM and disk "as low to 0 as possible").
//!
//! The app asks for a chat's newest page (400 records, 128 KiB) again and again while nothing is
//! appended: three identical asks within 200 ms on one chat, and the same page of a chat every few
//! seconds. Each ask read the log's tail back until the page filled: on a chat whose last records
//! are mostly kinds the page skips, megabytes of log for a 128 KiB reply. A daemon with an app
//! attached read 159 MB in 30 s for 45 pages (15.8 GB an hour, every byte from the page cache;
//! 6.8 to 15.7 GB an hour on a Mac with 6 chats open, cmuxterm-hq#13733).
//!
//! A reply is kept with the chat's `lastSeq` and log stamp (`store/log_bytes.rs`: a compaction, a
//! cut or a fork's history bumps it) it was read under, and answers the same ask while both are
//! the same: no record was appended and no line read differently. An append makes the next ask
//! read the log as before. Kept only:
//! - for an ask with no caller (the app, a peer): a lane's own read also marks its reports read
//!   (`Hub::lane_report_events_read`);
//! - for a page of at most [`MAX_PAGE_BYTES`];
//! - for a page with no ask in it: an ask reads as acpmux shows it now (`Hub::display_logged`),
//!   which a decision on another chat's policy can change with no record in this log.
//!
//! At most [`ENTRIES`] replies, the least recently asked dropped first: [`ENTRIES`] times
//! [`MAX_PAGE_BYTES`] bounds the memory, whatever the number of chats.

use std::collections::VecDeque;
use std::sync::Mutex;

use serde_json::Value;

use crate::store::EventRecord;

/// How many replies are kept: the chats an app keeps asking for at once.
pub(crate) const ENTRIES: usize = 16;

/// The largest page kept (the app's pages are 128 KiB).
pub(crate) const MAX_PAGE_BYTES: usize = 256 << 10;

struct Entry {
    session: String,
    key: String,
    last_seq: u64,
    stamp: u64,
    reply: Value,
}

/// The kept replies, newest asked first.
#[derive(Default)]
pub(crate) struct PageReplies {
    entries: Mutex<VecDeque<Entry>>,
}

/// The ask's key: its params as sent, less `_meta` (who sent it, not what it asks).
pub(crate) fn key(params: &Value) -> String {
    match params {
        Value::Object(fields) => {
            let mut fields = fields.clone();
            fields.remove("_meta");
            Value::Object(fields).to_string()
        }
        other => other.to_string(),
    }
}

/// Whether a page may be kept: none of its records reads as live state (module docs).
pub(crate) fn keepable(records: &[EventRecord]) -> bool {
    !records.iter().any(|rec| {
        rec.kind.starts_with("permission")
            || rec.msg.get("method").and_then(Value::as_str)
                == Some(crate::rpc::method::SESSION_REQUEST_PERMISSION)
    })
}

impl PageReplies {
    /// The reply kept for this ask of chat `session`, when its log is still at `last_seq` and
    /// `stamp`.
    pub(crate) fn get(&self, session: &str, key: &str, last_seq: u64, stamp: u64) -> Option<Value> {
        let mut entries = self.entries.lock().unwrap_or_else(|e| e.into_inner());
        let at = entries.iter().position(|e| e.session == session && e.key == key)?;
        if entries.get(at).is_some_and(|e| e.last_seq == last_seq && e.stamp == stamp) {
            let entry = entries.remove(at)?;
            let reply = entry.reply.clone();
            entries.push_front(entry);
            return Some(reply);
        }
        // Read under an older log: it never answers again.
        entries.remove(at);
        None
    }

    /// Keeps `reply` for this ask, read under `last_seq` and `stamp`.
    pub(crate) fn put(&self, session: &str, key: String, last_seq: u64, stamp: u64, reply: Value) {
        let mut entries = self.entries.lock().unwrap_or_else(|e| e.into_inner());
        entries.retain(|e| !(e.session == session && e.key == key));
        entries.push_front(Entry { session: session.to_owned(), key, last_seq, stamp, reply });
        entries.truncate(ENTRIES);
    }

    #[cfg(test)]
    pub(crate) fn len(&self) -> usize {
        self.entries.lock().unwrap_or_else(|e| e.into_inner()).len()
    }
}

impl super::Hub {
    /// Chat `id`'s log stamp, which a kept reply was read under: None when it does not read.
    pub(crate) fn page_log_stamp(&self, id: &str) -> Option<u64> {
        self.store.log_stamp(id).ok()
    }
}

#[cfg(test)]
#[path = "page_replies_tests.rs"]
mod tests;
