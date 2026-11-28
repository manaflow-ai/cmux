//! One scope's sync: the folder, the state that says which store version each file was last
//! agreed at (with that version's bytes kept as the merge base), and the passes that move
//! changes both ways.
//!
//! A pass pulls (`tree?since=LAST_SEQ`, each entry applied by [`Engine::apply_remote`]) and then
//! pushes (each local file whose bytes are not its base's is PUT with `If-Match-Version` = the
//! base version; a file gone here is DELETEd the same way). A 409 pulls again, which merges the
//! store's version in, and tries once more.
//!
//! The daemon's loop runs that full pass (a walk of the whole folder) at start, every 5 minutes
//! and when the folder watcher lost events. A wake from a remote change pulls and publishes only
//! what the pull itself left to publish (a merge, a conflict's side file), and a wake from the
//! watcher publishes only the paths it named: a folder of thousands of notes is not walked once
//! per edit somewhere in the fleet ([`Engine::pass_changed`]).

use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};

use super::client::{Client, Entry, NotDeployed, Wrote};
use super::merge::{self, Merged};
use super::{MAX_FILE_BYTES, Scope, now_unix, sha256_hex, skipped_name};

/// The version a file was last agreed at. An empty `sha256` is a tombstone (deleted at
/// `version`).
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Base {
    pub version: u64,
    pub sha256: String,
}

/// A file the store (or our own scan) refused, kept until its bytes change.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Refused {
    pub sha256: String,
    pub reason: String,
}

/// A scope's sync state (`ROOT/.sync/SCOPE/state.json`).
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct State {
    /// The last store sequence number this machine has applied.
    pub last_seq: u64,
    #[serde(default)]
    pub files: BTreeMap<String, Base>,
    #[serde(default)]
    pub refused: BTreeMap<String, Refused>,
    #[serde(default)]
    pub last_error: Option<String>,
    /// When a pass last finished (unix seconds).
    #[serde(default)]
    pub last_ok: Option<u64>,
    /// The store's sequence number at the last pass.
    #[serde(default)]
    pub remote_seq: Option<u64>,
    /// Which `state.log` lines follow this snapshot: those carrying the same epoch.
    #[serde(default)]
    pub log_epoch: u64,
}

impl State {
    /// `state.json`, then the `state.log` lines written since it.
    pub fn load(state_dir: &Path) -> State {
        load_with_log(state_dir).0
    }

    fn apply(&mut self, delta: Delta) {
        for (path, base) in delta.files {
            match base {
                Some(base) => self.files.insert(path, base),
                None => self.files.remove(&path),
            };
        }
        self.last_seq = delta.last_seq;
        if let Some(refused) = delta.refused {
            self.refused = refused;
        }
        self.last_error = delta.last_error;
        self.last_ok = delta.last_ok;
        self.remote_seq = delta.remote_seq;
    }
}

/// One saved pass in `state.log`: the files it moved (`None` is gone) and the small fields
/// whole. A pass that pulls one note appends a line, not the whole `files` map again (two
/// megabytes on a fleet's private scope, rewritten on every remote change).
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Delta {
    /// The `logEpoch` of the snapshot this line follows; lines of an older one are stale.
    epoch: u64,
    #[serde(default)]
    files: BTreeMap<String, Option<Base>>,
    last_seq: u64,
    #[serde(default)]
    refused: Option<BTreeMap<String, Refused>>,
    #[serde(default)]
    last_error: Option<String>,
    #[serde(default)]
    last_ok: Option<u64>,
    #[serde(default)]
    remote_seq: Option<u64>,
}

impl Delta {
    fn between(saved: &State, now: &State) -> Delta {
        let mut files = BTreeMap::new();
        for (path, base) in &now.files {
            if saved.files.get(path) != Some(base) {
                files.insert(path.clone(), Some(base.clone()));
            }
        }
        for path in saved.files.keys() {
            if !now.files.contains_key(path) {
                files.insert(path.clone(), None);
            }
        }
        Delta {
            epoch: now.log_epoch,
            files,
            last_seq: now.last_seq,
            refused: (saved.refused != now.refused).then(|| now.refused.clone()),
            last_error: now.last_error.clone(),
            last_ok: now.last_ok,
            remote_seq: now.remote_seq,
        }
    }
}

/// The log is folded into a new snapshot once it outgrows this or the snapshot, whichever is
/// larger: each line stays O(change) and a load reads at most about twice the state.
const LOG_COMPACT_BYTES: u64 = 1 << 20;

