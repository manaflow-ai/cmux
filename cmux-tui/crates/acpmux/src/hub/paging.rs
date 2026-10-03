//! Part of `Hub`; see `hub/mod.rs`. Cursor paging and kind filters over a
//! session's event log, shared by `_acpmux/events` and `_acpmux/attach`.

use super::*;

/// `session/update` kinds that carry no renderable transcript content.
const NON_TRANSCRIPT_UPDATES: &[&str] =
    &["usage_update", "available_commands_update", "current_mode_update", "config_option_update"];

/// Mux records a chat client renders. `turn_end` and `turn_error` are left
/// out because every turn also records `turn_result`.
pub const TRANSCRIPT_MUX_KINDS: &[&str] = &[
    "user_message",
    "queued",
    "dequeued",
    "turn_started",
    "turn_result",
    "permission_request",
    "permission_auto",
    "permission_decision",
    "permission_group",
    "permission_chat_allowance",
    "message_superseded",
    "failover",
    "forked",
    "imported",
    "mode",
    "model",
    "stopped",
    "exited",
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

/// Raw protocol traffic: requests, responses, replays and harness lines.
fn is_wire(rec: &EventRecord) -> bool {
    let live_update = is_agent_update(rec) && !rec.kind.ends_with(".replay");
    (rec.dir == "in" || rec.dir == "out") && !live_update
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
    /// `newest` picks the last `limit` of them instead of the first.
    pub fn events_page(
        &self,
        id: &str,
        after: u64,
        before: Option<u64>,
        limit: usize,
        newest: bool,
        filter: &EventFilter,
    ) -> Result<EventPage> {
        let before = before.unwrap_or(u64::MAX);
        let mut page = EventPage::default();
        if limit == 0 || !newest {
            let mut found = 0usize;
            self.store.scan(id, after, &mut |rec| {
                if rec.seq >= before {
                    return false;
                }
                if !filter.matches(&rec) {
                    return true;
                }
                if found == limit {
                    page.has_more = true;
                    return false;
                }
                found += 1;
                page.events.push(rec);
                true
            })?;
            return Ok(page);
        }
        let mut ring: std::collections::VecDeque<EventRecord> =
            std::collections::VecDeque::with_capacity(limit.min(4096));
        self.store.scan(id, after, &mut |rec| {
            if rec.seq >= before {
                return false;
            }
            if filter.matches(&rec) {
                if ring.len() == limit {
                    ring.pop_front();
                    page.has_more = true;
                }
                ring.push_back(rec);
            }
            true
        })?;
        page.events = ring.into();
        Ok(page)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rec(seq: u64, dir: &str, kind: &str, msg: Value) -> EventRecord {
        EventRecord { seq, at: 0, dir: dir.into(), kind: kind.into(), msg }
    }

    #[test]
    fn transcript_filter_keeps_renderable_records_only() {
        let update = |k: &str| json!({"method": "session/update", "params": {"update": {"sessionUpdate": k}}});
        let f = EventFilter::parse(Some(&json!(["transcript"]))).unwrap();
        assert!(f.matches(&rec(1, "in", "agent_message_chunk", update("agent_message_chunk"))));
        assert!(f.matches(&rec(2, "mux", "user_message", json!({}))));
        assert!(f.matches(&rec(3, "mux", "turn_result", json!({}))));
        assert!(!f.matches(&rec(
            4,
            "in",
            "agent_message_chunk.replay",
            update("agent_message_chunk")
        )));
        assert!(!f.matches(&rec(5, "in", "usage_update", update("usage_update"))));
        assert!(!f.matches(&rec(6, "out", "session/prompt", json!({"method": "session/prompt"}))));
        assert!(!f.matches(&rec(7, "in", "response", json!({"id": 1, "result": {}}))));
        assert!(!f.matches(&rec(8, "mux", "stderr", json!({}))));
        assert!(!f.matches(&rec(9, "mux", "turn_end", json!({}))));
        let wire = EventFilter::parse(Some(&json!(["wire", "stderr"]))).unwrap();
        assert!(wire.matches(&rec(
            6,
            "out",
            "session/prompt",
            json!({"method": "session/prompt"})
        )));
        assert!(wire.matches(&rec(8, "mux", "stderr", json!({}))));
        assert!(!wire.matches(&rec(1, "in", "agent_message_chunk", update("agent_message_chunk"))));
        assert!(EventFilter::parse(Some(&json!(7))).is_err());
        assert!(EventFilter::parse(None).unwrap().is_all());
    }
}
