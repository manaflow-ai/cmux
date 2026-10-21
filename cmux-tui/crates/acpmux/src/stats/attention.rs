//! What asked for the person's attention (hq#1920): how long permission
//! questions waited for an answer, and how often an account hit its limit.
//! Part of one session's fold (`super::SessionFold`).

use crate::store::EventRecord;
use serde_json::Value;
use std::collections::HashMap;

#[derive(Default)]
pub(super) struct Attention {
    /// Questions asked in the range and not answered yet, by permission id,
    /// with when they were asked.
    open: HashMap<String, u64>,
    /// Asked in the range without an id, or under an id asked again: never
    /// matched to an answer.
    unmatched: u64,
    pub answered: u64,
    pub wait_ms: u64,
    pub wait_max_ms: u64,
    pub limit_errors: u64,
}

impl Attention {
    /// One `dir: mux` record at `at`; `in_range` says whether `at` is in
    /// the requested range.
    pub fn record(&mut self, record: &EventRecord, in_range: bool) {
        let id = || record.msg.get("permissionId").and_then(Value::as_str);
        match record.kind.as_str() {
            "permission_request" if in_range => match id() {
                // An id asked twice: the earlier ask is never answered.
                Some(id) => {
                    if self.open.insert(id.to_owned(), record.at).is_some() {
                        self.unmatched += 1;
                    }
                }
                None => self.unmatched += 1,
            },
            // A reissued question keeps its id: the wait runs from the first
            // ask. A decision after the range leaves it open as of the range.
            "permission_decision" if in_range => {
                if let Some(asked) = id().and_then(|id| self.open.remove(id)) {
                    let wait = record.at.saturating_sub(asked);
                    self.answered += 1;
                    self.wait_ms += wait;
                    self.wait_max_ms = self.wait_max_ms.max(wait);
                }
            }
            // Every failed turn writes `turn_error` (older logs only it), so
            // it counts the turn once; a failover is a limit the fallback
            // carried the turn past.
            "turn_error" if in_range => self.limit_hit(record.msg.get("error")),
            "failover" if in_range => self.limit_hit(record.msg.get("reason")),
            _ => {}
        }
    }

    fn limit_hit(&mut self, message: Option<&Value>) {
        if message.and_then(Value::as_str).is_some_and(crate::hub::is_limit_error) {
            self.limit_errors += 1;
        }
    }

    /// Questions asked in the range with no answer in it: still open, or
    /// lost when the daemon that asked died.
    pub fn unanswered(&self) -> u64 {
        self.open.len() as u64 + self.unmatched
    }
}