/// The state, the log's length, and whether its tail is torn (a crash mid-append): appending
/// after a torn line would glue the next line onto it, so the next save compacts.
fn load_with_log(state_dir: &Path) -> (State, u64, bool) {
    let mut state: State = std::fs::read(state_dir.join("state.json"))
        .ok()
        .and_then(|bytes| serde_json::from_slice(&bytes).ok())
        .unwrap_or_default();
    let Ok(log) = std::fs::read(state_dir.join("state.log")) else {
        return (state, 0, false);
    };
    let mut torn = !log.is_empty() && !log.ends_with(b"\n");
    for line in log.split(|b| *b == b'\n').filter(|l| !l.is_empty()) {
        match serde_json::from_slice::<Delta>(line) {
            Ok(delta) if delta.epoch == state.log_epoch => state.apply(delta),
            Ok(_) => {}
            Err(_) => {
                torn = true;
                break;
            }
        }
    }
    (state, log.len() as u64, torn)
}

/// What a pass did.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize)]
pub struct Report {
    pub pulled: Vec<String>,
    pub pushed: Vec<String>,
    pub deleted: Vec<String>,
    pub merged: Vec<String>,
    pub conflicts: Vec<String>,
    pub refused: Vec<String>,
}

pub struct Engine {
    client: Client,
    scope: Scope,
    dir: PathBuf,
    state_dir: PathBuf,
    host: String,
    pub state: State,
    /// Each file's sha256 as last read, under the `stat` it was read at: a pass reads and hashes
    /// only files whose stamp moved, not the whole folder (thousands of notes, every pass).
    hashed: HashMap<String, (Stamp, String)>,
    /// The state as `state.json` last held it: a pass that changed nothing writes nothing.
    saved: Option<State>,
    /// `state.log`'s length; past [`LOG_COMPACT_BYTES`] and the snapshot the next save compacts.
    log_bytes: u64,
    /// `state.json`'s length at the last compaction.
    snapshot_bytes: u64,
    /// The next save writes a whole snapshot (a torn log tail, a failed append).
    compact_due: bool,
    /// Unreferenced bases are listed and removed on a full pass, not on every pull.
    prune_due: bool,
    /// Bytes written to `state.json` and `state.log` since start (tests read it).
    pub state_bytes_written: u64,
    /// Files read and hashed by pushes since start (what the stamp cache saves; tests read it).
    pub hashed_reads: u64,
    /// Whole-folder walks since start: one per full pass, none per [`Engine::pass_changed`]
    /// (tests read it).
    pub scans: u64,
    /// Paths a pull wrote here that still need publishing (a clean merge, a conflict's side
    /// file): the next pass of either kind publishes them.
    dirty: BTreeSet<String>,
    _lock: cmux_file_lock::FileLock,
}

/// What `stat` says of a file. The same stamp means the same bytes as when it was last hashed,
/// as git's index assumes; a file modified in the last [`RACY`] gets none, so a write landing in
/// the same clock tick as our read is never missed.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct Stamp {
    len: u64,
    modified: SystemTime,
    #[cfg(unix)]
    ino: u64,
    #[cfg(unix)]
    ctime: (i64, i64),
}

const RACY: Duration = Duration::from_secs(2);

impl Stamp {
    fn of(meta: &std::fs::Metadata) -> Option<Stamp> {
        if !meta.is_file() {
            return None;
        }
        let modified = meta.modified().ok()?;
        if SystemTime::now().duration_since(modified).map_or(true, |age| age < RACY) {
            return None;
        }
        #[cfg(unix)]
        use std::os::unix::fs::MetadataExt;
        Some(Stamp {
            len: meta.len(),
            modified,
            #[cfg(unix)]
            ino: meta.ino(),
            #[cfg(unix)]
            ctime: (meta.ctime(), meta.ctime_nsec()),
        })
    }
}

impl Engine {
    /// The sync of `scope` under `root`. Refuses while another holds it (the daemon's sync, or
    /// another `acpmux memory sync`).
    pub fn new(client: Client, scope: Scope, root: &Path, host: String) -> Result<Engine> {
        let dir = super::scope_dir(root, scope);
        let state_dir = super::state_dir(root, scope);
        crate::home_fs::create_dirs(&dir).with_context(|| format!("create {}", dir.display()))?;
        crate::home_fs::create_dirs(state_dir.join("bases"))
            .with_context(|| format!("create {}", state_dir.display()))?;
        let lock_file = crate::home_fs::OpenOptions::new()
            .create(true)
            .truncate(false)
            .write(true)
            .open(state_dir.join("lock"))
            .context("open the memory sync lock")?;
        let lock =
            match cmux_file_lock::FileLock::try_take(lock_file, cmux_file_lock::Kind::Exclusive) {
                Ok(lock) => lock,
                Err(cmux_file_lock::LockError::Busy(_)) => anyhow::bail!(
                    "another memory sync holds {} (the daemon's, when memory.sync is on)",
                    scope.as_str()
                ),
                Err(cmux_file_lock::LockError::Io(e)) => {
                    return Err(e).context("take the memory sync lock");
                }
            };
        let (state, log_bytes, torn) = load_with_log(&state_dir);
        let snapshot_bytes =
            std::fs::metadata(state_dir.join("state.json")).map(|m| m.len()).unwrap_or(0);
        let saved = Some(state.clone());
        Ok(Engine {
            client,
            scope,
            dir,
            state_dir,
            host,
            state,
            hashed: HashMap::new(),
            saved,
            log_bytes,
            snapshot_bytes,
            compact_due: torn,
            prune_due: true,
            state_bytes_written: 0,
            hashed_reads: 0,
            scans: 0,
            dirty: BTreeSet::new(),
            _lock: lock,
        })
    }

