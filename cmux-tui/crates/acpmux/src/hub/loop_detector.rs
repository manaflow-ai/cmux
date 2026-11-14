//! Bounded detection of repeated failed calls and an edit immediately undone.
//! Only tool metadata and terminal results are observed; token and output deltas do no work.

use serde_json::Value;
use std::collections::{VecDeque, hash_map::DefaultHasher};
use std::hash::{Hash, Hasher};

const WINDOW: usize = 8;
const PENDING: usize = 16;
const RECENT_IDS: usize = 16;
const MAX_ID: usize = 128;
const MAX_INPUT: usize = 4096;
const MAX_TITLE: usize = 160;
const MAX_ERROR: usize = 160;
const FAILURE_THRESHOLD: usize = 3;

#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct LoopEpisode {
    pub episode_id: u64,
    pub since: u64,
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
struct Edit {
    path: u64,
    before: u64,
    after: u64,
}

impl Edit {
    fn undoes(&self, other: &Self) -> bool {
        self.path == other.path && self.before == other.after && self.after == other.before
    }
}

#[derive(Clone, Debug, Default)]
enum Cwd {
    #[default]
    Unspecified,
    Known(u64),
    Invalid,
}

#[derive(Clone, Debug)]
struct Call {
    id: String,
    kind: String,
    cwd: Cwd,
    fingerprint: Option<u64>,
    title: String,
    edit: Option<Edit>,
}

impl Call {
    fn from_update(id: &str, update: &Value) -> Self {
        let mut call = Self {
            id: id.to_owned(),
            kind: String::new(),
            cwd: Cwd::Unspecified,
            fingerprint: None,
            title: String::new(),
            edit: None,
        };
        call.enrich(update);
        call
    }

    fn enrich(&mut self, update: &Value) {
        if let Some(kind) =
            update.get("kind").and_then(Value::as_str).filter(|kind| kind.len() <= 32)
        {
            self.kind = kind.to_owned();
        }
        if self.fingerprint.is_none()
            && let Some(title) = update.get("title").and_then(Value::as_str)
        {
            self.title = bounded_preview(title, MAX_TITLE);
        }
        if let Some(cwd) = update.pointer("/rawInput/cwd") {
            self.cwd = cwd.as_str().and_then(hash_bounded).map_or(Cwd::Invalid, Cwd::Known);
        }
        if update.pointer("/rawInput/command").is_some() {
            // A terminal update often repeats the command but omits its cwd. Keep the cwd
            // from the start; an overlarge or malformed command remains ineligible.
            self.fingerprint = fingerprint(update, &self.kind, &self.cwd);
            if let Some(command) = update.pointer("/rawInput/command").and_then(Value::as_str) {
                self.title = bounded_preview(command, MAX_TITLE);
            }
        }
        if let Some(edit) = edit(update, &self.kind) {
            self.edit = Some(edit);
        }
    }
}

#[derive(Clone, Debug)]
struct Attempt {
    fingerprint: Option<u64>,
    failed: bool,
    edit: Option<Edit>,
    error: Option<(u64, String)>,
}

#[derive(Debug, Default)]
pub(super) struct LoopDetector {
    pending: VecDeque<Call>,
    recent_ids: VecDeque<String>,
    attempts: VecDeque<Attempt>,
    episode: Option<LoopEpisode>,
    next_episode: u64,
}

impl LoopDetector {
    pub(super) fn reset(&mut self) {
        self.pending.clear();
        self.recent_ids.clear();
        self.attempts.clear();
        self.episode = None;
    }

    pub(super) fn active(&self) -> Option<&LoopEpisode> {
        self.episode.as_ref()
    }

