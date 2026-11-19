//! Row patches: a watch that asked `rowPatch: true` hears a changed row as only its changed
//! fields (`_acpmux/session_patch {sessionId, patch, unset}`), against the last row this
//! connection sent of the same chat, instead of the whole row (`_acpmux/session_changed`).
//!
//! An idle desktop, 2026-11-19: about 3.5 MB/s from acpmux to the app with nobody typing. Each
//! chat pane's watch got every row change as the whole ~4 KB row, where a background command's
//! update or a tool call changed four counters of it (`eventCount`, `lastSeq`, `updatedAt`,
//! `transcriptSeq`): a patch is a few hundred bytes. Those counters are read (the list sorts by
//! `updatedAt`, the pane reads `transcriptSeq`), so the change still goes; only its size drops.
//!
//! The base is what was sent, never what the client may have dropped: the fan-out task is the
//! only sender of row notices, so they reach the client in the order their bases were recorded.
//! A row goes whole on its first sight here, after the client asks (every `_acpmux/watch`
//! clears the book), after the hub feed lagged, after a notice too large to send was left out,
//! and when the book is full. A purge goes whole and drops its entry. A client that never asked
//! hears every row whole, as before.
//!
//! Memory: a local row's entry is the event's shared row (`HubEvent::row`), the one copy every
//! watcher already shares; a peer's row is kept as sent. At most [`MAX_ROWS`] entries.

use super::*;

/// The capability a daemon that answers `rowPatch` names (`capabilities.rs`).
pub(crate) const CAPABILITY: &str = "session-row-patch-v1";

/// The most rows one connection keeps a base of; past it, the book starts again (each row's next
/// change goes whole).
pub(super) const MAX_ROWS: usize = 4096;

/// The row a notice carried.
#[derive(Clone)]
pub(super) enum Row {
    /// This daemon's row, shared by every watcher of the event (`HubEvent::row`, which slot).
    Shared(Arc<[std::sync::OnceLock<Value>; 2]>, usize),
    /// A peer's row, as sent.
    Owned(Arc<Value>),
}

impl Row {
    fn value(&self) -> &Value {
        static NULL: Value = Value::Null;
        match self {
            Row::Shared(rows, at) => rows[*at].get().unwrap_or(&NULL),
            Row::Owned(row) => row,
        }
    }
}

#[derive(Default)]
pub(super) struct RowPatches {
    on: AtomicBool,
    sent: StdMutex<HashMap<String, Row>>,
}

impl RowPatches {
    /// `_acpmux/watch`: patches on or off; either way every row's next change goes whole.
    pub(super) fn watch(&self, on: bool) {
        let mut sent = self.sent.lock_or_recover();
        self.on.store(on, Ordering::SeqCst);
        sent.clear();
    }

    /// Every row's next change goes whole: the client may not have what this book says it has.
    pub(super) fn clear(&self) {
        if self.on.load(Ordering::Relaxed) {
            self.sent.lock_or_recover().clear();
        }
    }

    /// The notice for `row` with the rest of its params (`params`, without `session`): whole
    /// (`session_changed`), or its changes against the last row sent (`session_patch`). `params`
    /// must carry `sessionId`, and `peer` for a peer's row: the key the client holds the row by.
    pub(super) fn notice(&self, row: Row, mut params: Value) -> Message {
        let whole = |mut params: Value, row: &Row| {
            params.set("session", row.value().clone());
            Message::notification(method::MUX_SESSION_CHANGED, params)
        };
        if !self.on.load(Ordering::Relaxed) {
            return whole(params, &row);
        }
        let key = key(&params);
        let mut sent = self.sent.lock_or_recover();
        if params.get("kind").and_then(Value::as_str) == Some("purged") {
            sent.remove(&key);
            return whole(params, &row);
        }
        if sent.len() >= MAX_ROWS && !sent.contains_key(&key) {
            sent.clear();
        }
        let before = sent.insert(key, row.clone());
        let (Some(old), Some(new)) =
            (before.as_ref().and_then(|b| b.value().as_object()), row.value().as_object())
        else {
            return whole(params, &row);
        };
        let mut patch = serde_json::Map::new();
        for (field, value) in new {
            if old.get(field) != Some(value) {
                patch.insert(field.clone(), value.clone());
            }
        }
        let unset: Vec<Value> = old
            .keys()
            .filter(|field| !new.contains_key(*field))
            .map(|field| Value::String(field.clone()))
            .collect();
        params.set("patch", Value::Object(patch));
        if !unset.is_empty() {
            params.set("unset", Value::Array(unset));
        }
        Message::notification(method::MUX_SESSION_PATCH, params)
    }
}

