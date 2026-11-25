//! The settings owner with IO: the single writer of cmux.json. It refreshes
//! from disk before every write (a hand edit the watcher has not reported
//! yet is never lost), runs the reducer, publishes atomically, then adopts
//! the next state and writes the cold-start cache.

use std::path::{Path, PathBuf};

use cmux_json::JsonSet as _;
use serde_json::Value;

use crate::cache::{read_cache, write_cache};
use crate::domains::Domains;
use crate::fsio::{publish, read_source, resolve_symlinks, write_atomic};
use crate::history::{self, HistoryEntry, HistoryLog};
use crate::location::team_policy_path;
use crate::managed::{ManagedReader, TeamPolicyLayer};
use crate::refusal::Refusal;
use crate::schema::Schema;
use crate::store::{self, Change, FileRead, Op, Outcome, State, ThemeRead};
use crate::theme_file;

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
    /// Absolute: `settings.snapshot` reports it as `path`.
    config_path: PathBuf,
    /// Read while `config_path` does not exist (classic `cmux.json`); the
    /// first write then creates `config_path` from that text.
    seed_path: Option<PathBuf>,
    state_dir: Option<PathBuf>,
    /// The history of `config_path` in the state directory
    /// ([`crate::history::history_file_name`]); `None` without one.
    history: Option<HistoryLog>,
    /// The file text the last time it parsed: what a change out of a file
    /// that did not parse is recorded against.
    last_good: Option<String>,
    reader: Box<dyn ManagedReader>,
}

impl ConfigStore {
    /// Reads cmux.json and the managed values. The revision continues from
    /// the cold-start cache (one more when the effective settings changed
    /// while no owner ran), so clients never see a revision go back.
    ///
    /// A relative `config_path` is taken from the current directory once,
    /// here (no symlink is followed), so the owner keeps one file and
    /// [`ConfigStore::snapshot_json`] can name it.
    pub fn open(
        config_path: PathBuf,
        seed_path: Option<PathBuf>,
        state_dir: Option<PathBuf>,
        reader: Box<dyn ManagedReader>,
    ) -> ConfigStore {
        let config_path = std::path::absolute(&config_path).unwrap_or(config_path);
        let schema = Schema::embedded();
        let cached = state_dir.as_deref().and_then(read_cache);
        let file = read_settings(&config_path, seed_path.as_deref());
        let team =
            state_dir.as_deref().and_then(|dir| read_team_policy(dir, schema)).unwrap_or_default();
        let revision = cached.as_ref().map_or(0, |(revision, _)| *revision);
        let managed = reader.read();
        let mut state =
            State::new(schema, file.clone(), managed.clone(), team, Domains::default(), revision);
        // The theme file the settings pick applies from the first read.
        if state.theme_wanted().is_some() {
            let config_dir = config_path.parent().map(Path::to_path_buf).unwrap_or_default();
            state = state
                .reload_with_theme(file, managed, |name| Some(read_theme(&config_dir, name)))
                .0;
            state = state.with_revision(revision);
        }
        if let Some((revision, effective)) = cached
            && effective != state.effective().root
        {
            state = state.with_revision(revision + 1);
        }
        let history = state_dir.as_deref().map(|dir| HistoryLog::new(dir, &config_path));
        // Revisions continue past the history's too (a lost cache must not
        // reuse a revision an entry already names).
        if let Some(newest) = history.as_ref().and_then(HistoryLog::newest_revision)
            && newest > state.revision()
        {
            state = state.with_revision(newest);
        }
        // Opened on a file that does not parse: the text it last parsed with
        // is the saved one, so the change out of the broken text undoes alone.
        let last_good = if state.file_problem().is_some() {
            history.as_ref().and_then(HistoryLog::last_text)
        } else {
            None
        };
        let mut store =
            ConfigStore { state, config_path, seed_path, state_dir, history, last_good, reader };
        store.catch_up();
        store.migrate_once();
        store.note_good();
        store.write_cache();
        store
    }

