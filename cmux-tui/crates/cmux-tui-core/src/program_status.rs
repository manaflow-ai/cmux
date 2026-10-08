//! Per-terminal program status records (OSC 7501, decision
//! OSC-7501-PROGRAM-STATUS).
//!
//! libghostty-vt parses and validates the reports and keeps nothing; the
//! session host keeps one record per id here and applies the specification's
//! lifetime rules (https://mitchellh.com/writing/program-status-osc7501):
//! a report replaces its record, `clear` removes a record and its
//! descendants, a primary prompt start removes `working`, `blocked` and
//! `idle`, the process exit hides them, and at most [`MAX_RECORDS`] records
//! stay (the one updated longest ago goes first). `done` and `error` stay
//! until the program replaces or clears them; "seen" is client view state,
//! keyed by `updated_seq`.
//!
//! Text is untrusted program output: display only, never interpreted.
//! libghostty already removed control characters; this module also removes
//! invisible formatting characters (bidi overrides, zero-width characters)
//! and caps the length, so a record cannot hide or reorder text when a
//! client shows it outside the terminal.

use std::collections::BTreeMap;
use std::sync::{Arc, Mutex};

use ghostty_vt::{ProgramStatusEvent, ProgramStatusKind, ProgramStatusReport, ProgramStatusState};
use serde_json::{Value, json};

/// Records kept per terminal. The specification asks for at most 256 and at
/// least 64.
pub(crate) const MAX_RECORDS: usize = 256;
/// Shown text bounds, the same as terminal notifications.
pub(crate) const MAX_TITLE_CHARS: usize = 256;
pub(crate) const MAX_MESSAGE_CHARS: usize = 1024;

/// One kept record. `state` is never `Clear`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct ProgramStatusRecord {
    pub(crate) state: ProgramStatusState,
    pub(crate) kind: Option<ProgramStatusKind>,
    pub(crate) progress: Option<u8>,
    pub(crate) app: Option<String>,
    pub(crate) title: Option<String>,
    pub(crate) message: Option<String>,
    pub(crate) updated_seq: u64,
    pub(crate) updated_at_ms: u64,
}

impl ProgramStatusRecord {
    /// Whether the record ends at a new prompt or when the process exits.
    fn is_transient(&self) -> bool {
        matches!(
            self.state,
            ProgramStatusState::Working | ProgramStatusState::Blocked | ProgramStatusState::Idle
        )
    }

    fn to_json(&self, id: &str) -> Value {
        json!({
            "id": id,
            "state": self.state.as_str(),
            "progress": self.progress,
            "kind": self.kind.map(ProgramStatusKind::as_str),
            "app": self.app,
            "title": self.title,
            "msg": self.message,
            "updated_seq": self.updated_seq.to_string(),
            "updated_at_ms": self.updated_at_ms.to_string(),
        })
    }
}

/// The records of one terminal, keyed by record id (`""` is the root).
#[derive(Debug, Default)]
pub(crate) struct ProgramStatusRecords {
    records: BTreeMap<String, ProgramStatusRecord>,
    next_seq: u64,
    /// Bumped on every visible change; `published` is the value last handed
    /// to the public graph.
    revision: u64,
    published: u64,
}

impl ProgramStatusRecords {
    /// Applies one event from the terminal's parser at `now_ms`.
    pub(crate) fn apply(&mut self, event: ProgramStatusEvent, now_ms: u64) {
        match event {
            ProgramStatusEvent::PromptStart => self.end_transient(),
            ProgramStatusEvent::Report(report) => self.apply_report(report, now_ms),
        }
    }

