//! The settings owner with IO: the single writer of cmux.json. It refreshes
//! from disk before every write (a hand edit the watcher has not reported
//! yet is never lost), runs the reducer, publishes atomically, then adopts
//! the next state and writes the cold-start cache.

use std::path::{Path, PathBuf};

use crate::cache::{read_cache, write_cache};
use crate::domains::Domains;
use crate::fsio::{publish, read_source, resolve_symlinks};
use crate::managed::{ManagedReader, TeamPolicyLayer};
use crate::refusal::Refusal;
use crate::schema::Schema;
use crate::store::{self, Change, Op, Outcome, State};

/// What one op did. `changes` holds every revision it produced (an external
/// edit found by the write-time refresh comes first), emitted as events
/// whether or not the op itself succeeded.
#[derive(Debug, Clone)]
pub struct ApplyResult {
    pub changes: Vec<Change>,
    pub result: Result<Outcome, Refusal>,
}

pub struct ConfigStore {
    state: State,
    config_path: PathBuf,
    state_dir: Option<PathBuf>,
    reader: Box<dyn ManagedReader>,
}

impl ConfigStore {
    /// Reads cmux.json and the managed values. The revision continues from
    /// the cold-start cache (one more when the effective settings changed
    /// while no owner ran), so clients never see a revision go back.
    pub fn open(
        config_path: PathBuf,
        state_dir: Option<PathBuf>,
        reader: Box<dyn ManagedReader>,
    ) -> ConfigStore {
        let schema = Schema::embedded();
        let cached = state_dir.as_deref().and_then(read_cache);
        let file = read_source(&config_path);
        let revision = cached.as_ref().map_or(0, |(revision, _)| *revision);
        let mut state = State::new(
            schema,
            file,
            reader.read(),
            TeamPolicyLayer::default(),
            Domains::default(),
            revision,
        );
        if let Some((revision, effective)) = cached
            && effective != state.effective().root
        {
            state = state.with_revision(revision + 1);
        }
        let store = ConfigStore { state, config_path, state_dir, reader };
        store.write_cache();
        store
    }

    pub fn state(&self) -> &State {
        &self.state
    }

    pub fn config_path(&self) -> &Path {
        &self.config_path
    }

    /// Runs `op`: refresh from disk (write ops), reduce, publish, adopt.
    pub fn apply(&mut self, op: Op) -> ApplyResult {
        let mut changes = Vec::new();
        if matches!(op, Op::Set { .. } | Op::Reset { .. } | Op::ResetAll { .. }) {
            let (refreshed, change) =
                self.state.reload(read_source(&self.config_path), self.state.managed().clone());
            self.state = refreshed;
            changes.extend(change);
        }
        let result = match store::apply(&self.state, op) {
            Err(refusal) => Err(refusal),
            Ok(applied) => {
                match applied.write.as_deref().map(|text| publish(&self.config_path, text)) {
                    Some(Err(error)) => Err(Refusal::Io { message: error.to_string() }),
                    _ => {
                        self.state = applied.state;
                        changes.extend(applied.changes);
                        Ok(applied.outcome)
                    }
                }
            }
        };
        if !changes.is_empty() {
            self.write_cache();
        }
        ApplyResult { changes, result }
    }

    /// Re-reads cmux.json and the managed values (the watcher calls this).
    /// A change only when the effective settings changed.
    pub fn reload(&mut self) -> Option<Change> {
        let (next, change) = self.state.reload(read_source(&self.config_path), self.reader.read());
        self.state = next;
        if change.is_some() {
            self.write_cache();
        }
        change
    }

    /// Files whose changes may change the settings: cmux.json (and its
    /// symlink target) and the managed reader's files.
    pub fn watch_paths(&self) -> Vec<PathBuf> {
        let mut paths = vec![self.config_path.clone()];
        let resolved = resolve_symlinks(&self.config_path);
        if resolved != self.config_path {
            paths.push(resolved);
        }
        paths.extend(self.reader.watch_paths());
        paths
    }

    /// Best effort: the cache is a launch convenience; the daemon's
    /// snapshot is the record.
    fn write_cache(&self) {
        if let Some(dir) = &self.state_dir {
            let _ = write_cache(dir, &self.state);
        }
    }
}