    /// Moves a key cmux has renamed to its new name in the person's own file,
    /// once per rename: each one is recorded in the ledger
    /// (`migrations::once`), so a later open never runs it again. Needs a
    /// state directory for the ledger and a settings file of the person's
    /// own (a classic seed is not theirs to rewrite). A broken file, or a
    /// write that fails, records nothing: the next open tries again.
    fn migrate_once(&mut self) {
        use crate::migrations::once::{Ledger, pending};
        let Some(dir) = self.state_dir.clone() else { return };
        if self.state.file_problem.is_some()
            || std::fs::symlink_metadata(&self.config_path).is_err()
        {
            return;
        }
        let mut ledger = Ledger::read(&dir);
        let due = pending(&self.state.file_root, &ledger);
        if due.is_empty() {
            return;
        }
        let at = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |elapsed| elapsed.as_secs());
        for migration in due {
            let moved = match migration.edit {
                None => false,
                Some(edit) => {
                    let meta =
                        store::WriteMeta { origin: store::Origin::App, ..Default::default() };
                    match self.apply(Op::Edit { edits: vec![edit], meta }).result {
                        Ok(_) => true,
                        // Not this open's to finish: the file is broken or unwritable.
                        Err(Refusal::FileUnreadable { .. } | Refusal::Io { .. }) => break,
                        // The new row refuses the value (a managed key, a bad value): the file
                        // keeps the old key, which the table still reads.
                        Err(_) => false,
                    }
                }
            };
            ledger.record(migration.id, moved, at);
        }
        let _ = ledger.write(&dir);
    }

    pub fn state(&self) -> &State {
        &self.state
    }

    pub fn config_path(&self) -> &Path {
        &self.config_path
    }

    /// The `settings.snapshot` answer: the state's snapshot and `path`, the
    /// absolute path of the settings file this owner reads and writes (the
    /// configured path, not a symlink's target). A client with a settings
    /// file of its own (the Mac app) compares the two before it sends a
    /// write: an owner started on another file would change that file.
    pub fn snapshot_json(&self) -> Value {
        let mut snapshot = self.state.snapshot().to_json();
        snapshot.set("path", Value::String(self.config_path.to_string_lossy().into_owned()));
        snapshot
    }

    /// Whether `file` names the settings file this owner reads and writes,
    /// both paths standardized without touching the disk (`.` and `..`
    /// folded, as Swift's `standardizedFileURL`; symlinks not followed).
    /// `settings.edit`'s `file`: an owner started on another file refuses.
    pub fn serves(&self, file: &Path) -> bool {
        standardized(file) == standardized(&self.config_path)
    }

    /// The settings history, newest first (at most
    /// [`crate::history::HISTORY_CAPACITY`] entries); empty without a state
    /// directory.
    pub fn history(&self) -> Vec<HistoryEntry> {
        let mut entries = self.history.as_ref().map(HistoryLog::read).unwrap_or_default();
        entries.reverse();
        entries
    }

    /// Records a change of the file made while no owner ran: the text last
    /// seen parsing differs from the file's now. One entry (origin `file`),
    /// under a new revision, so undo takes back that change alone.
    fn catch_up(&mut self) {
        if self.state.file_problem().is_some() {
            return;
        }
        let Some(log) = self.history.as_mut() else { return };
        let Some(before) = log.last_text() else { return };
        if before == self.state.source() {
            return;
        }
        let revision = self.state.revision().saturating_add(1);
        self.state = self.state.clone().with_revision(revision);
        log.append(&HistoryEntry {
            revision,
            at: history::now_ms(),
            origin: crate::Origin::File.as_str().to_string(),
            keys: Vec::new(),
            before,
            undoes: None,
        });
    }

    /// Remembers the file text while it parses (see `last_good`).
    fn note_good(&mut self) {
        if self.state.file_problem().is_some() {
            return;
        }
        let text = self.state.source();
        if self.last_good.as_deref() == Some(text) {
            return;
        }
        self.last_good = Some(text.to_string());
        if let Some(log) = &self.history {
            log.save_last_text(text);
        }
    }

    /// Records a published change of the file whose text was `before`. A
    /// change that left the file text alone (managed values, a theme file)
    /// or that came from a file which did not parse is no setup to go back
    /// to, and is not recorded.
    /// A change out of a file that did not parse is recorded against the
    /// text it last parsed with, so the change into the broken text and the
    /// one out of it undo as one.
    fn record(&mut self, change: &Change, before: &str, before_broken: bool, undoes: Option<u64>) {
        let before = if before_broken {
            match self.last_good.clone() {
                Some(good) => good,
                None => return,
            }
        } else {
            before.to_string()
        };
        if before == self.state.source() {
            return;
        }
        let Some(log) = self.history.as_mut() else { return };
        log.append(&HistoryEntry {
            revision: change.revision,
            at: history::now_ms(),
            origin: change.origin.as_str().to_string(),
            keys: change.keys.clone(),
            before,
            undoes,
        });
        self.note_good();
    }

    /// A hand edit that changed the file's text but no setting (a comment,
    /// formatting) still gets a history entry, under a revision of its own
    /// with no keys: else an undo would skip it and take back the change
    /// before it, losing the edit. Returns that change for the caller to emit
    /// (clients then hold the new revision). Nothing without a history.
    fn text_only_change(&mut self, before: &str, before_broken: bool) -> Option<Change> {
        if self.history.is_none() || self.state.file_problem().is_some() {
            return None;
        }
        let baseline = if before_broken { self.last_good.as_deref()? } else { before };
        if baseline == self.state.source() {
            return None;
        }
        let revision = self.state.revision().saturating_add(1);
        self.state = self.state.clone().with_revision(revision);
        Some(Change { revision, keys: Vec::new(), origin: crate::Origin::File })
    }

    /// Runs `op`: refresh from disk (write ops), reduce, publish, adopt.
    /// Every published change of the file is recorded in the history.
    pub fn apply(&mut self, op: Op) -> ApplyResult {
        let mut changes = Vec::new();
        let team_before = self.state.team().clone();
        let writes = matches!(
            op,
            Op::Set { .. }
                | Op::Reset { .. }
                | Op::ResetAll { .. }
                | Op::Edit { .. }
                | Op::Undo { .. }
                | Op::Restore { .. }
                | Op::ResetGroup { .. }
        );
        // Daemons of other sessions may own the same file: hold its advisory
        // lock across refresh, reduce and publish so no update is lost.
        let _lock = if writes { lock_config(&self.config_path) } else { None };
        if writes {
            // Fresh managed values too: macOS sends no notification for a new
            // MDM profile, so the watcher may not have seen it yet.
            let before = self.state.source().to_string();
            let broken = self.state.file_problem().is_some();
            let (refreshed, change) = self.state.reload(self.read_file(), self.reader.read());
            self.state = refreshed;
            let change = change.or_else(|| self.text_only_change(&before, broken));
            if let Some(change) = &change {
                self.record(change, &before, broken, None);
            }
            changes.extend(change);
        }
        let history = match &op {
            Op::Undo { .. } | Op::Restore { .. } => {
                self.history.as_ref().map(HistoryLog::read).unwrap_or_default()
            }
            _ => Vec::new(),
        };
        let before = self.state.source().to_string();
        let broken = self.state.file_problem().is_some();
        let result = match store::apply_with_history(&self.state, op, &history) {
            Err(refusal) => Err(refusal),
            Ok(applied) => {
                match applied.write.as_deref().map(|text| publish(&self.config_path, text)) {
                    Some(Err(error)) => Err(Refusal::Io { message: error.to_string() }),
                    published => {
                        self.state = applied.state;
                        if published.is_some() {
                            for change in &applied.changes {
                                self.record(change, &before, broken, applied.undoes);
                            }
                        }
                        changes.extend(applied.changes);
                        Ok(applied.outcome)
                    }
                }
            }
        };
        // A write that picks another theme file: read that file now.
        if self.state.theme_wanted().is_some_and(|(_, stale)| stale)
            && let Some(change) = self.reload()
        {
            changes.push(change);
        }
        if *self.state.team() != team_before {
            self.write_team_policy();
        }
        if !changes.is_empty() {
            self.write_cache();
        }
        self.note_good();
        ApplyResult { changes, result }
    }

    /// Re-reads cmux.json and the managed values (the watcher calls this).
    /// A change only when the effective settings changed.
    pub fn reload(&mut self) -> Option<Change> {
        let config_dir = self.config_dir();
        let before = self.state.source().to_string();
        let broken = self.state.file_problem().is_some();
        let (next, change) =
            self.state.reload_with_theme(self.read_file(), self.reader.read(), |name| {
                Some(read_theme(&config_dir, name))
            });
        self.state = next;
        let change = change.or_else(|| self.text_only_change(&before, broken));
        if let Some(change) = &change {
            self.record(change, &before, broken, None);
            self.write_cache();
        }
        self.note_good();
        change
    }

    fn read_file(&self) -> FileRead {
        read_settings(&self.config_path, self.seed_path.as_deref())
    }

    /// The folder of the settings file, where `themes/` is.
    fn config_dir(&self) -> PathBuf {
        self.config_path.parent().map(Path::to_path_buf).unwrap_or_default()
    }

    /// The active theme file's path (it may not exist), when one is picked.
    /// It changes when `appearance.themeFile` does: a watcher of it is
    /// re-armed then (`watch_paths` includes it).
    pub fn theme_watch_path(&self) -> Option<PathBuf> {
        self.state.theme_wanted().map(|(name, _)| theme_file::path(&self.config_dir(), name))
    }

    /// Files whose changes may change the settings: cmux.json (and its
    /// symlink target), the managed reader's files and the active theme file.
    pub fn watch_paths(&self) -> Vec<PathBuf> {
        let mut paths = vec![self.config_path.clone()];
        paths.extend(self.theme_watch_path());
        let resolved = resolve_symlinks(&self.config_path);
        if resolved != self.config_path {
            paths.push(resolved);
        }
        if let Some(seed) = &self.seed_path {
            paths.push(seed.clone());
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

/// Theme file `name` beside the settings file: the user's, else the one
/// cmux ships.
fn read_theme(config_dir: &Path, name: &str) -> ThemeRead {
    ThemeRead {
        name: name.to_string(),
        read: theme_file::source(config_dir, name, None),
        folder: Some(theme_file::folder(config_dir)),
    }
}

/// The settings file's text, or the seed's while the file does not exist.
fn read_settings(config_path: &Path, seed_path: Option<&Path>) -> FileRead {
    match seed_path {
        Some(seed)
            if std::fs::symlink_metadata(config_path)
                .is_err_and(|error| error.kind() == std::io::ErrorKind::NotFound) =>
        {
            read_source(seed)
        }
        _ => read_source(config_path),
    }
}

/// `path` made absolute with `.` and `..` folded, without reading the disk.
fn standardized(path: &Path) -> PathBuf {
    use std::path::Component;
    let absolute = std::path::absolute(path).unwrap_or_else(|_| path.to_path_buf());
    let mut out = PathBuf::new();
    for component in absolute.components() {
        match component {
            Component::CurDir => {}
            Component::ParentDir => {
                out.pop();
            }
            other => out.push(other),
        }
    }
    out
}

/// The saved team layer, limited to the catalog of this build.
fn read_team_policy(state_dir: &Path, schema: &Schema) -> Option<TeamPolicyLayer> {
    let text = std::fs::read_to_string(team_policy_path(state_dir)).ok()?;
    let document: Value = serde_json::from_str(&text).ok()?;
    TeamPolicyLayer::from_device_policy(&document, schema)
}

/// An exclusive advisory lock on `.<name>.lock` beside the configured file.
/// `None` when the lock file cannot be opened (a read-only directory): the
/// write then goes ahead like before, and the publish reports any error.
///
/// The Mac app no longer writes the settings file (its writes are
/// `settings.edit` ops), so only owners in this crate take the lock.
pub(crate) fn lock_config(config_path: &Path) -> Option<ConfigLock> {
    // Beside the configured path, not a symlink's target: a dotfiles repo
    // never gets a lock file.
    let directory = config_path.parent().filter(|dir| !dir.as_os_str().is_empty())?;
    std::fs::create_dir_all(directory).ok()?;
    let name = config_path.file_name()?.to_string_lossy().into_owned();
    let file = std::fs::OpenOptions::new()
        .create(true)
        .truncate(false)
        .write(true)
        .open(directory.join(format!(".{name}.lock")))
        .ok()?;
    file.lock().ok()?;
    Some(ConfigLock(file))
}

/// [`lock_config`]'s lock, held until dropped. The drop unlocks before the
/// file closes: a child another thread started meanwhile keeps a copy of the
/// open file until it execs or exits, and a close alone would leave the lock
/// held in that copy.
pub(crate) struct ConfigLock(std::fs::File);

impl std::ops::Deref for ConfigLock {
    type Target = std::fs::File;
    fn deref(&self) -> &std::fs::File {
        &self.0
    }
}

impl Drop for ConfigLock {
    fn drop(&mut self) {
        let _ = self.0.unlock();
    }
}

#[cfg(all(test, unix))]
#[path = "owner_lock_tests.rs"]
mod lock_tests;

#[cfg(all(test, unix))]
mod serves_tests {
    use super::*;

    /// `settings.edit`'s `file` check: the configured path, written with `.`
    /// or `..`, is served; another file is not.
    #[test]
    fn the_owner_serves_its_own_file_only() {
        let dir = std::env::temp_dir().join(format!("cmux-serves-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let config = dir.join("cmux-next.json");
        let reader = Box::new(crate::managed::FixedManagedReader::default());
        let store = ConfigStore::open(config.clone(), None, None, reader);
        assert!(store.serves(&config));
        assert!(store.serves(&dir.join("./sub/../cmux-next.json")));
        assert!(!store.serves(&dir.join("other.json")));
        assert!(!store.serves(&dir.join("sub/cmux-next.json")));
        let _ = std::fs::remove_dir_all(&dir);
    }
}