    fn apply_report(&mut self, report: ProgramStatusReport, now_ms: u64) {
        let ProgramStatusReport { state, kind, progress, id, app, title, message } = report;
        if state == ProgramStatusState::Clear {
            let before = self.records.len();
            if id.is_empty() {
                self.records.clear();
            } else {
                let prefix = format!("{id}/");
                self.records.retain(|key, _| key != &id && !key.starts_with(&prefix));
            }
            if self.records.len() != before {
                self.revision += 1;
            }
            return;
        }
        if !self.records.contains_key(&id) && self.records.len() >= MAX_RECORDS {
            let oldest = self
                .records
                .iter()
                .min_by_key(|(_, record)| record.updated_seq)
                .map(|(key, _)| key.clone());
            if let Some(oldest) = oldest {
                self.records.remove(&oldest);
            }
        }
        self.next_seq += 1;
        let blocked = state == ProgramStatusState::Blocked;
        let shows_progress = blocked || state == ProgramStatusState::Working;
        let record = ProgramStatusRecord {
            state,
            kind: kind.filter(|_| blocked),
            progress: progress.filter(|value| shows_progress && *value <= 100),
            app: non_empty(shown_text(&app, MAX_TITLE_CHARS)),
            title: non_empty(shown_text(&title, MAX_TITLE_CHARS)),
            message: non_empty(shown_text(&message, MAX_MESSAGE_CHARS)),
            updated_seq: self.next_seq,
            updated_at_ms: now_ms,
        };
        self.records.insert(id, record);
        self.revision += 1;
    }

    /// A primary prompt started: the program that reported `working`,
    /// `blocked` or `idle` is no longer in the foreground.
    pub(crate) fn end_transient(&mut self) {
        let before = self.records.len();
        self.records.retain(|_, record| !record.is_transient());
        if self.records.len() != before {
            self.revision += 1;
        }
    }

    #[cfg(test)]
    pub(crate) fn is_empty(&self) -> bool {
        self.records.is_empty()
    }

    #[cfg(test)]
    pub(crate) fn get(&self, id: &str) -> Option<&ProgramStatusRecord> {
        self.records.get(id)
    }

    #[cfg(test)]
    pub(crate) fn len(&self) -> usize {
        self.records.len()
    }

    /// The public value (`extra.program_status`): records sorted by id.
    /// `running` false hides transient records, as at process exit. `None`
    /// when nothing is shown.
    pub(crate) fn to_json(&self, running: bool) -> Option<Value> {
        let records = self
            .records
            .iter()
            .filter(|(_, record)| running || !record.is_transient())
            .map(|(id, record)| record.to_json(id))
            .collect::<Vec<_>>();
        (!records.is_empty()).then_some(Value::Array(records))
    }

    /// True once per visible change, marking it published.
    pub(crate) fn take_change(&mut self) -> bool {
        let changed = self.revision != self.published;
        self.published = self.revision;
        changed
    }
}

/// The records shared by a terminal's parser callback (inside `vt_write`)
/// and the publisher. The callback never takes the terminal lock, so the
/// order is always terminal lock, then this lock.
pub(crate) type SharedProgramStatus = Arc<Mutex<ProgramStatusRecords>>;

/// The parser callback that feeds `records`.
pub(crate) fn sink(records: SharedProgramStatus) -> ghostty_vt::ProgramStatusFn {
    Box::new(move |event| {
        records
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .apply(event, crate::mux::now_ms());
    })
}

/// The callback of a terminal host's own parser. The host keeps no records
/// (the daemon's mirror does), but libghostty answers the `OSC 7501 ; ?`
/// support query only while a callback is set, and only the authoritative
/// parser may answer.
#[cfg_attr(not(unix), allow(dead_code))]
pub(crate) fn query_only_sink() -> ghostty_vt::ProgramStatusFn {
    Box::new(|_| {})
}

fn non_empty(text: String) -> Option<String> {
    (!text.is_empty()).then_some(text)
}

/// Untrusted text as shown outside the terminal: no control characters, no
/// invisible formatting characters, at most `limit` characters.
pub(crate) fn shown_text(text: &str, limit: usize) -> String {
    text.chars()
        .filter(|character| !character.is_control() && !is_invisible_format(*character))
        .take(limit)
        .collect()
}

/// Bidi controls, zero-width characters, word joiners, invisible operators,
/// the BOM and interlinear annotation marks (Unicode Cf characters that can
/// hide or reorder shown text).
fn is_invisible_format(character: char) -> bool {
    matches!(
        character,
        '\u{00AD}'
            | '\u{061C}'
            | '\u{180E}'
            | '\u{200B}'..='\u{200F}'
            | '\u{202A}'..='\u{202E}'
            | '\u{2060}'..='\u{2064}'
            | '\u{2066}'..='\u{206F}'
            | '\u{FEFF}'
            | '\u{FFF9}'..='\u{FFFB}'
    )
}

#[cfg(test)]
#[path = "program_status_tests.rs"]
mod tests;
