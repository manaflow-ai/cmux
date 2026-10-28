//! Part of `Hub`; see `hub/mod.rs`. Cursor paging and kind filters over a
//! session's event log, shared by `_acpmux/events` and `_acpmux/attach`.

use super::*;

/// `session/update` kinds that carry no renderable transcript content.
const NON_TRANSCRIPT_UPDATES: &[&str] = &[
    "usage_update",
    "available_commands_update",
    "current_mode_update",
    "config_option_update",
    // A compaction's summary is context a handoff carries, not a chat row.
    "compaction_summary",
];

/// Mux records a chat client renders. `turn_end` and `turn_error` are left
/// out because every turn also records `turn_result`.
pub const TRANSCRIPT_MUX_KINDS: &[&str] = &[
    "user_message",
    "queued",
    "dequeued",
    "queue_removed",
    "prompt_retracted",
    // A steer taken back before the agent read it (`queue_edit.rs` `withdraw`).
    "steer_withdrawn",
    // Edit queued prompt, Move up / Move down, and a queue a failed turn holds:
    // the queue a chat client shows changes with them.
    "queue_updated",
    "queue_order",
    "queue_paused",
    "queue_resumed",
    "turn_started",
    // The turn's agent has said nothing since its prompt, and then its model's first sign
    // (`silent_turn.rs`).
    "turn_silent",
    "turn_heard",
    "turn_result",
    "permission_request",
    "permission_auto",
    "permission_decision",
    "permission_group",
    "permission_chat_allowance",
    "message_superseded",
    "failover",
    // A policy narrower than approve-all that the chat's harness cannot keep
    // (`policy_mode.rs`): the chat says so where it happened.
    "policy_unenforced",
    "forked",
    "imported",
    "session_offer",
    "session_offer_decision",
    "mode",
    "model",
    "stopped",
    "exited",
    // The agent process started again: a client reads a subagent the old
    // process left running as stopped, as `processes.rs` does its processes.
    "resumed",
    "reopened",
    "host_started",
    "host_ended",
];

/// Which records a page or a live event stream carries. `kinds` entries are
/// either a category (`transcript`, `mux`, `wire`, `all`) or an exact record
/// kind; a record passes when any entry matches.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct EventFilter {
    kinds: Option<Vec<String>>,
}

impl EventFilter {
    pub fn all() -> Self {
        Self::default()
    }

    /// Parse the `kinds` parameter: absent or null means every record.
    pub fn parse(v: Option<&Value>) -> Result<Self, RpcError> {
        match v {
            None | Some(Value::Null) => Ok(Self::all()),
            Some(Value::String(s)) => Ok(Self { kinds: Some(vec![s.clone()]) }),
            Some(Value::Array(a)) => {
                let mut kinds = Vec::with_capacity(a.len());
                for k in a {
                    let k = k.as_str().ok_or_else(|| {
                        RpcError::invalid_params("kinds must be an array of strings")
                    })?;
                    kinds.push(k.to_owned());
                }
                Ok(Self { kinds: Some(kinds) })
            }
            Some(_) => Err(RpcError::invalid_params("kinds must be an array of strings")),
        }
    }

    pub fn is_all(&self) -> bool {
        match &self.kinds {
            None => true,
            Some(k) => k.iter().any(|k| k == "all"),
        }
    }

    /// True when no record with this `dir` and `kind` can match, so a store can
    /// pass its line without parsing it. False means "parse and ask `matches`":
    /// an `in` record's kind alone does not say whether it is an agent update,
    /// except for the kinds that never are (raw harness lines, responses, load
    /// replays and bookkeeping updates).
    pub fn surely_skips(&self, dir: &[u8], kind: &[u8]) -> bool {
        let Some(kinds) = &self.kinds else { return false };
        !kinds.iter().any(|k| match k.as_str() {
            "all" | "wire" => true,
            "transcript" => transcript_may_match(dir, kind),
            "mux" => dir == b"mux",
            exact => kind == exact.as_bytes(),
        })
    }

    pub fn matches(&self, rec: &EventRecord) -> bool {
        let Some(kinds) = &self.kinds else { return true };
        kinds.iter().any(|k| match k.as_str() {
            "all" => true,
            "transcript" => is_transcript(rec),
            "mux" => rec.dir == "mux",
            "wire" => is_wire(rec),
            exact => rec.kind == exact,
        })
    }
}

