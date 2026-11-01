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
    "_acpmux/message",
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
    // Where a chat seeded from a Claude Code transcript's newest page has older turns
    // (`hub/native_history.rs`): the pane that pages back to it reads on from the transcript.
    "native_history",
    // The turn's agent has said nothing since its prompt, and then its model's first sign
    // (`silent_turn.rs`).
    "turn_silent",
    "turn_heard",
    "turn_result",
    // A turn the person did not start, around its rows (`background_turn.rs`).
    "background_turn",
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
    // A line from outside any chat, such as cmux Cloud's after it resized the machine
    // (`server/host_notice.rs`).
    "host_notice",
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
    /// A page read newest first leaves out what newer tool call updates in it make moot
    /// (`store/superseded.rs`). Pages only; a live stream ignores it.
    omit_superseded: bool,
}

impl EventFilter {
    pub fn all() -> Self {
        Self::default()
    }

    /// Parse the `kinds` parameter: absent or null means every record.
    pub fn parse(v: Option<&Value>) -> Result<Self, RpcError> {
        match v {
            None | Some(Value::Null) => Ok(Self::all()),
            Some(Value::String(s)) => Ok(Self { kinds: Some(vec![s.clone()]), ..Self::default() }),
            Some(Value::Array(a)) => {
                let mut kinds = Vec::with_capacity(a.len());
                for k in a {
                    let k = k.as_str().ok_or_else(|| {
                        RpcError::invalid_params("kinds must be an array of strings")
                    })?;
                    kinds.push(k.to_owned());
                }
                Ok(Self { kinds: Some(kinds), ..Self::default() })
            }
            Some(_) => Err(RpcError::invalid_params("kinds must be an array of strings")),
        }
    }