    pub fn dir(&self) -> &Path {
        &self.dir
    }

    /// Pull, then push every file under the folder; the state is saved either way.
    pub async fn pass(&mut self) -> Result<Report> {
        let mut report = Report::default();
        self.prune_due = true;
        let result = async {
            self.pull(&mut report).await?;
            self.push(&mut report).await
        }
        .await;
        self.finish(result, report)
    }

    /// Pull, then publish only `changed` (folder-relative paths the watcher named) and what the
    /// pull left to publish, without walking the folder. A named path that is gone is deleted
    /// (and every agreed file under it, for a removed folder); a named folder that exists falls
    /// back to the full push, since its files were not named one by one.
    pub async fn pass_changed(&mut self, changed: BTreeSet<String>) -> Result<Report> {
        let mut report = Report::default();
        let result = async {
            self.pull(&mut report).await?;
            self.push_paths(changed, &mut report).await
        }
        .await;
        self.finish(result, report)
    }

    fn finish(&mut self, result: Result<()>, report: Report) -> Result<Report> {
        match &result {
            Ok(()) => {
                self.state.last_error = None;
                self.state.last_ok = Some(now_unix());
            }
            Err(e) => self.state.last_error = Some(format!("{e:#}")),
        }
        self.save_if_changed()?;
        result.map(|()| report)
    }

    /// Apply what the store has after `last_seq`.
    pub async fn pull(&mut self, report: &mut Report) -> Result<()> {
        let mut tree = self.client.tree(self.scope, self.state.last_seq).await?;
        tree.entries.sort_by_key(|e| e.seq);
        for entry in &tree.entries {
            self.apply_remote(entry, report).await?;
        }
        self.state.last_seq = self.state.last_seq.max(tree.seq);
        self.state.remote_seq = Some(tree.seq);
        Ok(())
    }

    /// One remote entry: written here when the local file still matches its base (or is the
    /// same bytes), merged when both sides changed it, skipped when we already hold its version.
    pub async fn apply_remote(&mut self, e: &Entry, report: &mut Report) -> Result<()> {
        if !safe_rel(&e.path) || skipped_name(&e.path) {
            return Ok(());
        }
        let base = self.state.files.get(&e.path).cloned();
        if base.as_ref().is_some_and(|b| b.version >= e.version) {
            return Ok(()); // ours already, or older than what we hold (our own write's echo)
        }
        let local = self.read_local(&e.path)?;
        let local_sha = local.as_deref().map(sha256_hex);
        let base_sha = base.as_ref().map(|b| b.sha256.clone()).filter(|s| !s.is_empty());
        let unchanged = local_sha == base_sha;
        if e.deleted {
            if local.is_some() && unchanged {
                self.remove_local(&e.path, local_sha.as_deref())?;
                report.pulled.push(e.path.clone());
            }
            // Changed here, deleted there: ours stays and is published again over the tombstone.
            self.state
                .files
                .insert(e.path.clone(), Base { version: e.version, sha256: String::new() });
            return Ok(());
        }
        if local_sha.as_deref() == Some(e.sha256.as_str()) {
            let bytes = local.unwrap_or_default();
            self.record(&e.path, e.version, &bytes);
            return Ok(());
        }
        let Some(theirs) = self.client.get(self.scope, &e.path).await? else {
            return Ok(()); // deleted since; the next pull sees the tombstone
        };
        let Some(ours) = local.filter(|_| !unchanged) else {
            // Unchanged here (or deleted here while it changed there: theirs comes back).
            if self.write_local(&e.path, &theirs, local_sha.as_deref())? {
                self.record(&e.path, e.version, &theirs);
                report.pulled.push(e.path.clone());
            }
            return Ok(());
        };
        let base_bytes = base_sha.and_then(|sha| self.read_base(&sha)).unwrap_or_default();
        self.resolve(&e.path, e.version, &base_bytes, &ours, &theirs, report)
    }

    /// Both sides changed `rel`: merge, or keep theirs under the name and ours beside it.
    fn resolve(
        &mut self,
        rel: &str,
        their_version: u64,
        base: &[u8],
        ours: &[u8],
        theirs: &[u8],
        report: &mut Report,
    ) -> Result<()> {
        let ours_sha = sha256_hex(ours);
        match merge::three_way(rel, base, ours, theirs) {
            Merged::Clean(merged) => {
                if self.write_local(rel, &merged, Some(&ours_sha))? {
                    // Agreed at theirs; the push publishes the merge on top of it.
                    self.record(rel, their_version, theirs);
                    self.dirty.insert(rel.to_owned());
                    report.merged.push(rel.to_owned());
                }
            }
            Merged::Conflict => {
                let side = merge::conflict_name(rel, &self.host, now_unix());
                if !self.write_local(&side, ours, None)? {
                    return Ok(());
                }
                if self.write_local(rel, theirs, Some(&ours_sha))? {
                    self.record(rel, their_version, theirs);
                }
                self.dirty.insert(side.clone());
                report.conflicts.push(side);
            }
        }
        Ok(())
    }

