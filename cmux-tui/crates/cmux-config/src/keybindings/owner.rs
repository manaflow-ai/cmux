//! The keybindings.json owner with IO (K-T6): the single writer of the file
//! beside the settings file. Like the settings owner it re-reads the file
//! under the advisory lock before every edit (a hand edit the watcher has
//! not reported yet is never lost), edits it in place ([`super::edit`]) and
//! publishes atomically. A revision counts every change the owner saw, its
//! own writes and the file's. An idempotency key replays its committed
//! outcome (a retried append never writes twice) while this daemon runs.

use std::collections::{HashMap, VecDeque};
use std::path::{Path, PathBuf};

use serde_json::Value;

use super::edit::{self, EditError, Target};
use super::{Parsed, parse};
use crate::fsio::{publish, read_source, resolve_symlinks};
use crate::owner::lock_config;
use crate::store::{FileRead, Origin};

/// One edit of the Keyboard Shortcuts page (or the CLI).
#[derive(Debug, Clone)]
pub enum KeybindingsOp {
    /// Binds `binding` with `args`; with `replaces`, that binding goes.
    Set { binding: Target, args: Option<Value>, replaces: Option<Target> },
    /// Unbinds one binding of a command.
    Remove { target: Target },
    /// Drops every entry and removal of `command`: its defaults return.
    Reset { command: String },
}

/// Why an edit was refused; the file is unchanged.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum KeybindingsRefusal {
    /// A key that keybindings.json cannot hold (syntax, more than four
    /// strokes, a first stroke without cmd or ctrl).
    Invalid(String),
    /// The file is not a readable JSONC array: fix it by hand first.
    Unreadable(String),
    Io(String),
    /// The idempotency key committed another op (`committed`, its wire name).
    IdempotencyConflict {
        key: String,
        committed: &'static str,
    },
}

impl KeybindingsRefusal {
    pub fn code(&self) -> &'static str {
        match self {
            KeybindingsRefusal::Invalid(_) => "keybindings.invalid",
            KeybindingsRefusal::Unreadable(_) => "keybindings.unreadable",
            KeybindingsRefusal::Io(_) => "keybindings.io",
            KeybindingsRefusal::IdempotencyConflict { .. } => "idempotency.conflict",
        }
    }

    pub fn message(&self) -> &str {
        match self {
            KeybindingsRefusal::Invalid(message)
            | KeybindingsRefusal::Unreadable(message)
            | KeybindingsRefusal::Io(message) => message,
            KeybindingsRefusal::IdempotencyConflict { .. } => {
                "the idempotency key committed another keybindings op"
            }
        }
    }
}

impl From<EditError> for KeybindingsRefusal {
    fn from(error: EditError) -> Self {
        match error {
            EditError::InvalidKey(message) => KeybindingsRefusal::Invalid(message),
            EditError::Unreadable(message) => KeybindingsRefusal::Unreadable(message),
        }
    }
}

/// The file changed: its new revision and who changed it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct KeybindingsChange {
    pub revision: u64,
    pub origin: Origin,
}

/// What one op did: every change it produced (a hand edit found by the
/// write-time refresh comes first), emitted whether or not the op succeeded.
#[derive(Debug, Clone)]
pub struct KeybindingsApplied {
    pub changes: Vec<KeybindingsChange>,
    pub result: Result<KeybindingsOutcome, KeybindingsRefusal>,
}

/// The revision after the op; `replayed` for a retry of a committed key.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct KeybindingsOutcome {
    pub revision: u64,
    pub replayed: bool,
}

/// Replay records kept (oldest dropped first), as the settings owner keeps.
const REPLAY_CAPACITY: usize = 4096;

impl KeybindingsOp {
    fn wire_name(&self) -> &'static str {
        match self {
            KeybindingsOp::Set { .. } => "keybindings.set",
            KeybindingsOp::Remove { .. } => "keybindings.remove",
            KeybindingsOp::Reset { .. } => "keybindings.reset",
        }
    }
}

pub struct KeybindingsStore {
    path: PathBuf,
    text: FileRead,
    revision: u64,
    /// Idempotency key -> the op it committed and the revision after it.
    replays: HashMap<String, (KeybindingsOp, u64)>,
    replay_order: VecDeque<String>,
}

