//! The revision history of one protocol: which changes each revision made to
//! which message kinds.

use serde::{Deserialize, Serialize};

use crate::CompatError;
use crate::change::Change;

/// The full change history of a protocol, as stored in its compat file
/// (for the cmux-tui daemon: `cmux-tui/spec/api-compat.json`).
///
/// ```json
/// {
///   "protocol": "cmux-mux",
///   "base": 12,
///   "revisions": [
///     { "rev": 13, "note": "workspace name is now title",
///       "changes": [ { "message": "event:workspace-updated", "op": "rename",
///                      "path": "/workspace/name", "to": "title" } ] }
///   ]
/// }
/// ```
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Schema {
    /// Protocol name (for error messages and the handshake).
    pub protocol: String,
    /// The oldest revision this build can still talk to.
    pub base: u32,
    /// The dated name of `base` (`YYYY-MM-DD`, [`crate::version`]). Set once a
    /// protocol makes the dated-version promise; then every later revision
    /// carries a later `date`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub base_date: Option<String>,
    /// Revisions after `base`, ascending and contiguous (`base + 1`, `base + 2`, ...).
    #[serde(default)]
    pub revisions: Vec<Revision>,
}

/// One revision: every change it made, per message kind.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Revision {
    /// This revision's number.
    pub rev: u32,
    /// Why the revision exists (free text).
    #[serde(default)]
    pub note: String,
    /// The dated name a client pins this revision by (`YYYY-MM-DD`,
    /// [`crate::version`]); required once the schema has a `base_date`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub date: Option<String>,
    /// The changes, applied in order when upgrading.
    #[serde(default)]
    pub changes: Vec<MessageChange>,
    /// The structural fingerprint of the schema file this revision describes,
    /// written by the coverage check; a schema edit without a new revision
    /// changes the fingerprint and fails CI.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fingerprint: Option<String>,
}

/// A change to one message kind.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct MessageChange {
    /// The message kind, as named by the integration (for example
    /// `request:new-workspace`, `response:list-workspaces`, `event:tree-updated`).
    pub message: String,
    /// The change itself.
    #[serde(flatten)]
    pub change: Change,
}

impl Schema {
    /// An empty history: only `base` exists.
    pub fn new(protocol: impl Into<String>, base: u32) -> Self {
        Self { protocol: protocol.into(), base, base_date: None, revisions: Vec::new() }
    }

    /// Parses and validates a compat file.
    pub fn from_json(bytes: &[u8]) -> Result<Self, CompatError> {
        let schema: Self =
            serde_json::from_slice(bytes).map_err(|e| CompatError::InvalidSchema(e.to_string()))?;
        schema.validate()?;
        Ok(schema)
    }

    /// The newest revision.
    pub fn current(&self) -> u32 {
        self.revisions.last().map_or(self.base, |r| r.rev)
    }

    /// Appends a revision (`current() + 1`) and returns its number.
    pub fn push(&mut self, note: impl Into<String>, changes: Vec<MessageChange>) -> u32 {
        let rev = self.current() + 1;
        self.revisions.push(Revision {
            rev,
            note: note.into(),
            date: None,
            changes,
            fingerprint: None,
        });
        rev
    }

    /// Appends a revision pinned by `date` (`YYYY-MM-DD`) and returns its number.
    pub fn push_dated(
        &mut self,
        date: impl Into<String>,
        note: impl Into<String>,
        changes: Vec<MessageChange>,
    ) -> u32 {
        let rev = self.push(note, changes);
        if let Some(revision) = self.revisions.last_mut() {
            revision.date = Some(date.into());
        }
        rev
    }

    /// Checks numbering and that every change compiles in both directions.
    pub fn validate(&self) -> Result<(), CompatError> {
        for (expected, revision) in (self.base + 1..).zip(&self.revisions) {
            if revision.rev != expected {
                return Err(CompatError::InvalidSchema(format!(
                    "revision {} out of order (expected {expected})",
                    revision.rev
                )));
            }
            for change in &revision.changes {
                change.change.to_op(true)?;
                change.change.to_op(false)?;
            }
        }
        crate::version::validate_dates(self)
    }
}