    /// Publish what changed here: every file under the folder, and a delete for each agreed
    /// file no longer there.
    pub async fn push(&mut self, report: &mut Report) -> Result<()> {
        self.dirty.clear();
        let local = self.scan()?;
        for (rel, stamp) in &local {
            self.publish(rel, *stamp, report).await?;
        }
        self.hashed.retain(|rel, _| local.contains_key(rel));
        let gone: Vec<(String, Base)> = self
            .state
            .files
            .iter()
            .filter(|(rel, base)| !base.sha256.is_empty() && !local.contains_key(*rel))
            .map(|(rel, base)| (rel.clone(), base.clone()))
            .collect();
        for (rel, base) in gone {
            self.publish_delete(rel, base, report).await?;
        }
        Ok(())
    }

    /// Publish only `changed` and the paths a pull left dirty (see [`Engine::pass_changed`]).
    async fn push_paths(&mut self, changed: BTreeSet<String>, report: &mut Report) -> Result<()> {
        let mut paths = std::mem::take(&mut self.dirty);
        paths.extend(changed);
        for rel in paths {
            if !safe_rel(&rel) || skipped_name(&rel) {
                continue;
            }
            match std::fs::symlink_metadata(self.dir.join(&rel)) {
                Ok(meta) if meta.is_dir() => return self.push(report).await,
                Ok(meta) if meta.is_file() => {
                    if meta.len() <= MAX_FILE_BYTES {
                        self.publish(&rel, Stamp::of(&meta), report).await?;
                    }
                }
                Ok(_) => {} // a symlink or a special file: never synced
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                    self.hashed.remove(&rel);
                    let under = format!("{rel}/");
                    let gone: Vec<(String, Base)> = self
                        .state
                        .files
                        .iter()
                        .filter(|(path, base)| {
                            !base.sha256.is_empty() && (**path == rel || path.starts_with(&under))
                        })
                        .map(|(path, base)| (path.clone(), base.clone()))
                        .collect();
                    for (path, base) in gone {
                        // Under a removed folder, a file back by another name is not gone.
                        if path != rel && self.dir.join(&path).exists() {
                            continue;
                        }
                        self.hashed.remove(&path);
                        self.publish_delete(path, base, report).await?;
                    }
                }
                Err(e) => {
                    return Err(e)
                        .with_context(|| format!("stat {}", self.dir.join(&rel).display()));
                }
            }
        }
        Ok(())
    }

    /// Delete `rel` from the store at its agreed version (it is gone here).
    async fn publish_delete(&mut self, rel: String, base: Base, report: &mut Report) -> Result<()> {
        match self.client.delete(self.scope, &rel, base.version, &self.host).await? {
            Wrote::Ok { version } => {
                self.state.files.insert(rel.clone(), Base { version, sha256: String::new() });
                report.deleted.push(rel);
            }
            Wrote::Conflict(_) => {
                // Changed there since: it comes back here at the store's version.
                self.state.files.remove(&rel);
                if let Some(theirs) = self.client.get(self.scope, &rel).await?
                    && self.write_local(&rel, &theirs, None)?
                {
                    let version = self.client_version(&rel).await?.unwrap_or(base.version);
                    self.record(&rel, version, &theirs);
                    report.pulled.push(rel);
                }
            }
            Wrote::SecretRefused | Wrote::TooLarge => {}
        }
        Ok(())
    }

    /// The store's version of `rel`, from its whole tree.
    async fn client_version(&self, rel: &str) -> Result<Option<u64>> {
        let tree = self.client.tree(self.scope, 0).await?;
        Ok(tree.entries.iter().find(|e| e.path == rel).map(|e| e.version))
    }

    async fn publish(
        &mut self,
        rel: &str,
        scanned: Option<Stamp>,
        report: &mut Report,
    ) -> Result<()> {
        // Unchanged since it was last hashed, and agreed or refused at that hash: nothing to do,
        // without reading it.
        if let Some(stamp) = scanned
            && let Some((known, sha)) = self.hashed.get(rel)
            && *known == stamp
            && (self.state.files.get(rel).is_some_and(|b| &b.sha256 == sha)
                || self.state.refused.get(rel).is_some_and(|r| &r.sha256 == sha))
        {
            return Ok(());
        }
        for _ in 0..3 {
            let stamp =
                std::fs::symlink_metadata(self.dir.join(rel)).ok().and_then(|m| Stamp::of(&m));
            let Some(bytes) = self.read_local(rel)? else {
                return Ok(());
            };
            let sha = sha256_hex(&bytes);
            self.hashed_reads += 1;
            match stamp {
                Some(stamp) => self.hashed.insert(rel.to_owned(), (stamp, sha.clone())),
                None => self.hashed.remove(rel),
            };
            let base = self.state.files.get(rel).cloned();
            if base.as_ref().is_some_and(|b| b.sha256 == sha) {
                return Ok(());
            }
            if self.state.refused.get(rel).is_some_and(|r| r.sha256 == sha) {
                return Ok(());
            }
            if crate::artifacts_sync::should_skip(rel, &bytes) {
                self.refuse(rel, sha, "secret (local scan)", report);
                return Ok(());
            }
            let if_match = base.as_ref().map(|b| b.version).unwrap_or(0);
            let mtime = mtime_ms(&self.dir.join(rel));
            match self
                .client
                .put(self.scope, rel, bytes.clone(), if_match, mtime, &self.host)
                .await?
            {
                Wrote::Ok { version } => {
                    self.record(rel, version, &bytes);
                    self.state.refused.remove(rel);
                    report.pushed.push(rel.to_owned());
                    return Ok(());
                }
                Wrote::SecretRefused => {
                    self.refuse(rel, sha, "memory.secret_refused", report);
                    return Ok(());
                }
                Wrote::TooLarge => {
                    self.refuse(rel, sha, "memory.too_large", report);
                    return Ok(());
                }
                Wrote::Conflict(current) => {
                    // Merge the store's version in (the pull does it), then try again on top.
                    self.pull(report).await?;
                    let now = self.state.files.get(rel).map(|b| b.version).unwrap_or(0);
                    if now == if_match {
                        // The tree did not move this path past our base: take the store's
                        // version as the 409 named it and resolve against it directly.
                        let Some(current) = current else {
                            anyhow::bail!("memory put {rel}: conflict without the store's version");
                        };
                        let theirs = self.client.get(self.scope, rel).await?.unwrap_or_default();
                        let base_bytes = base
                            .as_ref()
                            .filter(|b| !b.sha256.is_empty())
                            .and_then(|b| self.read_base(&b.sha256))
                            .unwrap_or_default();
                        self.resolve(rel, current.version, &base_bytes, &bytes, &theirs, report)?;
                    }
                }
            }
        }
        Ok(())
    }

    fn refuse(&mut self, rel: &str, sha: String, reason: &str, report: &mut Report) {
        tracing::warn!("memory sync: {rel} not published: {reason}");
        self.state
            .refused
            .insert(rel.to_owned(), Refused { sha256: sha, reason: reason.to_owned() });
        report.refused.push(rel.to_owned());
    }

    fn record(&mut self, rel: &str, version: u64, bytes: &[u8]) {
        let sha = sha256_hex(bytes);
        let blob = self.state_dir.join("bases").join(&sha);
        if !blob.exists() {
            let _ = write_atomic(&blob, bytes);
        }
        self.state.files.insert(rel.to_owned(), Base { version, sha256: sha });
    }

    fn read_base(&self, sha: &str) -> Option<Vec<u8>> {
        std::fs::read(self.state_dir.join("bases").join(sha)).ok()
    }

    fn prune_bases(&self) {
        let keep: BTreeSet<&str> = self.state.files.values().map(|b| b.sha256.as_str()).collect();
        let Ok(entries) = std::fs::read_dir(self.state_dir.join("bases")) else {
            return;
        };
        for entry in entries.flatten() {
            let name = entry.file_name();
            let name = name.to_string_lossy();
            if !keep.contains(name.as_ref()) && name.len() == 64 {
                let _ = crate::home_fs::remove_file(entry.path());
            }
        }
    }

    /// Write the whole state as a new snapshot and start an empty log after it.
    pub fn save(&mut self) -> Result<()> {
        self.state.log_epoch += 1;
        let bytes = serde_json::to_vec(&self.state)?;
        write_atomic(&self.state_dir.join("state.json"), &bytes)
            .context("save the memory sync state")?;
        // The old log's lines carry the old epoch, so a crash before this leaves them ignored.
        write_atomic(&self.state_dir.join("state.log"), b"")
            .context("reset the memory sync log")?;
        self.state_bytes_written += bytes.len() as u64;
        self.snapshot_bytes = bytes.len() as u64;
        self.log_bytes = 0;
        self.compact_due = false;
        self.saved = Some(self.state.clone());
        Ok(())
    }

    /// Append what moved since the last save as one `state.log` line.
    fn append(&mut self, saved: &State) -> std::io::Result<Delta> {
        use std::io::Write as _;
        let delta = Delta::between(saved, &self.state);
        let mut line = serde_json::to_vec(&delta)?;
        line.push(b'\n');
        let mut log = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(self.state_dir.join("state.log"))?;
        log.write_all(&line)?;
        self.log_bytes += line.len() as u64;
        self.state_bytes_written += line.len() as u64;
        Ok(delta)
    }

    /// Save only when the pass changed the state (`last_ok` alone at most once a minute), as a
    /// log line of what moved; a snapshot only once the log outgrows it. Bases are pruned on a
    /// full pass or a snapshot. A pull per remote change on a folder of thousands of files
    /// otherwise rewrote two megabytes of JSON and listed every base, about once a second.
    fn save_if_changed(&mut self) -> Result<()> {
        let (files_moved, changed) = match &self.saved {
            None => (true, true),
            Some(saved) => {
                let s = &self.state;
                let files_moved = s.files != saved.files;
                let clock = s.last_ok.unwrap_or(0).saturating_sub(saved.last_ok.unwrap_or(0)) >= 60;
                let changed = files_moved
                    || clock
                    || s.last_seq != saved.last_seq
                    || s.refused != saved.refused
                    || s.last_error != saved.last_error
                    || s.remote_seq != saved.remote_seq;
                (files_moved, changed)
            }
        };
        if !changed {
            return Ok(());
        }
        let compact = self.compact_due
            || self.log_bytes > LOG_COMPACT_BYTES.max(self.snapshot_bytes)
            || self.saved.is_none();
        if compact {
            self.save()?;
        } else if let Some(mut saved) = self.saved.take() {
            match self.append(&saved) {
                Ok(delta) => {
                    saved.apply(delta);
                    self.saved = Some(saved);
                }
                Err(e) => {
                    self.saved = Some(saved);
                    self.compact_due = true;
                    tracing::warn!("append the memory sync log: {e}; writing a snapshot");
                    self.save()?;
                }
            }
        }
        if files_moved && (self.prune_due || compact) {
            self.prune_bases();
            self.prune_due = false;
        }
        Ok(())
    }

    /// A regular file's bytes at `rel`, `None` when there is none (a symlink is none).
    fn read_local(&self, rel: &str) -> Result<Option<Vec<u8>>> {
        let path = self.dir.join(rel);
        match std::fs::symlink_metadata(&path) {
            Ok(meta) if meta.is_file() => {
                if meta.len() > MAX_FILE_BYTES {
                    return Ok(None);
                }
                Ok(Some(std::fs::read(&path).with_context(|| format!("read {}", path.display()))?))
            }
            Ok(_) => Ok(None),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
            Err(e) => Err(e).with_context(|| format!("stat {}", path.display())),
        }
    }

    /// Write `bytes` at `rel` atomically, only while the file there still has `expect` (its
    /// sha256; `None`: no file). False when it changed meanwhile (the next pass takes it).
    fn write_local(&self, rel: &str, bytes: &[u8], expect: Option<&str>) -> Result<bool> {
        let path = self.dir.join(rel);
        if let Some(parent) = path.parent() {
            crate::home_fs::create_dirs(parent)
                .with_context(|| format!("create {}", parent.display()))?;
        }
        let temp = temp_beside(&path);
        let written = {
            let _turn = crate::dead_temps::hold(&temp);
            fill_temp(&temp, bytes).with_context(|| format!("write {}", temp.display()))?;
            let now = self.read_local(rel)?.map(|b| sha256_hex(&b));
            if now.as_deref() == expect {
                crate::home_fs::rename(&temp, &path)
                    .with_context(|| format!("rename into {}", path.display()))?;
                true
            } else {
                let _ = crate::home_fs::remove_file(&temp);
                false
            }
        };
        sweep_dead_temps(&path);
        Ok(written)
    }

    fn remove_local(&self, rel: &str, expect: Option<&str>) -> Result<()> {
        let now = self.read_local(rel)?.map(|b| sha256_hex(&b));
        if now.as_deref() == expect {
            let path = self.dir.join(rel);
            crate::home_fs::remove_file(&path)
                .with_context(|| format!("remove {}", path.display()))?;
        }
        Ok(())
    }

    /// Every synced file under the folder, as `/`-separated relative paths. Symlinks are not
    /// followed; hidden, editor and oversized files are left out.
    /// Each comes with its [`Stamp`] from the same `stat`.
    fn scan(&mut self) -> Result<BTreeMap<String, Option<Stamp>>> {
        self.scans += 1;
        let mut out = BTreeMap::new();
        let mut stack = vec![(self.dir.clone(), String::new())];
        while let Some((dir, prefix)) = stack.pop() {
            let entries = match std::fs::read_dir(&dir) {
                Ok(entries) => entries,
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => continue,
                Err(e) => return Err(e).with_context(|| format!("read {}", dir.display())),
            };
            for entry in entries.flatten() {
                let Some(name) = entry.file_name().to_str().map(str::to_owned) else {
                    continue;
                };
                let rel = if prefix.is_empty() { name } else { format!("{prefix}/{name}") };
                if skipped_name(&rel) {
                    continue;
                }
                let Ok(kind) = entry.file_type() else { continue };
                if kind.is_dir() {
                    stack.push((entry.path(), rel));
                } else if kind.is_file()
                    && let Ok(meta) = entry.metadata()
                    && meta.len() <= MAX_FILE_BYTES
                {
                    out.insert(rel, Stamp::of(&meta));
                }
            }
        }
        Ok(out)
    }

    /// Paths changed here and not yet published.
    pub fn pending(&self) -> Vec<String> {
        pending(&self.dir, &self.state)
    }

    /// The daemon's loop: a full pass at start, then wait for a local change (300 ms quiet), a
    /// remote change (long-poll) or the next full pass, due 5 minutes after the last; failures
    /// back off up to 5 minutes, a store without the memory route 10. A remote wake pulls and a
    /// local one publishes the paths the watcher named, neither walking the folder; a watcher
    /// that lost events (or no watcher, for a remote wake) asks for the full pass instead.
    pub async fn run(mut self, shutdown: &tokio::sync::Notify) {
        let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel::<Change>();
        let watcher = watch_dir(&self.dir, tx);
        let mut backoff = Duration::from_secs(1);
        let mut next: Option<BTreeSet<String>> = None; // None: a full pass
        let mut last_full = tokio::time::Instant::now();
        loop {
            let full = next.is_none();
            let result = match next.take() {
                None => self.pass().await,
                Some(changed) => self.pass_changed(changed).await,
            };
            if full {
                last_full = tokio::time::Instant::now();
            }
            let wait = match result {
                Ok(report) => {
                    if report != Report::default() {
                        tracing::info!("memory sync {}: {report:?}", self.scope.as_str());
                    }
                    backoff = Duration::from_secs(1);
                    None
                }
                Err(e) if e.is::<NotDeployed>() => Some(Duration::from_secs(600)),
                Err(e) => {
                    tracing::warn!("memory sync {}: {e:#}", self.scope.as_str());
                    let wait = backoff;
                    backoff = (backoff * 2).min(Duration::from_secs(300));
                    Some(wait)
                }
            };
            // After a failure the next pass is a full one: what the failed pass held is not kept.
            let due_full = last_full + FULL_PASS_EVERY;
            let deadline = match wait {
                Some(wait) => tokio::time::Instant::now() + wait,
                None => due_full,
            };
            let mut changed = BTreeSet::new();
            let mut rescan = false;
            loop {
                let remote = async {
                    if wait.is_some() {
                        std::future::pending::<bool>().await
                    } else {
                        match self.client.watch(self.scope, self.state.last_seq).await {
                            Ok(tree) => !tree.entries.is_empty() || tree.seq > self.state.last_seq,
                            Err(_) => {
                                tokio::time::sleep(Duration::from_secs(15)).await;
                                false
                            }
                        }
                    }
                };
                tokio::select! {
                    _ = shutdown.notified() => return,
                    _ = tokio::time::sleep_until(deadline) => {
                        rescan = true;
                        break;
                    }
                    is_changed = remote => if is_changed {
                        // Without a watcher only a full pass sees local edits.
                        rescan |= watcher.is_none();
                        break;
                    },
                    Some(first) = rx.recv() => {
                        first.add_to(&mut changed, &mut rescan);
                        // Wait for 300 ms of quiet so an editor's burst is one pass.
                        loop {
                            tokio::select! {
                                _ = tokio::time::sleep(Duration::from_millis(300)) => break,
                                more = rx.recv() => match more {
                                    Some(more) => more.add_to(&mut changed, &mut rescan),
                                    None => break,
                                },
                            }
                        }
                        break;
                    }
                }
            }
            next = if rescan || wait.is_some() { None } else { Some(changed) };
        }
    }
}

