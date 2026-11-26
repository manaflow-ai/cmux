//! One scope's sync: the folder, the state that says which store version each file was last
//! agreed at (with that version's bytes kept as the merge base), and the passes that move
//! changes both ways.
//!
//! A pass pulls (`tree?since=LAST_SEQ`, each entry applied by [`Engine::apply_remote`]) and then
//! pushes (each local file whose bytes are not its base's is PUT with `If-Match-Version` = the
//! base version; a file gone here is DELETEd the same way). A 409 pulls again, which merges the
//! store's version in, and tries once more.

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};
use std::time::Duration;

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
}

impl State {
    pub fn load(state_dir: &Path) -> State {
        std::fs::read(state_dir.join("state.json"))
            .ok()
            .and_then(|bytes| serde_json::from_slice(&bytes).ok())
            .unwrap_or_default()
    }
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
    _lock: cmux_file_lock::FileLock,
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
        let state = State::load(&state_dir);
        Ok(Engine { client, scope, dir, state_dir, host, state, _lock: lock })
    }

    pub fn dir(&self) -> &Path {
        &self.dir
    }

    /// Pull, then push; the state is saved either way.
    pub async fn pass(&mut self) -> Result<Report> {
        let mut report = Report::default();
        let result = async {
            self.pull(&mut report).await?;
            self.push(&mut report).await
        }
        .await;
        match &result {
            Ok(()) => {
                self.state.last_error = None;
                self.state.last_ok = Some(now_unix());
            }
            Err(e) => self.state.last_error = Some(format!("{e:#}")),
        }
        self.prune_bases();
        self.save()?;
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
                report.conflicts.push(side);
            }
        }
        Ok(())
    }

    /// Publish what changed here.
    pub async fn push(&mut self, report: &mut Report) -> Result<()> {
        let local = self.scan()?;
        for rel in &local {
            self.publish(rel, report).await?;
        }
        let gone: Vec<(String, Base)> = self
            .state
            .files
            .iter()
            .filter(|(rel, base)| !base.sha256.is_empty() && !local.contains(*rel))
            .map(|(rel, base)| (rel.clone(), base.clone()))
            .collect();
        for (rel, base) in gone {
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
        }
        Ok(())
    }

    /// The store's version of `rel`, from its whole tree.
    async fn client_version(&self, rel: &str) -> Result<Option<u64>> {
        let tree = self.client.tree(self.scope, 0).await?;
        Ok(tree.entries.iter().find(|e| e.path == rel).map(|e| e.version))
    }

    async fn publish(&mut self, rel: &str, report: &mut Report) -> Result<()> {
        for _ in 0..3 {
            let Some(bytes) = self.read_local(rel)? else {
                return Ok(());
            };
            let sha = sha256_hex(&bytes);
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

    pub fn save(&self) -> Result<()> {
        let bytes = serde_json::to_vec_pretty(&self.state)?;
        write_atomic(&self.state_dir.join("state.json"), &bytes)
            .context("save the memory sync state")
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
    pub fn scan(&self) -> Result<BTreeSet<String>> {
        let mut out = BTreeSet::new();
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
                    && entry.metadata().map(|m| m.len() <= MAX_FILE_BYTES).unwrap_or(false)
                {
                    out.insert(rel);
                }
            }
        }
        Ok(out)
    }

    /// Paths changed here and not yet published.
    pub fn pending(&self) -> Vec<String> {
        pending(&self.dir, &self.state)
    }

    /// The daemon's loop: a pass, then wait for a local change (300 ms quiet), a remote change
    /// (long-poll) or 5 minutes; failures back off up to 5 minutes, a store without the memory
    /// route 10.
    pub async fn run(mut self, shutdown: &tokio::sync::Notify) {
        let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel::<()>();
        let _watcher = watch_dir(&self.dir, tx);
        let mut backoff = Duration::from_secs(1);
        loop {
            let wait = match self.pass().await {
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
            let deadline = tokio::time::Instant::now() + wait.unwrap_or(Duration::from_secs(300));
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
                    _ = tokio::time::sleep_until(deadline) => break,
                    changed = remote => if changed { break },
                    Some(()) = rx.recv() => {
                        // Wait for 300 ms of quiet so an editor's burst is one pass.
                        loop {
                            tokio::select! {
                                _ = tokio::time::sleep(Duration::from_millis(300)) => break,
                                more = rx.recv() => if more.is_none() { break },
                            }
                        }
                        break;
                    }
                }
            }
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

/// A recursive watcher on `dir` that sends one `()` per change to a synced path.
fn watch_dir(
    dir: &Path,
    tx: tokio::sync::mpsc::UnboundedSender<()>,
) -> Option<notify::RecommendedWatcher> {
    use notify::Watcher;
    let root = dir.to_path_buf();
    let mut watcher = notify::recommended_watcher(move |event: notify::Result<notify::Event>| {
        let Ok(event) = event else { return };
        // notify's inotify asks IN_OPEN: a read is no change.
        if matches!(event.kind, notify::EventKind::Access(_)) {
            return;
        }
        let synced = event.paths.iter().any(|p| {
            p.strip_prefix(&root)
                .ok()
                .and_then(|rel| rel.to_str())
                .is_some_and(|rel| !rel.is_empty() && !skipped_name(rel))
        });
        if synced {
            let _ = tx.send(());
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