    pub(super) fn observe(&mut self, update: &Value) -> Option<LoopEvent> {
        if !matches!(
            update.get("sessionUpdate").and_then(Value::as_str),
            Some("tool_call" | "tool_call_update")
        ) {
            return None;
        }
        let id = update
            .get("toolCallId")
            .and_then(Value::as_str)
            .filter(|id| !id.is_empty() && id.len() <= MAX_ID)?;
        let terminal =
            matches!(update.get("status").and_then(Value::as_str), Some("completed" | "failed"));
        // Output and title deltas can arrive per chunk. Only the initial call, raw input,
        // and actual diff content can change the metadata needed for detection.
        if !terminal
            && update.get("sessionUpdate").and_then(Value::as_str) == Some("tool_call_update")
            && update.get("rawInput").is_none()
            && !has_diff_content(update)
        {
            return None;
        }
        if self.recent_ids.iter().any(|recent| recent == id) {
            return None;
        }
        let index = self.pending.iter().position(|call| call.id == id);
        if !terminal {
            if let Some(index) = index {
                if let Some(call) = self.pending.get_mut(index) {
                    call.enrich(update);
                }
            } else {
                push_bounded(&mut self.pending, Call::from_update(id, update), PENDING);
            }
            return None;
        }
        let mut call = index
            .and_then(|index| self.pending.remove(index))
            .unwrap_or_else(|| Call::from_update(id, update));
        call.enrich(update);
        push_bounded(&mut self.recent_ids, id.to_owned(), RECENT_IDS);
        let failed = failed(update);
        let attempt = Attempt {
            fingerprint: call.fingerprint,
            failed,
            edit: if failed { None } else { call.edit },
            error: if failed { error(update) } else { None },
        };
        let inverse = attempt.edit.as_ref().is_some_and(|edit| {
            self.attempts
                .iter()
                .rev()
                .filter_map(|past| past.edit.as_ref())
                .find(|past| past.path == edit.path)
                .is_some_and(|past| edit.undoes(past))
        });
        // A successful call is progress unless it repeats an apply/undo cycle. Narration,
        // another failed call and output updates do not make a visible episode flicker.
        if self.episode.is_some() && !failed && !inverse {
            return self.clear_on_progress();
        }
        if !failed && !inverse {
            // Successful work breaks a run of failures. Keep only the successful edit so
            // an inverse edit after failed validation can still be recognized.
            self.attempts.clear();
        }
        push_bounded(&mut self.attempts, attempt.clone(), WINDOW);
        if self.episode.is_some() {
            return None;
        }
        let same: Vec<&Attempt> = if failed {
            attempt
                .fingerprint
                .into_iter()
                .flat_map(|key| {
                    self.attempts
                        .iter()
                        .filter(move |past| past.failed && past.fingerprint == Some(key))
                })
                .collect()
        } else {
            Vec::new()
        };
        if same.len() < FAILURE_THRESHOLD && !inverse {
            return None;
        }
        self.next_episode = self.next_episode.saturating_add(1);
        let count = if inverse { 2 } else { same.len() as u32 };
        let title = if call.title.is_empty() { "a tool".to_owned() } else { call.title };
        let diagnosis = if inverse {
            format!("Applied and reversed an edit to {title}.")
        } else {
            let common_error =
                same.first().and_then(|first| first.error.as_ref()).filter(|first| {
                    same.iter()
                        .all(|past| past.error.as_ref().is_some_and(|error| error.0 == first.0))
                });
            match common_error {
                Some((_, message)) => {
                    format!("Ran {title} {count} times; the same error repeated: {message}")
                }
                None => format!("Ran {title} {count} times; each attempt failed."),
            }
        };
        let episode = LoopEpisode {
            episode_id: self.next_episode,
            since: crate::store::now_ms(),
            count,
            hint: format!("Try a different approach to {title}."),
            diagnosis,
        };
        self.episode = Some(episode.clone());
        Some(LoopEvent::Detected(episode))
    }

    fn clear_on_progress(&mut self) -> Option<LoopEvent> {
        let episode_id = self.episode.take()?.episode_id;
        self.attempts.clear();
        Some(LoopEvent::Cleared { episode_id })
    }
}

fn push_bounded<T>(queue: &mut VecDeque<T>, value: T, limit: usize) {
    if queue.len() == limit {
        queue.pop_front();
    }
    queue.push_back(value);
}

fn failed(update: &Value) -> bool {
    update.get("status").and_then(Value::as_str) == Some("failed")
        || update
            .pointer("/rawOutput/exit_code")
            .and_then(Value::as_i64)
            .is_some_and(|code| code != 0)
}

fn fingerprint(update: &Value, kind: &str, cwd: &Cwd) -> Option<u64> {
    let command = update.pointer("/rawInput/command");
    let mut hasher = DefaultHasher::new();
    kind.hash(&mut hasher);
    match command {
        Some(Value::String(command)) => hash_bounded(command)?.hash(&mut hasher),
        Some(Value::Array(args)) if args.len() <= 64 => {
            for arg in args {
                hash_bounded(arg.as_str()?)?.hash(&mut hasher);
                0_u8.hash(&mut hasher);
            }
        }
        _ => return None,
    }
    // Delimit command from cwd and distinguish omitted cwd from an empty one.
    match cwd {
        Cwd::Unspecified => 0_u8.hash(&mut hasher),
        Cwd::Known(hash) => {
            1_u8.hash(&mut hasher);
            hash.hash(&mut hasher);
        }
        Cwd::Invalid => return None,
    }
    Some(hasher.finish())
}