/// How often the daemon's loop walks the whole folder, whatever the watcher said: the backstop
/// for an event the watcher never delivered.
const FULL_PASS_EVERY: Duration = Duration::from_secs(300);

/// What the folder watcher saw: synced paths that changed (folder-relative), or that it lost
/// events and only a full pass can tell.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Change {
    Paths(Vec<String>),
    Rescan,
}

impl Change {
    fn add_to(self, changed: &mut BTreeSet<String>, rescan: &mut bool) {
        match self {
            Change::Paths(paths) => changed.extend(paths),
            Change::Rescan => *rescan = true,
        }
    }
}

/// Paths under `dir` whose bytes are not their base's (and not refused as they are).
pub fn pending(dir: &Path, state: &State) -> Vec<String> {
    let mut out = Vec::new();
    let mut stack = vec![(dir.to_path_buf(), String::new())];
    let mut seen = BTreeSet::new();
    while let Some((d, prefix)) = stack.pop() {
        let Ok(entries) = std::fs::read_dir(&d) else { continue };
        for entry in entries.flatten() {
            let Some(name) = entry.file_name().to_str().map(str::to_owned) else { continue };
            let rel = if prefix.is_empty() { name } else { format!("{prefix}/{name}") };
            if skipped_name(&rel) {
                continue;
            }
            let Ok(kind) = entry.file_type() else { continue };
            if kind.is_dir() {
                stack.push((entry.path(), rel));
            } else if kind.is_file() {
                seen.insert(rel.clone());
                let Ok(bytes) = std::fs::read(entry.path()) else { continue };
                if bytes.len() as u64 > MAX_FILE_BYTES {
                    continue;
                }
                let sha = sha256_hex(&bytes);
                let agreed = state.files.get(&rel).is_some_and(|b| b.sha256 == sha);
                let refused = state.refused.get(&rel).is_some_and(|r| r.sha256 == sha);
                if !agreed && !refused {
                    out.push(rel);
                }
            }
        }
    }
    for (rel, base) in &state.files {
        if !base.sha256.is_empty() && !seen.contains(rel) {
            out.push(rel.clone());
        }
    }
    out.sort();
    out
}

