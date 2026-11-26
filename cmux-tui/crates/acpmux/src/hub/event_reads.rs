//! Part of `Hub`; see `hub/mod.rs`. Reads of a session's stored history: `history`, its newest
//! turn result, and the event log's pages, scans and newest window.

use super::*;

impl Hub {
    /// `_acpmux/session_search`: the session's messages that match `query`, newest first.
    pub fn session_search(
        &self,
        id: &str,
        query: &crate::session_search::Query,
    ) -> Result<Value, RpcError> {
        crate::session_search::search(self.store.as_ref(), id, query)
            .map_err(|e| RpcError::internal(format!("the session's log could not be read: {e}")))
    }

    /// Turn-by-turn summary from the event log.
    pub fn history(&self, session: &Session, limit: usize) -> Vec<Value> {
        // Only the kinds a summary reads are parsed, one record at a time: the whole log
        // as records grew the daemon by 347 MB for a 70 MB Chief log (perf100, rbx).
        const KINDS: &[&str] = &[
            "user_message",
            "tool_call",
            "permission_request",
            "permission_auto",
            "usage_update",
            "turn_result",
            "turn_end",
            "turn_error",
        ];
        let kinds: Vec<&str> = KINDS.iter().chain(history_timing::KINDS).copied().collect();
        let mut timing = history_timing::Timing::default();
        let mut turns: Vec<Value> = Vec::new();
        let mut cur: Option<serde_json::Map<String, Value>> = None;
        let _ = self.scan_kinds_off(&session.id, &kinds, &mut |e: EventRecord| {
            let mut opened = false;
            match e.kind.as_str() {
                "user_message" if e.msg.get("steer").and_then(Value::as_bool) != Some(true) => {
                    if let Some(t) = cur.take() {
                        turns.push(Value::Object(t));
                    }
                    let mut t = serde_json::Map::new();
                    t.insert("seq".into(), json!(e.seq));
                    t.insert("startedAt".into(), json!(e.at));
                    t.insert(
                        "prompt".into(),
                        json!(short_text(
                            e.msg.get("text").and_then(Value::as_str).unwrap_or(""),
                            120
                        )),
                    );
                    t.insert("toolCalls".into(), json!(0));
                    t.insert("permissions".into(), json!(0));
                    t.insert("status".into(), json!("running"));
                    cur = Some(t);
                    opened = true;
                }
                "tool_call" => {
                    if let Some(t) = cur.as_mut() {
                        let n = t.get("toolCalls").and_then(Value::as_u64).unwrap_or(0);
                        t.insert("toolCalls".into(), json!(n + 1));
                    }
                }
                "permission_request" | "permission_auto" => {
                    if let Some(t) = cur.as_mut() {
                        let n = t.get("permissions").and_then(Value::as_u64).unwrap_or(0);
                        t.insert("permissions".into(), json!(n + 1));
                    }
                }
                "usage_update" => {
                    if let Some(t) = cur.as_mut()
                        && let Some(u) =
                            e.msg.pointer("/params/update/used").and_then(Value::as_u64)
                    {
                        t.insert("tokens".into(), json!(u));
                    }
                }
                "turn_result" => {
                    if let Some(t) = cur.as_mut() {
                        if let Some(id) = e.msg.get("turnId") {
                            t.insert("turnId".into(), id.clone());
                        }
                        t.insert(
                            "status".into(),
                            e.msg.get("status").cloned().unwrap_or(json!("completed")),
                        );
                        t.insert(
                            "stopReason".into(),
                            e.msg.get("stopReason").cloned().unwrap_or(Value::Null),
                        );
                        t.insert("endedAt".into(), json!(e.at));
                        let started = t.get("startedAt").and_then(Value::as_u64).unwrap_or(e.at);
                        t.insert("wallMs".into(), json!(e.at.saturating_sub(started)));
                        if let Some(err) = e.msg.get("error") {
                            t.insert("error".into(), err.clone());
                        }
                        // Why a failed turn ended with no answer (`outcome_unknown`: a daemon
                        // restart cut it short), so a reader tells that from an agent error.
                        if let Some(detail) = e.msg.get("detail") {
                            t.insert("detail".into(), detail.clone());
                        }
                    }
                }
                "turn_end" | "turn_error" => {
                    // Older logs without turn_result.
                    if let Some(t) = cur.as_mut()
                        && t.get("endedAt").is_none()
                    {
                        let failed = e.kind == "turn_error";
                        t.insert(
                            "status".into(),
                            json!(if failed { "failed" } else { "completed" }),
                        );
                        t.insert(
                            "stopReason".into(),
                            e.msg.get("stopReason").cloned().unwrap_or(Value::Null),
                        );
                        t.insert("endedAt".into(), json!(e.at));
                        let started = t.get("startedAt").and_then(Value::as_u64).unwrap_or(e.at);
                        t.insert("wallMs".into(), json!(e.at.saturating_sub(started)));
                    }
                }
                _ => {}
            }
            timing.note(&e, cur.as_mut(), opened);
            true
        });
        if let Some(t) = cur.take() {
            turns.push(Value::Object(t));
        }
        let n = turns.len();
        turns.into_iter().skip(n.saturating_sub(limit)).collect()
    }