fn edit(update: &Value, kind: &str) -> Option<Edit> {
    if kind != "edit" {
        return None;
    }
    let input = update.get("rawInput");
    let direct = input.and_then(|input| {
        Some((
            input.get("file_path").or_else(|| input.get("path"))?.as_str()?,
            input.get("old_string")?.as_str()?,
            input.get("new_string")?.as_str()?,
        ))
    });
    // A file-change call carries the actual hunk text as ACP diff content, while its
    // `rawInput.changes` contains only path and line counts. A single hunk can prove an inverse;
    // a multi-hunk change is left undiagnosed rather than guessing from the file name.
    let diff = update.get("content").and_then(Value::as_array).and_then(|blocks| {
        let [block] = blocks.as_slice() else { return None };
        if block.get("type").and_then(Value::as_str) != Some("diff") {
            return None;
        }
        Some((
            block.get("path")?.as_str()?,
            block.get("oldText")?.as_str()?,
            block.get("newText")?.as_str()?,
        ))
    });
    let (path, before, after) = direct.or(diff)?;
    // Reject oversize hunks before even comparing them: equality otherwise scans the
    // entire edit on this event, including an arbitrarily large unchanged file.
    if before.len() > MAX_INPUT || after.len() > MAX_INPUT || before == after {
        return None;
    }
    Some(Edit {
        path: hash_bounded(path)?,
        before: hash_bounded(before)?,
        after: hash_bounded(after)?,
    })
}

fn has_diff_content(update: &Value) -> bool {
    update
        .get("content")
        .and_then(Value::as_array)
        .is_some_and(|blocks| {
            matches!(blocks.as_slice(), [block] if block.get("type").and_then(Value::as_str) == Some("diff"))
        })
}

fn hash_bounded(text: &str) -> Option<u64> {
    if text.len() > MAX_INPUT {
        return None;
    }
    let mut hasher = DefaultHasher::new();
    text.hash(&mut hasher);
    Some(hasher.finish())
}

fn error(update: &Value) -> Option<(u64, String)> {
    let text = update
        .pointer("/rawOutput/stderr")
        .or_else(|| update.pointer("/rawOutput/error"))
        .or_else(|| update.pointer("/content/0/content/text"))?
        .as_str()?;
    let hash = hash_bounded(text)?;
    let first = text.lines().find(|line| !line.trim().is_empty())?;
    Some((hash, bounded_preview(first, MAX_ERROR)))
}