/// A relative store path this folder may hold: `/`-separated plain parts, no `..`.
pub fn safe_rel(rel: &str) -> bool {
    !rel.is_empty()
        && !rel.starts_with('/')
        && !rel.contains('\\')
        && !rel.contains('\0')
        && rel.split('/').all(|p| !p.is_empty() && p != "." && p != "..")
}

/// The hidden copy a write of `path` fills before its rename: one name per file and process,
/// the same on every write, never one per write (each new name is one more path fseventsd keeps,
/// `dead_temps`). This process's writers of one name take turns (`dead_temps::hold`).
fn temp_beside(path: &Path) -> PathBuf {
    path.with_file_name(format!("{}{}", temp_prefix(path), std::process::id()))
}

fn temp_prefix(path: &Path) -> String {
    let name = path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    format!(".{name}.memtmp-")
}

/// Fill `temp` from nothing (0600 when new): the caller holds its turn, so no other writer of
/// this process fills it meanwhile.
fn fill_temp(temp: &Path, bytes: &[u8]) -> std::io::Result<()> {
    use std::io::Write as _;
    let mut file = crate::home_fs::create_file(temp)?;
    file.write_all(bytes)
}

/// Remove the copies of `path` a process that is gone left behind (`dead_temps::remove`).
fn sweep_dead_temps(path: &Path) {
    if let Some(dir) = path.parent() {
        crate::dead_temps::remove(dir, &temp_prefix(path));
    }
}

