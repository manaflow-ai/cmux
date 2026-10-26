//! The answers a chat's permission asks got, kept a short while by permission id: the first
//! answer wins (`permissions.rs` `respond_permission`), and a later one gets `not_found` with
//! `data {answeredBy, outcome}`, so its pane shows "Answered by Ana" instead of an error
//! (chat multiplayer, `author.rs`). `answeredBy` is null when the owner (no author) answered, or
//! no one did (a cancel).
//!
//! No timer: an answer is dropped once it is older than [`KEEP`] (checked at every remember and
//! read), past the newest [`MAX`] of its chat, and with the chat.

use serde_json::{Value, json};
use std::collections::VecDeque;
use std::time::{Duration, Instant};

/// How long a settled answer is told to a later one.
pub(crate) const KEEP: Duration = Duration::from_secs(10 * 60);
/// At most this many settled answers per chat.
pub(crate) const MAX: usize = 64;

#[derive(Debug, Default)]
pub(crate) struct Settled(VecDeque<(String, Instant, Value)>);

impl Settled {
    /// `id` was answered `outcome` (the agent's, its `_meta` and slots dropped) by `answered_by`.
    pub(crate) fn remember(&mut self, id: &str, answered_by: Option<&Value>, outcome: &Value) {
        self.remember_at(Instant::now(), id, answered_by, outcome);
    }

    fn remember_at(&mut self, now: Instant, id: &str, by: Option<&Value>, outcome: &Value) {
        self.0.retain(|(other, at, _)| other != id && now.duration_since(*at) < KEEP);
        while self.0.len() >= MAX {
            self.0.pop_front();
        }
        let mut outcome = outcome.clone();
        if let Some(fields) = outcome.as_object_mut() {
            fields.retain(|k, _| !k.starts_with('_'));
        }
        let data = json!({"answeredBy": by.cloned().unwrap_or(Value::Null), "outcome": outcome});
        self.0.push_back((id.to_owned(), now, data));
    }

    /// What a losing answer to `id` is told, while it is kept.
    pub(crate) fn lost(&self, id: &str) -> Option<Value> {
        self.lost_at(Instant::now(), id)
    }

    fn lost_at(&self, now: Instant, id: &str) -> Option<Value> {
        let (_, at, data) = self.0.iter().rev().find(|(other, ..)| other == id)?;
        (now.duration_since(*at) < KEEP).then(|| data.clone())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_settled_answer_is_told_for_a_while_and_the_store_stays_bounded() {
        let mut s = Settled::default();
        let t0 = Instant::now();
        let by = json!({"id": "tailnet:ana", "name": "Ana"});
        let outcome =
            json!({"outcome": "selected", "optionId": "yes", "_meta": {"updatedInput": {}}});
        s.remember_at(t0, "p-1", Some(&by), &outcome);
        let told = s.lost_at(t0, "p-1").unwrap();
        assert_eq!(
            told,
            json!({"answeredBy": by, "outcome": {"outcome": "selected", "optionId": "yes"}})
        );
        assert_eq!(s.lost_at(t0 + KEEP, "p-1"), None, "kept past KEEP");
        s.remember_at(t0, "p-2", None, &json!({"outcome": "cancelled"}));
        assert_eq!(s.lost_at(t0, "p-2").unwrap()["answeredBy"], Value::Null);
        for i in 0..(MAX * 2) {
            s.remember_at(t0, &format!("q-{i}"), None, &json!({"outcome": "cancelled"}));
        }
        assert_eq!(s.0.len(), MAX);
        // A remember drops what expired.
        s.remember_at(t0 + KEEP, "late", None, &json!({}));
        assert_eq!(s.0.len(), 1);
    }
}