    /// For a page a client bounds by bytes (it names `maxBytes`): the app's open and its older
    /// pages. Every call still ends as logged; a reader that wants every record (an export, a
    /// lane report) names no bound and reads them all.
    pub fn omitting_superseded(mut self, on: bool) -> Self {
        self.omit_superseded = on;
        self
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

/// About what a record adds to a page's JSON: the record as written, escapes and all, plus the
/// `sessionId` the page adds. An agent names its own kinds, and a kind of 169 NULs is 1 KiB
/// of JSON: 14,000 such records counted by the kind's length passed as a 4 MiB page and were
/// more than one message.
fn record_bytes(rec: &EventRecord) -> usize {
    serde_json::to_string(rec).map_or(0, |json| json.len()) + 120
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
fn fit(rec: EventRecord, bounded: bool) -> (EventRecord, usize) {
    let bytes = record_bytes(&rec);
    fit_sized(rec, bytes, bounded)
}

/// [`fit`] for a record whose bytes are known.
fn fit_sized(mut rec: EventRecord, bytes: usize, bounded: bool) -> (EventRecord, usize) {
    if !bounded || bytes <= MAX_RECORD_BYTES {
        return (rec, bytes);
    }
    rec.msg = omitted(bytes);
    // A kind is an agent's own name for its update, and can be the large part.
    if rec.kind.len() > ENVELOPE_FIELD_BYTES {
        rec.kind.clear();
    }
    let stub = record_bytes(&rec);
    (rec, stub)
}

/// What a record's `msg` becomes when no message can carry it: what it left out, and how much.
pub fn omitted(bytes: usize) -> Value {
    json!({"_meta": {"acpmux": {"omitted": {"bytes": bytes, "reason": "too_large"}}}})
}

/// The most a reply carrying records holds before its JSON-RPC envelope: the same one MiB room
/// as a record's ([`MAX_RECORD_BYTES`]) for the id, the wrapper and a relaying peer's name.
pub const MAX_REPLY_BYTES: usize = MAX_RECORD_BYTES;

/// The fields of `_acpmux/attach`'s `session` that only its detail carries
/// (`Hub::session_detail`), each copied whole from what the agent said: the first a reply that
/// must fit gives up, largest first, each to its empty value.
const DETAIL_FIELDS: &[(&str, fn() -> Value)] = &[
    ("modes", || Value::Null),
    ("configOptions", || Value::Null),
    ("models", || Value::Null),
    ("agentInfo", || Value::Null),
    ("agentCapabilities", || Value::Null),
    ("usage", || Value::Null),
    ("goal", || Value::Null),
    ("contextBreakdown", || Value::Null),
    ("usageLimits", || Value::Null),
    ("availableCommands", || Value::Null),
    ("rulesJson", || Value::Null),
    ("pending", || Value::Array(Vec::new())),
];

/// The `session` fields that name the chat and where it runs, besides its `sessionId`: they go
/// last, only when nothing else is left to give up, so no value an agent sets (a title, a tag,
/// its own session id in `sessionReceipt`) can keep a chat from opening.
const IDENTITY_FIELDS: &[&str] =
    &["id", "qualifiedSessionId", "sessionReceipt", "status", "harness", "cwd", "peer"];

/// A record envelope field (`kind`, `dir`) past this is given up with the record's `msg`.
const ENVELOPE_FIELD_BYTES: usize = 1 << 10;

/// `value`'s empty value of its own type: what a field given up becomes after the detail's.
fn empty_like(value: &Value) -> Value {
    match value {
        Value::String(_) => Value::String(String::new()),
        Value::Array(_) => Value::Array(Vec::new()),
        Value::Object(_) => Value::Object(serde_json::Map::new()),
        _ => Value::Null,
    }
}

/// Makes a reply of records fit one message when each part fits but together they do not:
/// `_acpmux/attach`'s page and its `turnOpener` each keep a record of up to
/// [`MAX_RECORD_BYTES`], so a large prompt and its large answer were an 18.9 MB reply refused
/// as `message.too_large` at every open, and the chat never opened again (Leo, 2026-10-31:
/// "this is completely hardlocked bc of message size").
///
/// First the largest records' `msg` become [`omitted`] stubs, largest first, until the reply
/// fits; every record keeps its seq and time, and its kind unless that is past
/// [`ENVELOPE_FIELD_BYTES`]. The records are `events` (an array of
/// `_acpmux/event` values) and `turnOpener` (one). If it still does not fit, the `session`
/// detail's own fields ([`DETAIL_FIELDS`]) go, largest first, and then any other field but
/// the chat's identity ([`IDENTITY_FIELDS`]), each to its empty value and named in
/// `session._meta.acpmux.omitted`; the pane then reads as for an older acpmux that sent none.
/// Last, since an agent's own ids (`sessionReceipt.agentSessionId`) reach them too, the
/// identity fields go the same way. Only `sessionId`, acpmux's own id, always stays, so what
/// is left is at most that id and the records' envelopes, a few hundred bytes each.
pub fn fit_reply(reply: &mut Value) {
    let size = |value: &Value| serde_json::to_string(value).map_or(usize::MAX, |text| text.len());
    let mut bytes = size(reply);
    if bytes <= MAX_REPLY_BYTES {
        return;
    }
    let mut records: Vec<(String, usize)> = reply
        .get("events")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .enumerate()
        .map(|(index, record)| (format!("/events/{index}"), size(record)))
        .collect();
    if let Some(opener) = reply.get("turnOpener").filter(|opener| opener.is_object()) {
        records.push(("/turnOpener".to_owned(), size(opener)));
    }
    records.sort_by_key(|(_, bytes)| std::cmp::Reverse(*bytes));
    for (at, record_size) in records {
        if bytes <= MAX_REPLY_BYTES {
            return;
        }
        let Some(record) = reply.pointer_mut(&at).and_then(Value::as_object_mut) else {
            continue;
        };
        // Each change only shrinks the record: a stub smaller than its msg, an empty value.
        if let Some(msg) = record.get_mut("msg") {
            let msg_size = size(&*msg);
            let stub = omitted(msg_size);
            if size(&stub) < msg_size {
                *msg = stub;
            }
        }
        // The envelope too: an agent's own `sessionUpdate` name is its `kind`.
        for (name, value) in record.iter_mut() {
            if name != "seq" && name != "msg" && size(&*value) > ENVELOPE_FIELD_BYTES {
                *value = empty_like(&*value);
            }
        }
        let Some(record) = reply.pointer(&at) else { continue };
        bytes = bytes - record_size + size(record);
    }
    let Some(session) = reply.get_mut("session").and_then(Value::as_object_mut) else { return };
    let mut left_out = Vec::new();
    // The detail's fields first, then the rest but the chat's identity, then that identity but
    // its sessionId; each pass largest first.
    let detail: Vec<(String, Value)> = DETAIL_FIELDS
        .iter()
        .filter_map(|&(name, empty)| session.get(name).map(|_| (name.to_owned(), empty())))
        .collect();
    let rest: Vec<(String, Value)> = session
        .iter()
        .filter(|(name, _)| {
            *name != "sessionId"
                && !IDENTITY_FIELDS.contains(&name.as_str())
                && !DETAIL_FIELDS.iter().any(|(detail, _)| detail == name)
        })
        .map(|(name, value)| (name.clone(), empty_like(value)))
        .collect();
    let identity: Vec<(String, Value)> = IDENTITY_FIELDS
        .iter()
        .filter_map(|&name| session.get(name).map(|value| (name.to_owned(), empty_like(value))))
        .collect();
    for pass in [detail, rest, identity] {
        let mut fields: Vec<(String, Value, usize)> = pass
            .into_iter()
            .filter_map(|(name, empty)| {
                let field_size = session.get(&name).map(size)?;
                Some((name, empty, field_size))
            })
            .collect();
        fields.sort_by_key(|(_, _, bytes)| std::cmp::Reverse(*bytes));
        for (name, empty, field_size) in fields {
            if bytes <= MAX_REPLY_BYTES {
                break;
            }
            let empty_size = size(&empty);
            if empty_size >= field_size {
                break;
            }
            bytes = bytes - field_size + empty_size;
            session.insert(name.clone(), empty);
            left_out.push(Value::String(name));
        }
    }
    if !left_out.is_empty() {
        session.insert(
            "_meta".to_owned(),
            json!({"acpmux": {"omitted": {"fields": left_out, "reason": "too_large"}}}),
        );
    }
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
        // Newest first; a slot a later (older) record made moot is empty.
        let mut found: Vec<Option<(EventRecord, usize)>> = Vec::new();
        let mut held = 0usize;
        // A Codex command's updates each carry its whole output so far: without this, a few of
        // them fill the page (`store/superseded.rs`). Its prompts are read whatever the kinds: a
        // call id names a call within one prompt.
        let omit = filter.omit_superseded;
        let skip = |dir: &[u8], kind: &[u8]| {
            filter.surely_skips(dir, kind) && !(omit && crate::store::starts_prompt(dir, kind))
        };
        let mut superseded = omit.then(crate::store::Superseded::default);
        self.store.scan_back(id, after, before, &skip, &mut |rec| {
            let matches = filter.matches(&rec);
            let mut rec = rec;
            if matches {
                self.display_logged(session.as_deref(), &mut rec);
            }
            // Its bytes, once its superseded content is out: whether it goes out whole.
            let mut sized = None;
            let moot = match superseded.as_mut() {
                Some(superseded)
                    if matches
                        || crate::store::starts_prompt(rec.dir.as_bytes(), rec.kind.as_bytes()) =>
                {
                    superseded.read(&mut rec, found.len(), |rec| {
                        let bytes = record_bytes(rec);
                        sized = Some(bytes);
                        !bounded || bytes <= MAX_RECORD_BYTES
                    })
                }
                _ => None,
            };
            if !matches {
                return true;
            }
            let (rec, rec_bytes) = match sized {
                Some(bytes) => fit_sized(rec, bytes, bounded),
                None => fit(rec, bounded),
            };
            let moot_bytes = moot.and_then(|slot| found.get(slot)?.as_ref()).map_or(0, |(_, b)| *b);
            let kept = held + 1 - usize::from(moot.is_some());
            let size = bytes + rec_bytes - moot_bytes;
            // Full by count, or by size once it holds another record.
            if kept > limit || (kept > 1 && max_bytes.is_some_and(|max| size > max)) {
                page.has_more = true;
                return false;
            }
            if let Some(entry) = moot.and_then(|slot| found.get_mut(slot)) {
                *entry = None;
            }
            (held, bytes) = (kept, size);
            found.push(Some((rec, rec_bytes)));
            true
        })?;
        page.events = found.into_iter().rev().flatten().map(|(rec, _)| rec).collect();
        Ok(page)
    }
}

/// How much of a prompt's text an entry of the prompt index keeps: the rail's hover card title
/// clamps to three lines, so a pasted log never travels whole.
pub const PROMPT_INDEX_TEXT_CHARS: usize = 240;

/// A prompt's record as the prompt index carries it: its id, whether it was a steer or went on
/// with a turn, and the start of its text. Nothing else (images, pastes, `_meta`).
pub fn prompt_index_msg(msg: &Value) -> Value {
    let mut out = serde_json::Map::new();
    for key in ["promptId", "steer", "turnId", "continues"] {
        if let Some(value) = msg.get(key) {
            out.insert(key.to_owned(), value.clone());
        }
    }
    if let Some(text) = msg.get("text").and_then(Value::as_str) {
        let cut: String = text.chars().take(PROMPT_INDEX_TEXT_CHARS).collect();
        out.insert("text".to_owned(), Value::String(cut));
    }
    Value::Object(out)
}

impl Hub {
    /// Every prompt (`user_message`) of a session's log before `before`, oldest first, each cut to
    /// [`prompt_index_msg`]: the thread rail lays out a long chat's every turn from its first frame
    /// instead of growing as history pages in (Leo, 2026-10-31). One pass that parses only prompt
    /// lines (the store skips the rest by kind), so it stays fast however much tool output the
    /// chat has.
    pub fn prompt_index(&self, id: &str, before: Option<u64>) -> Result<Vec<EventRecord>> {
        let before = before.unwrap_or(u64::MAX);
        let mut out = Vec::new();
        let skip = |dir: &[u8], kind: &[u8]| !(dir == b"mux" && kind == b"user_message");
        self.store.scan_back(id, 0, before, &skip, &mut |mut rec| {
            if rec.dir == "mux" && rec.kind == "user_message" {
                rec.msg = prompt_index_msg(&rec.msg);
                out.push(rec);
            }
            true
        })?;
        out.reverse();
        Ok(out)
    }
}

#[cfg(test)]
#[path = "paging_tests.rs"]
mod paging_tests;

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