/// The row's key, as the client holds it: its peer (none here) and its `sessionId`.
fn key(params: &Value) -> String {
    let peer = params.get("peer").and_then(Value::as_str).unwrap_or("");
    let id = params.get("sessionId").and_then(Value::as_str).unwrap_or("");
    format!("{peer}\u{1}{id}")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn shared(row: Value) -> Row {
        let rows: Arc<[std::sync::OnceLock<Value>; 2]> = Arc::default();
        rows[0].set(row).unwrap();
        Row::Shared(rows, 0)
    }

    /// The client's merge (`webviews/.../rowPatch.ts`), for the book's own tests.
    fn merge(held: &mut HashMap<String, Value>, msg: &Message) -> Value {
        let Message::Notification { method: m, params: Some(p) } = msg else { panic!() };
        let k = key(p);
        if m == method::MUX_SESSION_CHANGED {
            held.insert(k, p["session"].clone());
            return p["session"].clone();
        }
        let mut row = held[&k].as_object().unwrap().clone();
        for (f, v) in p["patch"].as_object().unwrap() {
            row.insert(f.clone(), v.clone());
        }
        for f in p["unset"].as_array().into_iter().flatten() {
            row.remove(f.as_str().unwrap());
        }
        held.insert(k, Value::Object(row.clone()));
        Value::Object(row)
    }

    fn method_of(msg: &Message) -> &str {
        msg.method().unwrap()
    }

    #[test]
    fn off_sends_every_row_whole() {
        let book = RowPatches::default();
        for n in 0..3 {
            let msg =
                book.notice(shared(json!({"sessionId": "a", "n": n})), json!({"sessionId": "a"}));
            assert_eq!(method_of(&msg), method::MUX_SESSION_CHANGED);
        }
        assert!(book.sent.lock_or_recover().is_empty(), "no book kept for a plain watch");
    }

    /// Changed, added and removed fields; a lag (`clear`) and a purge send the next row whole; the
    /// rows built from the notices equal the rows at each step.
    #[test]
    fn patches_rebuild_every_row_across_a_lag_and_a_purge() {
        let book = RowPatches::default();
        book.watch(true);
        let mut held = HashMap::new();
        let rows = [
            json!({"sessionId": "a", "n": 1, "title": "t", "usage": {"x": 1}}),
            json!({"sessionId": "a", "n": 2, "title": "t", "usage": {"x": 1}}),
            json!({"sessionId": "a", "n": 2, "usage": {"x": 2}, "retry": {"at": 5}}),
            json!({"sessionId": "a", "n": 2, "usage": {"x": 2}, "retry": {"at": 5}}),
        ];
        let mut methods = Vec::new();
        for row in &rows {
            let msg = book.notice(shared(row.clone()), json!({"sessionId": "a", "kind": "row"}));
            methods.push(method_of(&msg).to_owned());
            assert_eq!(&merge(&mut held, &msg), row);
        }
        assert_eq!(
            methods,
            [
                method::MUX_SESSION_CHANGED,
                method::MUX_SESSION_PATCH,
                method::MUX_SESSION_PATCH,
                method::MUX_SESSION_PATCH
            ]
        );
        // The last was a no-op: an empty patch, no unset.
        let msg = book.notice(shared(rows[3].clone()), json!({"sessionId": "a"}));
        let Message::Notification { params: Some(p), .. } = &msg else { panic!() };
        assert_eq!(p["patch"], json!({}));
        assert!(p.get("unset").is_none());
        // A lag: whole again.
        book.clear();
        let row = json!({"sessionId": "a", "n": 3});
        let msg = book.notice(shared(row.clone()), json!({"sessionId": "a"}));
        assert_eq!(method_of(&msg), method::MUX_SESSION_CHANGED);
        assert_eq!(merge(&mut held, &msg), row);
        // A purge: whole, and its entry goes.
        let msg = book
            .notice(shared(json!({"sessionId": "a"})), json!({"sessionId": "a", "kind": "purged"}));
        assert_eq!(method_of(&msg), method::MUX_SESSION_CHANGED);
        assert!(book.sent.lock_or_recover().is_empty());
    }

    /// A peer's row and this daemon's row of the same id are two rows.
    #[test]
    fn a_peer_row_is_its_own_row() {
        let book = RowPatches::default();
        book.watch(true);
        book.notice(shared(json!({"sessionId": "a", "n": 1})), json!({"sessionId": "a"}));
        let msg = book.notice(
            Row::Owned(Arc::new(json!({"sessionId": "a", "n": 9}))),
            json!({"sessionId": "a", "peer": "m"}),
        );
        assert_eq!(method_of(&msg), method::MUX_SESSION_CHANGED, "first sight of the peer's row");
    }

    /// The book holds at most `MAX_ROWS` rows.
    #[test]
    fn the_book_is_bounded() {
        let book = RowPatches::default();
        book.watch(true);
        for i in 0..MAX_ROWS + 10 {
            let id = format!("s{i}");
            book.notice(shared(json!({"sessionId": id})), json!({"sessionId": id}));
        }
        assert!(book.sent.lock_or_recover().len() <= MAX_ROWS);
    }
}
