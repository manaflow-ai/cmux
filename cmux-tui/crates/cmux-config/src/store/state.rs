//! The owner's in-memory state and its derived effective settings.

use serde_json::{Map, Value};

use super::replay::ReplayLog;
use super::{Applied, Change, Origin, Outcome, diff};
use crate::diagnostics::{Diagnostic, DiagnosticKind};
use crate::domains::Domains;
use crate::effective::EffectiveSettings;
use crate::jsonc;
use crate::managed::{ManagedPreferences, TeamPolicyLayer};
use crate::render::compact;
use crate::schema::{Schema, accepts};
use crate::value::value_at;

/// What reading cmux.json gave: its text (`""` for a missing file), or why
/// it could not be read.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FileRead {
    Text(String),
    Unreadable(String),
}

#[derive(Debug, Clone)]
pub struct State {
    pub(crate) schema: &'static Schema,
    /// The file text as last read or written.
    pub(crate) source: String,
    /// The last document that parsed (applies while the file is broken).
    pub(crate) file_root: Value,
    /// Why the current file text does not parse, if it does not.
    pub(crate) file_problem: Option<String>,
    pub(crate) managed: ManagedPreferences,
    pub(crate) team: TeamPolicyLayer,
    pub(crate) domains: Domains,
    pub(crate) revision: u64,
    pub(crate) effective: EffectiveSettings,
    pub(crate) replay: ReplayLog,
}

impl State {
    /// A state for `file` with the given inputs, at `revision`.
    pub fn new(
        schema: &'static Schema,
        file: FileRead,
        managed: ManagedPreferences,
        team: TeamPolicyLayer,
        domains: Domains,
        revision: u64,
    ) -> State {
        let empty = Value::Object(Map::new());
        let effective = EffectiveSettings::merge(&empty, &managed, &team, schema);
        let mut state = State {
            schema,
            source: String::new(),
            file_root: empty,
            file_problem: None,
            managed,
            team,
            domains,
            revision,
            effective,
            replay: ReplayLog::default(),
        };
        state.read_file(file);
        state.recompute();
        state
    }

    pub fn revision(&self) -> u64 {
        self.revision
    }
    pub fn schema(&self) -> &'static Schema {
        self.schema
    }
    pub fn source(&self) -> &str {
        &self.source
    }
    pub fn effective(&self) -> &EffectiveSettings {
        &self.effective
    }
    pub fn managed(&self) -> &ManagedPreferences {
        &self.managed
    }
    pub fn team(&self) -> &TeamPolicyLayer {
        &self.team
    }
    pub fn domains(&self) -> &Domains {
        &self.domains
    }
    pub fn file_problem(&self) -> Option<&str> {
        self.file_problem.as_deref()
    }
    /// Idempotency records held (at most `REPLAY_CAPACITY`).
    pub fn replay_len(&self) -> usize {
        self.replay.len()
    }

    pub(crate) fn with_revision(mut self, revision: u64) -> State {
        self.revision = revision;
        self
    }

    /// The state after an external change of the file or the managed
    /// values (watcher, write-time refresh). Bumps the revision and returns
    /// a change only when something visible changed (a comment-only edit
    /// changes nothing).
    pub fn reload(&self, file: FileRead, managed: ManagedPreferences) -> (State, Option<Change>) {
        let mut next = self.clone();
        next.read_file(file);
        next.managed = managed;
        next.recompute();
        let applied = finish(self, next, Origin::File);
        (applied.state, applied.changes.into_iter().next())
    }

    /// Adopts a file read: a parsing object becomes the file root; anything
    /// else keeps the last good root and records the problem.
    pub(crate) fn read_file(&mut self, file: FileRead) {
        match file {
            FileRead::Text(text) => {
                match jsonc::parse(&text) {
                    Ok(root @ Value::Object(_)) => {
                        self.file_root = root;
                        self.file_problem = None;
                    }
                    Ok(_) => self.file_problem = Some("root is not an object".to_string()),
                    Err(error) => self.file_problem = Some(error.to_string()),
                }
                self.source = text;
            }
            FileRead::Unreadable(message) => {
                self.source = String::new();
                self.file_problem = Some(message);
            }
        }
    }

    /// Re-derives the effective settings and diagnostics from the inputs.
    pub(crate) fn recompute(&mut self) {
        let mut effective =
            EffectiveSettings::merge(&self.file_root, &self.managed, &self.team, self.schema);
        let mut diagnostics = Vec::new();
        if let Some(problem) = &self.file_problem {
            diagnostics.push(Diagnostic::new(DiagnosticKind::UnreadableFile, "", problem));
        }
        diagnostics.append(&mut effective.diagnostics);
        for row in &self.schema.rows {
            if let Some(stored) = value_at(&effective.root, &row.path)
                && accepts(row, stored, &self.domains).is_err()
            {
                let message = format!("{} does not accept {}", row.key, compact(stored));
                diagnostics.push(Diagnostic::new(DiagnosticKind::InvalidValue, &row.key, &message));
            }
        }
        effective.diagnostics = diagnostics;
        self.effective = effective;
    }

    /// Whether a client could see a difference between `self` and `other`.
    fn visibly_differs(&self, other: &State) -> bool {
        self.effective != other.effective
    }
}

/// Bumps the revision of `next` once when it differs visibly from `previous`.
pub(super) fn finish(previous: &State, mut next: State, origin: Origin) -> Applied {
    if !previous.visibly_differs(&next) {
        let outcome = Outcome { revision: next.revision, keys: Vec::new(), replayed: false };
        return Applied { state: next, changes: Vec::new(), outcome, write: None };
    }
    next.revision = previous.revision + 1;
    let keys = diff::changed_keys(&previous.effective, &next.effective);
    let change = Change { revision: next.revision, keys: keys.clone(), origin };
    let outcome = Outcome { revision: next.revision, keys, replayed: false };
    Applied { state: next, changes: vec![change], outcome, write: None }
}