fn is_agent_update(rec: &EventRecord) -> bool {
    rec.dir == "in" && rec.msg.get("method").and_then(Value::as_str) == Some(method::SESSION_UPDATE)
}

/// A record a chat transcript renders: an agent `session/update` that is
/// not a load replay or bookkeeping, or a mux record in `TRANSCRIPT_MUX_KINDS`.
pub fn is_transcript(rec: &EventRecord) -> bool {
    if is_agent_update(rec) {
        return !rec.kind.ends_with(".replay")
            && !NON_TRANSCRIPT_UPDATES.contains(&rec.kind.as_str());
    }
    rec.dir == "mux" && TRANSCRIPT_MUX_KINDS.contains(&rec.kind.as_str())
}

/// Whether a record with this `dir` and `kind` may be a transcript record
/// (`is_transcript`); false only when it surely is not.
fn transcript_may_match(dir: &[u8], kind: &[u8]) -> bool {
    match dir {
        b"mux" => TRANSCRIPT_MUX_KINDS.iter().any(|k| k.as_bytes() == kind),
        // A live agent update's kind is its `sessionUpdate` (hub/tap.rs); a raw
        // harness line keeps its `claude.` method and a reply is `response`.
        b"in" => {
            !kind.ends_with(b".replay")
                && !kind.starts_with(b"claude.")
                && kind != b"response"
                && !NON_TRANSCRIPT_UPDATES.iter().any(|k| k.as_bytes() == kind)
        }
        _ => false,
    }
}

/// Raw protocol traffic: requests, responses, replays and harness lines.
fn is_wire(rec: &EventRecord) -> bool {
    let live_update = is_agent_update(rec) && !rec.kind.ends_with(".replay");
    (rec.dir == "in" || rec.dir == "out") && !live_update
}

/// About what a record adds to a page's JSON: its message plus the envelope
/// (`sessionId`, `seq`, `at`, `dir`, `kind`).
fn record_bytes(rec: &EventRecord) -> usize {
    serde_json::to_string(&rec.msg).map_or(0, |msg| msg.len()) + rec.kind.len() + 120
}

/// The most JSON one page holds when the caller names no `maxBytes`, and the most it may
/// name. A page's records are parsed trees until the reply is written, many times their
/// JSON: one read of a whole 31 MB log held about 1 GB (huge-blue, 2026-10-21), and a 4 MiB
/// page still grew the daemon by 95 MB. A longer read takes more pages through `hasMore`;
/// the app's pages are 128 and 256 KiB. A page also goes out as one message, under
/// `rpc::MAX_MESSAGE_BYTES`: 5000 records of a chat with long tool outputs were 32.8 MB.
pub const DEFAULT_PAGE_BYTES: usize = 1 << 20;
pub const MAX_PAGE_BYTES: usize = 4 << 20;

/// A page's byte limit from `maxBytes`: [`DEFAULT_PAGE_BYTES`] when absent, at most
/// [`MAX_PAGE_BYTES`].
pub fn page_bytes(params: &Value) -> usize {
    let asked = params.get("maxBytes").and_then(Value::as_u64);
    asked
        .map_or(DEFAULT_PAGE_BYTES, |b| usize::try_from(b).unwrap_or(usize::MAX))
        .min(MAX_PAGE_BYTES)
}

/// The most JSON one record may hold in a page: a page always carries at least one record and
/// goes out as one message, so a record must leave room under `rpc::MAX_MESSAGE_BYTES` for the
/// reply around it.
pub const MAX_RECORD_BYTES: usize = crate::rpc::MAX_MESSAGE_BYTES - (1 << 20);

/// A record no message can carry goes as a stub with its kind and seq: what it left out, and how
/// much. Also returns what the record adds to the page.
fn fit(mut rec: EventRecord, bounded: bool) -> (EventRecord, usize) {
    let bytes = record_bytes(&rec);
    if !bounded || bytes <= MAX_RECORD_BYTES {
        return (rec, bytes);
    }
    rec.msg = json!({"_meta": {"acpmux": {"omitted": {"bytes": bytes, "reason": "too_large"}}}});
    let stub = record_bytes(&rec);
    (rec, stub)
}

