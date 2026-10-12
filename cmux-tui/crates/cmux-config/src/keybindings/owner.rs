//! The keybindings.json owner with IO (K-T6): the single writer of the file
//! beside the settings file. Like the settings owner it re-reads the file
//! under the advisory lock before every edit (a hand edit the watcher has
//! not reported yet is never lost), edits it in place ([`super::edit`]) and
//! publishes atomically. A revision counts every change the owner saw, its
//! own writes and the file's.

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
}

impl KeybindingsRefusal {
    pub fn code(&self) -> &'static str {
        match self {
            KeybindingsRefusal::Invalid(_) => "keybindings.invalid",
            KeybindingsRefusal::Unreadable(_) => "keybindings.unreadable",
            KeybindingsRefusal::Io(_) => "keybindings.io",
        }
    }

    pub fn message(&self) -> &str {
        match self {
            KeybindingsRefusal::Invalid(message)
            | KeybindingsRefusal::Unreadable(message)
            | KeybindingsRefusal::Io(message) => message,
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
    pub result: Result<u64, KeybindingsRefusal>,
}

pub struct KeybindingsStore {
    path: PathBuf,
    text: FileRead,
    revision: u64,
}

impl KeybindingsStore {
    pub fn open(path: PathBuf) -> KeybindingsStore {
        let text = read_source(&path);
        KeybindingsStore { path, text, revision: 1 }
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

    pub fn apply(&mut self, op: KeybindingsOp, origin: Origin) -> KeybindingsApplied {
        // Daemons of other sessions may own the same file: hold its lock
        // across refresh, edit and publish so no update is lost.
        let _lock = lock_config(&self.path);
        let mut changes: Vec<KeybindingsChange> = self.reload().into_iter().collect();
        let edited = self.edit(&op);
        let written = edited.and_then(|next| self.write(next, origin));
        if let Ok(Some(change)) = &written {
            changes.push(*change);
        }
        KeybindingsApplied { changes, result: written.map(|_| self.revision) }
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