fn bounded_preview(text: &str, limit: usize) -> String {
    // Scan well past the display cut before masking: a secret crossing that cut must
    // disappear in full. The scan itself is bounded for a tool's large output.
    let head: String = text.chars().take(MAX_INPUT).collect();
    super::session::masked_preview(&head, limit)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn start(id: &str, command: &str) -> Value {
        json!({"sessionUpdate":"tool_call", "toolCallId":id, "kind":"execute",
               "title":command, "rawInput":{"command":command}, "status":"in_progress"})
    }

    fn end(id: &str, status: &str, error: &str) -> Value {
        json!({"sessionUpdate":"tool_call_update", "toolCallId":id,
               "status":status, "rawOutput":{"stderr":error}})
    }

    #[test]
    fn diagnosis_names_the_command_instead_of_a_generic_tool_title() {
        let mut detector = LoopDetector::default();
        for id in ["a", "b", "c"] {
            let mut update = start(id, "cargo test");
            update["title"] = json!("Bash");
            detector.observe(&update);
            let mut result = end(id, "failed", "auth.rs:88");
            result["title"] = json!("Bash");
            detector.observe(&result);
        }
        assert!(detector.active().unwrap().diagnosis.starts_with("Ran cargo test 3 times"));
    }

    #[test]
    fn partial_terminal_uses_start_cwd_for_failure_fingerprint() {
        let mut detector = LoopDetector::default();
        for (id, cwd) in [("a", "/repo/a"), ("b", "/repo/b"), ("c", "/repo/c")] {
            detector.observe(&json!({"sessionUpdate":"tool_call", "toolCallId":id,
                "kind":"execute", "title":"cargo test",
                "rawInput":{"command":"cargo test", "cwd":cwd}, "status":"in_progress"}));
            assert!(
                detector
                    .observe(&json!({"sessionUpdate":"tool_call_update",
                "toolCallId":id, "status":"failed",
                "rawInput":{"command":"cargo test"}}))
                    .is_none()
            );
        }
        assert!(detector.active().is_none());
        for (id, cwd) in [("d", "/repo/a"), ("e", "/repo/a")] {
            detector.observe(&json!({"sessionUpdate":"tool_call", "toolCallId":id,
                "kind":"execute", "title":"cargo test",
                "rawInput":{"command":"cargo test", "cwd":cwd}, "status":"in_progress"}));
            let event = detector.observe(&json!({"sessionUpdate":"tool_call_update",
                "toolCallId":id, "status":"failed",
                "rawInput":{"command":"cargo test"}}));
            assert_eq!(matches!(event, Some(LoopEvent::Detected(_))), id == "e");
        }
    }

    #[test]
    fn title_only_output_delta_preserves_started_metadata() {
        let mut detector = LoopDetector::default();
        detector.observe(&start("a", "cargo test"));
        detector.observe(&json!({"sessionUpdate":"tool_call_update", "toolCallId":"a",
            "title":"streaming output", "content":[{"type":"content", "content":{"type":"text", "text":"chunk"}}]}));
        assert_eq!(detector.pending[0].title, "cargo test");
        assert_eq!(
            detector.pending[0].fingerprint,
            fingerprint(&start("a", "cargo test"), "execute", &Cwd::Unspecified)
        );
    }

    #[test]
    fn command_and_cwd_boundaries_are_distinct() {
        let first = json!({"rawInput":{"command":"ab"}});
        let second = json!({"rawInput":{"command":"a"}});
        assert_ne!(
            fingerprint(&first, "execute", &Cwd::Known(hash_bounded("c").unwrap())),
            fingerprint(&second, "execute", &Cwd::Known(hash_bounded("bc").unwrap()))
        );
        assert_ne!(
            fingerprint(&first, "execute", &Cwd::Unspecified),
            fingerprint(&first, "execute", &Cwd::Known(hash_bounded("").unwrap()))
        );
    }

    #[test]
    fn quoted_command_and_directory_whitespace_are_significant() {
        let mut commands = LoopDetector::default();
        let mut directories = LoopDetector::default();
        for (id, spaces) in [("a", " "), ("b", "  "), ("c", "   ")] {
            commands.observe(&start(id, &format!("test 'a{spaces}b' = 'ab'")));
            assert!(commands.observe(&end(id, "failed", "comparison failed")).is_none());

            let mut update = start(id, "cargo test");
            update["rawInput"]["cwd"] = json!(format!("/repo/a{spaces}b"));
            directories.observe(&update);
            assert!(directories.observe(&end(id, "failed", "auth.rs:88")).is_none());
        }
        assert!(commands.active().is_none());
        assert!(directories.active().is_none());
    }
    #[test]
    fn recorded_shape_partial_updates_and_duplicate_terminals() {
        let mut detector = LoopDetector::default();
        let transcript = include_str!("../../tests/fixtures/looping-tool-updates.jsonl");
        let events: Vec<_> = transcript
            .lines()
            .map(|line| serde_json::from_str::<Value>(line).expect("fixture update"))
            .filter_map(|update| detector.observe(&update))
            .collect();
        let [LoopEvent::Detected(episode), LoopEvent::Cleared { episode_id }] = events.as_slice()
        else {
            panic!("expected one detected and one cleared event: {events:?}");
        };
        assert_eq!(episode.count, 3);
        assert!(episode.diagnosis.contains("auth.rs:88"));
        assert_eq!(*episode_id, episode.episode_id);
        assert!(detector.active().is_none());
    }

    #[test]
    fn inverse_edit_requires_actual_content() {
        let mut detector = LoopDetector::default();
        let edit = |id: &str, before: &str, after: &str| {
            json!({"sessionUpdate":"tool_call", "toolCallId":id,
            "kind":"edit", "title":"Edit auth.rs", "rawInput":{"file_path":"auth.rs",
            "old_string":before,"new_string":after}, "status":"completed"})
        };
        assert!(detector.observe(&edit("a", "old", "new")).is_none());
        assert!(detector.observe(&edit("b", "new", "other")).is_none());
        assert!(matches!(
            detector.observe(&edit("c", "other", "new")),
            Some(LoopEvent::Detected(_))
        ));
        assert!(detector.observe(&edit("d", "new", "other")).is_none());
    }

    #[test]
    fn recorded_file_change_diff_can_prove_inverse() {
        let mut detector = LoopDetector::default();
        let change = |detector: &mut LoopDetector, id: &str, before: &str, after: &str| {
            detector.observe(&json!({"sessionUpdate":"tool_call", "toolCallId":id,
                "kind":"edit", "title":"Edit auth.rs", "status":"in_progress"}));
            detector.observe(&json!({"sessionUpdate":"tool_call_update", "toolCallId":id,
                "status":"completed", "content":[{"type":"diff", "path":"auth.rs",
                    "oldText":before, "newText":after}]}))
        };
        assert!(change(&mut detector, "a", "old\n", "new\n").is_none());
        assert!(matches!(
            change(&mut detector, "b", "new\n", "old\n"),
            Some(LoopEvent::Detected(_))
        ));
    }

    #[test]
    fn recorded_edit_failed_validation_inverse_is_one_episode() {
        let mut detector = LoopDetector::default();
        let transcript = include_str!("../../tests/fixtures/edit-validation-revert.jsonl");
        let events: Vec<_> = transcript
            .lines()
            .map(|line| serde_json::from_str::<Value>(line).expect("fixture update"))
            .filter_map(|update| detector.observe(&update))
            .collect();
        let [LoopEvent::Detected(episode)] = events.as_slice() else {
            panic!("expected one edit loop episode: {events:?}");
        };
        assert_eq!(episode.count, 2);
        assert!(episode.diagnosis.contains("Edit auth.rs"));
    }

    #[test]
    fn successful_unrelated_tool_breaks_edit_history() {
        let mut detector = LoopDetector::default();
        let edit = |id: &str, before: &str, after: &str| {
            json!({"sessionUpdate":"tool_call", "toolCallId":id,
                "kind":"edit", "title":"Edit auth.rs", "status":"completed",
                "rawInput":{"file_path":"auth.rs", "old_string":before, "new_string":after}})
        };
        detector.observe(&edit("apply", "old", "new"));
        detector.observe(&end("validation", "failed", "auth.rs:88"));
        detector.observe(&json!({"sessionUpdate":"tool_call", "toolCallId":"progress",
            "kind":"execute", "title":"different command", "status":"completed",
            "rawInput":{"command":"different command"}}));
        assert!(detector.observe(&edit("revert", "new", "old")).is_none());
        assert!(detector.active().is_none());
    }

    #[test]
    fn partial_terminal_keeps_the_started_tool_kind() {
        let mut detector = LoopDetector::default();
        for (id, kind) in [("a", "execute"), ("b", "execute"), ("c", "other")] {
            detector.observe(&json!({"sessionUpdate":"tool_call", "toolCallId":id,
                "kind":kind, "title":"cargo test", "rawInput":{"command":"cargo test"},
                "status":"in_progress"}));
            assert!(
                detector
                    .observe(&json!({"sessionUpdate":"tool_call_update", "toolCallId":id,
                "status":"failed", "rawInput":{"command":"cargo test"}}))
                    .is_none()
            );
        }
        assert!(detector.active().is_none());
    }

    #[test]
    fn successful_call_breaks_the_failure_run_before_detection() {
        let mut detector = LoopDetector::default();
        for (id, status) in [
            ("a", "failed"),
            ("b", "completed"),
            ("c", "failed"),
            ("d", "completed"),
            ("e", "failed"),
        ] {
            detector.observe(&start(id, "cargo test"));
            assert!(
                detector
                    .observe(&json!({"sessionUpdate":"tool_call_update",
                "toolCallId":id, "status":status}))
                    .is_none()
            );
        }
        assert!(detector.active().is_none());
    }

    #[test]
    fn memory_is_bounded_and_oversize_input_is_ignored() {
        let mut detector = LoopDetector::default();
        for i in 0..100 {
            detector.observe(&start(&format!("pending-{i}"), "cargo test"));
        }
        assert_eq!(detector.pending.len(), PENDING);
        for i in 0..100 {
            let id = format!("done-{i}");
            detector.observe(&start(&id, &"x".repeat(MAX_INPUT + 1)));
            detector.observe(&end(&id, "failed", "error"));
        }
        assert_eq!(detector.recent_ids.len(), RECENT_IDS);
        assert_eq!(detector.attempts.len(), WINDOW);
        assert!(detector.active().is_none());
    }
}