/// One page of a session's log, oldest first.
#[derive(Debug, Default)]
pub struct EventPage {
    pub events: Vec<EventRecord>,
    /// More matching records exist beyond the page: older ones when paging
    /// backwards, newer ones (below `before`) when paging forwards.
    pub has_more: bool,
}

impl Hub {
    /// Read a page of matching records with `after < seq < before`.
    /// `newest` picks the last `limit` of them instead of the first. A page
    /// also ends before its records' JSON would pass `max_bytes` (the reply a
    /// remote client downloads); it always holds at least one record.
    pub fn events_page(
        &self,
        id: &str,
        after: u64,
        before: Option<u64>,
        limit: usize,
        max_bytes: Option<usize>,
        newest: bool,
        filter: &EventFilter,
    ) -> Result<EventPage> {
        let before = before.unwrap_or(u64::MAX);
        let bounded = max_bytes.is_some();
        // An ask in the log reads as acpmux shows it now (`Hub::display_logged`).
        let session = self.sessions.lock().unwrap_or_else(|e| e.into_inner()).get(id).cloned();
        let mut page = EventPage::default();
        let mut bytes = 0usize;
        // Whether the page is full before `rec`: by count, or by size once it holds a record.
        let mut full = |rec_bytes: usize, found: usize| {
            if found == limit {
                return true;
            }
            let Some(max) = max_bytes else { return false };
            bytes += rec_bytes;
            found > 0 && bytes > max
        };
        if limit == 0 || !newest {
            let mut found = 0usize;
            self.store.scan(id, after, &mut |rec| {
                if rec.seq >= before {
                    return false;
                }
                if !filter.matches(&rec) {
                    return true;
                }
                let mut rec = rec;
                self.display_logged(session.as_deref(), &mut rec);
                let (rec, rec_bytes) = fit(rec, bounded);
                if full(rec_bytes, found) {
                    page.has_more = true;
                    return false;
                }
                found += 1;
                page.events.push(rec);
                true
            })?;
            return Ok(page);
        }
        let mut found = Vec::new();
        let skip = |dir: &[u8], kind: &[u8]| filter.surely_skips(dir, kind);
        self.store.scan_back(id, after, before, &skip, &mut |rec| {
            if !filter.matches(&rec) {
                return true;
            }
            let mut rec = rec;
            self.display_logged(session.as_deref(), &mut rec);
            let (rec, rec_bytes) = fit(rec, bounded);
            if full(rec_bytes, found.len()) {
                page.has_more = true;
                return false;
            }
            found.push(rec);
            true
        })?;
        found.reverse();
        page.events = found;
        Ok(page)
    }
}

#[cfg(test)]
mod transcript_kind_tests {
    use super::*;

    fn mux(kind: &str) -> EventRecord {
        EventRecord {
            seq: 1,
            at: 0,
            dir: "mux".into(),
            kind: kind.into(),
            msg: json!({}),
            host_seq: None,
        }
    }

    /// A chat client that follows `transcript` sees every change to the
    /// queue it shows: Edit queued prompt (`queue_updated`), Move up / Move
    /// down (`queue_order`), and a queue held after a failed turn.
    #[test]
    fn queue_edits_are_transcript_records() {
        for kind in [
            "queued",
            "dequeued",
            "queue_removed",
            "queue_updated",
            "queue_order",
            "queue_paused",
            "queue_resumed",
        ] {
            assert!(is_transcript(&mux(kind)), "{kind} is not a transcript record");
        }
    }

    /// A chat client reads a subagent nothing will end any more as stopped
    /// when the agent process behind the chat went away or started again.
    #[test]
    fn agent_process_changes_are_transcript_records() {
        for kind in ["stopped", "exited", "resumed", "reopened", "host_started", "host_ended"] {
            assert!(is_transcript(&mux(kind)), "{kind} is not a transcript record");
        }
    }

    /// A chat client notes a policy its harness cannot keep where it was
    /// logged, as it notes a failover.
    #[test]
    fn an_unenforced_policy_is_a_transcript_record() {
        assert!(is_transcript(&mux("policy_unenforced")));
        let transcript = EventFilter::parse(Some(&json!(["transcript"]))).unwrap();
        assert!(!transcript.surely_skips(b"mux", b"policy_unenforced"));
    }
}