/// Write through a hidden temp beside `path`, then rename over it.
pub fn write_atomic(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    if let Some(parent) = path.parent() {
        crate::home_fs::create_dirs(parent)?;
    }
    let temp = temp_beside(path);
    let done = {
        let _turn = crate::dead_temps::hold(&temp);
        fill_temp(&temp, bytes).and_then(|()| crate::home_fs::rename(&temp, path)).inspect_err(
            |_| {
                let _ = crate::home_fs::remove_file(&temp);
            },
        )
    };
    sweep_dead_temps(path);
    done
}

fn mtime_ms(path: &Path) -> Option<u64> {
    let modified = std::fs::metadata(path).ok()?.modified().ok()?;
    Some(modified.duration_since(std::time::UNIX_EPOCH).ok()?.as_millis() as u64)
}

/// A recursive watcher on `dir` that sends the synced paths each change names, or
/// [`Change::Rescan`] when the backend says it dropped events.
fn watch_dir(
    dir: &Path,
    tx: tokio::sync::mpsc::UnboundedSender<Change>,
) -> Option<notify::RecommendedWatcher> {
    use notify::Watcher;
    let root = dir.to_path_buf();
    let mut watcher = notify::recommended_watcher(move |event: notify::Result<notify::Event>| {
        let Ok(event) = event else {
            // An error from the backend (an inotify queue overflow among them): events were lost.
            let _ = tx.send(Change::Rescan);
            return;
        };
        if let Some(change) = change_of(&root, &event) {
            let _ = tx.send(change);
        }
    })
    .inspect_err(|e| {
        tracing::warn!("memory sync: no folder watcher ({e}); passes run every 5 minutes")
    })
    .ok()?;
    watcher
        .watch(dir, notify::RecursiveMode::Recursive)
        .inspect_err(|e| tracing::warn!("memory sync: cannot watch {}: {e}", dir.display()))
        .ok()?;
    Some(watcher)
}

/// The change one watcher event names under `root`, if any.
pub fn change_of(root: &Path, event: &notify::Event) -> Option<Change> {
    if event.need_rescan() {
        return Some(Change::Rescan);
    }
    // notify's inotify asks IN_OPEN: a read is no change.
    if matches!(event.kind, notify::EventKind::Access(_)) {
        return None;
    }
    let paths: Vec<String> = event
        .paths
        .iter()
        .filter_map(|p| {
            let rel = p.strip_prefix(root).ok()?.to_str()?;
            let rel = rel.replace(std::path::MAIN_SEPARATOR, "/");
            (!rel.is_empty() && !skipped_name(&rel)).then_some(rel)
        })
        .collect();
    if event.paths.iter().any(|p| p == root) {
        // The folder itself changed (moved, replaced): its contents are not named.
        return Some(Change::Rescan);
    }
    (!paths.is_empty()).then_some(Change::Paths(paths))
}