    /// The seq of the log's last `turn_result`; only those records are parsed.
    pub(crate) fn latest_turn_result(&self, id: &str) -> Result<Option<u64>, RpcError> {
        let mut latest = None;
        self.store
            .scan_kinds(id, &["turn_result"], &mut |e: EventRecord| {
                latest = latest.max(Some(e.seq));
                true
            })
            .map_err(|e| RpcError::internal(e.to_string()))?;
        Ok(latest)
    }

    pub fn events(&self, id: &str, after: u64, limit: usize) -> Result<Vec<EventRecord>> {
        self.warm_chat_id(id);
        self.store.events(id, after, limit)
    }

    /// Visits the records past `after` in order, one at a time, until `visit` returns false. A
    /// caller sends each record as it reads it (`session/load`'s replay), so the visit stops at
    /// the chat's `last_seq` read first: a line the log holds before its journal record is
    /// appended (R-DURABILITY S2c) is never sent ahead of that record. A chat no session holds
    /// takes no appends: read to the end.
    pub fn scan_events(
        &self,
        id: &str,
        after: u64,
        visit: &mut dyn FnMut(EventRecord) -> bool,
    ) -> Result<()> {
        // An evicted chat comes back first (`evict.rs`): its log may be cold-archived.
        let live = self.session_get(id);
        let Some(session) = live else {
            return self.store.scan(id, after, visit);
        };
        // A cold-archived chat's log comes back first, and its preview goes (`cold_archive.rs`).
        self.warm_chat(&session);
        // After a hard stop the log can be ahead of the saved `lastSeq`, until the chat's log is
        // loaded (`load_logs`, after the daemon's ready line) or its first append: its tail is
        // counted first, so the cap below leaves out only a line whose record is not appended
        // yet. A caught-up chat takes no lock here (a replay never waits for an append).
        self.catch_up_tail(&session);
        let last = session.meta().last_seq;
        #[cfg(test)]
        log_load::catch_up_note(&log_load::NOTE_BEFORE_REPLAY_SCAN, "scans the log");
        self.store.scan(id, after, &mut |record| record.seq <= last && visit(record))
    }

    /// Where a replay of chat `id`'s newest `n` records starts ([`crate::store::NewestWindow`]),
    /// read up to the same `last_seq` [`Self::scan_events`] stops at: `scan_events` from its
    /// `after` sends those `n` and the few appended since. Costs `n` line heads read back from
    /// the end however long the log is.
    pub fn newest_window(&self, id: &str, n: u64) -> Result<crate::store::NewestWindow> {
        let live = self.session_get(id);
        let Some(session) = live else { return self.store.newest_window(id, u64::MAX, n) };
        self.warm_chat(&session);
        self.catch_up_tail(&session);
        let last = session.meta().last_seq;
        self.store.newest_window(id, last.saturating_add(1), n)
    }

    /// Counts `session`'s log tail past its saved `lastSeq` if no one has yet ([`Self::catch_up`]):
    /// a read that compares a client's cursor with `lastSeq` (`_acpmux/events`) reads it after
    /// this, or after a hard stop it refuses the records the log holds and the saved session does
    /// not (`cursor_future`) until the chat's log loads. A caught-up chat takes no lock.
    pub(crate) fn catch_up_tail(&self, session: &Session) {
        if !session.caught_up.load(Ordering::SeqCst) {
            self.catch_up(session);
        }
    }

    pub fn session_dir(&self, id: &str) -> Option<PathBuf> {
        self.store.session_dir(id)
    }
}
