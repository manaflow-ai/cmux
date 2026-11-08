//! Bounded detection of an agent repeating the same unsuccessful tool attempt.
//!
//! This deliberately lives beside the stalled-turn detector.  Silence and a loop are
//! different episodes, but both are observations of the same live `session/update` stream.

use serde_json::{Map, Value};
use std::collections::VecDeque;

const WINDOW: usize = 8;
const FAILURE_THRESHOLD: u32 = 3;

#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct LoopEpisode {
    pub episode_id: u64,
    pub count: u32,
    pub diagnosis: String,
    pub hint: String,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) enum LoopEvent {
    Detected(LoopEpisode),
    Cleared { episode_id: u64 },
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct Attempt {
    fingerprint: String,
    failed: bool,
    edit_path: Option<String>,
    reverted: bool,
}

#[derive(Debug, Default)]
pub(super) struct LoopDetector {
    attempts: VecDeque<Attempt>,
    repeat: u32,
    episode: Option<LoopEpisode>,
    next_episode: u64,
}

impl LoopDetector {
    pub(super) fn reset(&mut self) {
        self.attempts.clear();
        self.repeat = 0;
        self.episode = None;
    }

    pub(super) fn active(&self) -> Option<&LoopEpisode> {
        self.episode.as_ref()
    }

    /// Observe one live update. Only completed or failed tool attempts enter the bounded
    /// history; model text, plans, and a new tool are progress that clears an episode.
    pub(super) fn observe(&mut self, update: &Value) -> Option<LoopEvent> {
        let kind = update.get("sessionUpdate").and_then(Value::as_str);
        if !matches!(kind, Some("tool_call" | "tool_call_update")) {
            return self.clear_on_progress();
        }
        let status = update.get("status").and_then(Value::as_str);
        if !matches!(status, Some("completed" | "failed")) {
            return None;
        }

        let attempt = Attempt {
            fingerprint: fingerprint(update),
            failed: failed(update),
            edit_path: edit_path(update),
            reverted: is_revert(update),
        };
        let same_failure = attempt.failed
            && self
                .attempts
                .back()
                .is_some_and(|last| last.failed && last.fingerprint == attempt.fingerprint);
        self.repeat = if same_failure { self.repeat.saturating_add(1) } else { 1 };
        let edit_reverted = attempt.reverted
            && attempt.edit_path.is_some()
            && self
                .attempts
                .back()
                .is_some_and(|last| !last.reverted && last.edit_path == attempt.edit_path);
        self.attempts.push_back(attempt.clone());
        while self.attempts.len() > WINDOW {
            self.attempts.pop_front();
        }

        if self.episode.is_some() {
            return None;
        }
        if self.repeat >= FAILURE_THRESHOLD || edit_reverted {
            self.next_episode = self.next_episode.saturating_add(1);
            let count = if edit_reverted { 2 } else { self.repeat };
            let title = display_title(update);
            let diagnosis = if edit_reverted {
                format!("Applied {title}, then reverted the same edit.")
            } else {
                format!("Ran {title} {count} times; the same error repeated each time.")
            };
            let episode = LoopEpisode {
                episode_id: self.next_episode,
                count,
                hint: format!("Try a different approach to {title}."),
                diagnosis,
            };
            self.episode = Some(episode.clone());
            return Some(LoopEvent::Detected(episode));
        }
        None
    }

    fn clear_on_progress(&mut self) -> Option<LoopEvent> {
        let episode_id = self.episode.take().map(|episode| episode.episode_id)?;
        self.attempts.clear();
        self.repeat = 0;
        Some(LoopEvent::Cleared { episode_id })
    }
}

fn failed(update: &Value) -> bool {
    update.get("status").and_then(Value::as_str) == Some("failed")
        || update
            .pointer("/rawOutput/exit_code")
            .and_then(Value::as_i64)
            .is_some_and(|code| code != 0)
}

fn display_title(update: &Value) -> String {
    update
        .get("title")
        .and_then(Value::as_str)
        .map(normalize_text)
        .filter(|title| !title.is_empty())
        .unwrap_or_else(|| update.get("kind").and_then(Value::as_str).unwrap_or("tool").to_owned())
}

fn edit_path(update: &Value) -> Option<String> {
    if update.get("kind").and_then(Value::as_str) != Some("edit") {
        return None;
    }
    update
        .pointer("/rawInput/file_path")
        .or_else(|| update.pointer("/rawInput/path"))
        .and_then(Value::as_str)
        .map(normalize_text)
}

fn is_revert(update: &Value) -> bool {
    update.pointer("/rawInput/reverted").and_then(Value::as_bool).unwrap_or(false)
        || update
            .get("title")
            .and_then(Value::as_str)
            .is_some_and(|title| title.to_ascii_lowercase().contains("revert"))
}

fn fingerprint(update: &Value) -> String {
    let mut stable = update.clone();
    if let Value::Object(object) = &mut stable {
        for key in ["toolCallId", "status", "content", "rawOutput", "_meta"] {
            object.remove(key);
        }
    }
    canonical(&stable).to_string()
}

fn canonical(value: &Value) -> Value {
    match value {
        Value::Object(object) => {
            let mut sorted = Map::new();
            let mut entries: Vec<_> = object.iter().collect();
            entries.sort_by(|(left, _), (right, _)| left.cmp(right));
            for (key, value) in entries {
                sorted.insert(key.clone(), canonical(value));
            }
            Value::Object(sorted)
        }
        Value::Array(values) => Value::Array(values.iter().map(canonical).collect()),
        Value::String(text) => Value::String(normalize_text(text)),
        other => other.clone(),
    }
}

fn normalize_text(text: &str) -> String {
    text.split_whitespace().collect::<Vec<_>>().join(" ")
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn failed(id: &str, title: &str) -> Value {
        json!({"sessionUpdate":"tool_call_update", "toolCallId":id,
               "status":"failed", "kind":"execute", "title":title,
               "rawInput":{"command":["cargo", "test"]},
               "rawOutput":{"exit_code":1}})
    }

    #[test]
    fn detects_three_normalized_failures_once() {
        let mut detector = LoopDetector::default();
        assert!(detector.observe(&failed("one", "cargo   test")).is_none());
        assert!(detector.observe(&failed("two", "cargo test")).is_none());
        let Some(LoopEvent::Detected(episode)) = detector.observe(&failed("three", "cargo test"))
        else {
            panic!("expected loop episode");
        };
        assert_eq!(episode.count, 3);
        assert!(detector.observe(&failed("four", "cargo test")).is_none());
    }

    #[test]
    fn progress_clears_episode_and_allows_a_new_one() {
        let mut detector = LoopDetector::default();
        for id in ["one", "two", "three"] {
            detector.observe(&failed(id, "cargo test"));
        }
        assert_eq!(
            detector.observe(&json!({"sessionUpdate":"agent_message_chunk"})),
            Some(LoopEvent::Cleared { episode_id: 1 })
        );
        assert!(detector.active().is_none());
    }

    #[test]
    fn edit_revert_is_an_episode() {
        let mut detector = LoopDetector::default();
        let edit = json!({"sessionUpdate":"tool_call_update", "status":"completed",
                          "kind":"edit", "title":"write auth.rs",
                          "rawInput":{"file_path":"auth.rs"}});
        let revert = json!({"sessionUpdate":"tool_call_update", "status":"completed",
                            "kind":"edit", "title":"revert auth.rs",
                            "rawInput":{"file_path":"auth.rs", "reverted":true}});
        assert!(detector.observe(&edit).is_none());
        assert!(matches!(detector.observe(&revert), Some(LoopEvent::Detected(_))));
    }
}