impl KeybindingsStore {
    pub fn open(path: PathBuf) -> KeybindingsStore {
        let text = read_source(&path);
        KeybindingsStore {
            path,
            text,
            revision: 1,
            replays: HashMap::new(),
            replay_order: VecDeque::new(),
        }
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    pub fn revision(&self) -> u64 {
        self.revision
    }

    /// The entries and per-entry diagnostics of the file as last read or written.
    pub fn parsed(&self) -> Parsed {
        match &self.text {
            FileRead::Text(text) => parse(text),
            FileRead::Unreadable(message) => parse_unreadable(message),
        }
    }

    pub fn apply(
        &mut self,
        op: KeybindingsOp,
        origin: Origin,
        idempotency_key: Option<String>,
    ) -> KeybindingsApplied {
        if let Some(key) = &idempotency_key
            && let Some((committed, revision)) = self.replays.get(key)
        {
            let result = if format!("{committed:?}") == format!("{op:?}") {
                Ok(KeybindingsOutcome { revision: *revision, replayed: true })
            } else {
                Err(KeybindingsRefusal::IdempotencyConflict {
                    key: key.clone(),
                    committed: committed.wire_name(),
                })
            };
            return KeybindingsApplied { changes: vec![], result };
        }
        // Daemons of other sessions may own the same file: hold its lock
        // across refresh, edit and publish so no update is lost.
        let _lock = lock_config(&self.path);
        let mut changes: Vec<KeybindingsChange> = self.reload().into_iter().collect();
        let edited = self.edit(&op);
        let written = edited.and_then(|next| self.write(next, origin));
        if let Ok(Some(change)) = &written {
            changes.push(*change);
        }
        let result =
            written.map(|_| KeybindingsOutcome { revision: self.revision, replayed: false });
        if let (Ok(outcome), Some(key)) = (&result, idempotency_key) {
            self.remember(key, op, outcome.revision);
        }
        KeybindingsApplied { changes, result }
    }

    fn remember(&mut self, key: String, op: KeybindingsOp, revision: u64) {
        if self.replays.insert(key.clone(), (op, revision)).is_none() {
            self.replay_order.push_back(key);
        }
        while self.replay_order.len() > REPLAY_CAPACITY {
            if let Some(oldest) = self.replay_order.pop_front() {
                self.replays.remove(&oldest);
            }
        }
    }

    /// Publishes `next`; no change when the edit left the text as it was.
    fn write(
        &mut self,
        next: String,
        origin: Origin,
    ) -> Result<Option<KeybindingsChange>, KeybindingsRefusal> {
        if matches!(&self.text, FileRead::Text(current) if *current == next) {
            return Ok(None);
        }
        publish(&self.path, &next).map_err(|error| KeybindingsRefusal::Io(error.to_string()))?;
        self.text = FileRead::Text(next);
        self.revision += 1;
        Ok(Some(KeybindingsChange { revision: self.revision, origin }))
    }

    fn edit(&self, op: &KeybindingsOp) -> Result<String, KeybindingsRefusal> {
        let source = match &self.text {
            FileRead::Text(text) => text.as_str(),
            FileRead::Unreadable(message) => {
                return Err(KeybindingsRefusal::Unreadable(message.clone()));
            }
        };
        Ok(match op {
            KeybindingsOp::Set { binding, args, replaces } => {
                edit::set(source, binding, args.as_ref(), replaces.as_ref())?
            }
            KeybindingsOp::Remove { target } => edit::remove(source, target)?,
            KeybindingsOp::Reset { command } => edit::reset(source, command)?,
        })
    }

    /// Re-reads the file (the watcher calls this). A change only when its
    /// text changed.
    pub fn reload(&mut self) -> Option<KeybindingsChange> {
        let next = read_source(&self.path);
        if same(&next, &self.text) {
            return None;
        }
        self.text = next;
        self.revision += 1;
        Some(KeybindingsChange { revision: self.revision, origin: Origin::File })
    }

    /// The file and its symlink target.
    pub fn watch_paths(&self) -> Vec<PathBuf> {
        let mut paths = vec![self.path.clone()];
        let resolved = resolve_symlinks(&self.path);
        if resolved != self.path {
            paths.push(resolved);
        }
        paths
    }
}

fn same(left: &FileRead, right: &FileRead) -> bool {
    match (left, right) {
        (FileRead::Text(left), FileRead::Text(right)) => left == right,
        (FileRead::Unreadable(left), FileRead::Unreadable(right)) => left == right,
        _ => false,
    }
}

fn parse_unreadable(message: &str) -> Parsed {
    Parsed {
        entries: vec![],
        diagnostics: vec![super::EntryDiagnostic {
            index: None,
            problem: super::Problem::UnreadableFile,
            message: message.to_string(),
        }],
    }
}
