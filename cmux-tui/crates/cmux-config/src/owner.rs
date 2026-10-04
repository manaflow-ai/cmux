//! The settings owner with IO: the single writer of cmux.json. It refreshes
//! from disk before every write (a hand edit the watcher has not reported
//! yet is never lost), runs the reducer, publishes atomically, then adopts
//! the next state and writes the cold-start cache.

use std::path::{Path, PathBuf};

use crate::cache::{read_cache, write_cache};
use crate::domains::Domains;
use crate::fsio::{publish, read_source, resolve_symlinks, write_atomic};
use crate::location::team_policy_path;
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
        let team =
            state_dir.as_deref().and_then(|dir| read_team_policy(dir, schema)).unwrap_or_default();
        let revision = cached.as_ref().map_or(0, |(revision, _)| *revision);
        let mut state = State::new(schema, file, reader.read(), team, Domains::default(), revision);
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
        let team_before = self.state.team().clone();
        let writes = matches!(op, Op::Set { .. } | Op::Reset { .. } | Op::ResetAll { .. });
        // Daemons of other sessions may own the same file: hold its advisory
        // lock across refresh, reduce and publish so no update is lost.
        let _lock = if writes { lock_config(&self.config_path) } else { None };
        if writes {
            // Fresh managed values too: macOS sends no notification for a new
            // MDM profile, so the watcher may not have seen it yet.
            let (refreshed, change) =
                self.state.reload(read_source(&self.config_path), self.reader.read());
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
        if *self.state.team() != team_before {
            self.write_team_policy();
        }
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

    /// Saves the team layer (or removes the file when no team manages this
    /// install). Best effort like the cache: the app sends the layer again
    /// after every connect.
    fn write_team_policy(&self) {
        let Some(dir) = &self.state_dir else { return };
        let path = team_policy_path(dir);
        if self.state.team().team_id.is_empty() && self.state.team().enforced.is_empty() {
            let _ = std::fs::remove_file(path);
            return;
        }
        let mut text = crate::render::pretty(&self.state.team().to_device_policy(), "");
        text.push('\n');
        let _ = write_atomic(&path, text.as_bytes());
    }

    /// Best effort: the cache is a launch convenience; the daemon's
    /// snapshot is the record.
    fn write_cache(&self) {
        if let Some(dir) = &self.state_dir {
            let _ = write_cache(dir, &self.state);
        }
    }
}

/// The saved team layer, limited to the catalog of this build.
fn read_team_policy(state_dir: &Path, schema: &Schema) -> Option<TeamPolicyLayer> {
    let text = std::fs::read_to_string(team_policy_path(state_dir)).ok()?;
    let document: serde_json::Value = serde_json::from_str(&text).ok()?;
    TeamPolicyLayer::from_device_policy(&document, schema)
}

/// An exclusive advisory lock on `.<name>.lock` beside the (resolved) file.
/// `None` when the lock file cannot be opened (a read-only directory): the
/// write then goes ahead like before, and the publish reports any error.
fn lock_config(config_path: &Path) -> Option<std::fs::File> {
    let target = resolve_symlinks(config_path);
    let directory = target.parent().filter(|dir| !dir.as_os_str().is_empty())?;
    std::fs::create_dir_all(directory).ok()?;
    let name = target.file_name()?.to_string_lossy().into_owned();
    let file = std::fs::OpenOptions::new()
        .create(true)
        .truncate(false)
        .write(true)
        .open(directory.join(format!(".{name}.lock")))
        .ok()?;
    file.lock().ok()?;
    Some(file)
}
