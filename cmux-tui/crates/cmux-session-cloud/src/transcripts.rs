//! Read-only cloud copies of the agents' own transcripts: Claude Code's `~/.claude/projects/**.jsonl`
//! and Codex's `~/.codex/sessions/**/rollout-*.jsonl`.
//!
//! Leo, 2026-11-25: "we also want to be offering up session history offloading and auto deletion i
//! think". These files are the agents', not acpmux's: a pass never rewrites one. It copies each file
//! idle past the cutoff to the person's store, sealed with their key like a chat archive
//! ([`crate::offload::upload`]), then reads the copy back and checks its hash. A ledger in the state
//! folder (`session-cloud-transcripts.json`) names every copy, so an unchanged file is not sent twice
//! and a changed one is copied again.
//!
//! Removing the local file is a second opt-in ([`Policy::delete_local`], off by default). It happens
//! only after the copy was read back in the same pass and its plaintext hash matched the file's
//! bytes, and only while the file still holds those bytes; it leaves the usual stub
//! (`<file>.cloud`, [`crate::offload::commit`]) as the tombstone. [`restore`] brings files back
//! (fetch on open, by session id) and [`restore_all`] undoes every removal.
//!
//! A dry run ([`pass`] with `dry_run`) needs no cloud and changes nothing: it lists what would be
//! copied and what would be removed, with sizes.

use crate::Cloud;
use crate::seal;
use crate::stub::{self, Stub};
use anyhow::{Context, bail};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, HashSet};
use std::path::{Path, PathBuf};

/// The ledger, in the state folder next to `session-cloud.json`.
pub const LEDGER_FILE: &str = "session-cloud-transcripts.json";
/// Taken by [`lock`].
pub const LOCK_FILE: &str = "session-cloud-transcripts.lock";
/// How many files a report lists by name; the totals count every one.
pub const REPORT_FILES: usize = 200;

/// Where each agent keeps its transcripts, under the home folder, and how deep they sit.
const SOURCES: &[(&str, &str, usize)] = &[
    // ~/.codex/sessions/YYYY/MM/DD/rollout-<time>-<sid>.jsonl
    ("codex", ".codex/sessions", 4),
    // ~/.claude/projects/<cwd>/<sid>.jsonl, and <sid>/subagents/agent-*.jsonl
    ("claude", ".claude/projects", 4),
];

/// What a pass may do.
#[derive(Debug, Clone)]
pub struct Policy {
    /// Files modified more recently than this many milliseconds ago are left alone (live chats).
    pub older_than_ms: u64,
    /// Remove a local file once its copy is verified. Off by default.
    pub delete_local: bool,
    /// Session ids never removed locally (pinned or starred chats). They are still copied.
    pub keep: HashSet<String>,
    /// Asked again under the ledger lock right before a file goes, for its session id: a chat
    /// opened since the pass began (and so missing from `keep`) is kept too.
    pub kept_now: KeptNow,
    /// Now, in milliseconds since the epoch.
    pub now_ms: u64,
}

/// [`Policy::kept_now`]: None keeps only `keep`.
#[derive(Clone, Default)]
pub struct KeptNow(pub Option<KeptFn>);

/// Whether a session id is kept, asked now.
pub type KeptFn = std::sync::Arc<dyn Fn(&str) -> bool + Send + Sync>;

impl KeptNow {
    fn kept(&self, sid: &str) -> bool {
        self.0.as_ref().is_some_and(|kept| kept(sid))
    }
}

impl std::fmt::Debug for KeptNow {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(if self.0.is_some() { "KeptNow(asked)" } else { "KeptNow(none)" })
    }
}

/// One copy in the ledger.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Entry {
    #[serde(flatten)]
    pub stub: Stub,
    /// The file's size and mtime when it was copied: a file whose either differs is copied again.
    pub size: u64,
    pub mtime_ms: u64,
    /// Set when the local file was removed after the copy was verified.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub removed_at_ms: Option<u64>,
}

/// Every copy this machine made, by path relative to the home folder.
#[derive(Debug, Default, Clone, Serialize, Deserialize)]
pub struct Ledger {
    pub v: u32,
    pub files: BTreeMap<String, Entry>,
}

impl Ledger {
    pub fn load(state: &Path) -> anyhow::Result<Self> {
        match std::fs::read(state.join(LEDGER_FILE)) {
            Ok(bytes) => serde_json::from_slice(&bytes)
                .with_context(|| format!("cannot parse {}", state.join(LEDGER_FILE).display())),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                Ok(Self { v: 1, ..Self::default() })
            }
            Err(e) => Err(e.into()),
        }
    }

    pub fn save(&self, state: &Path) -> anyhow::Result<()> {
        std::fs::create_dir_all(state)?;
        crate::write_durable(&state.join(LEDGER_FILE), &serde_json::to_vec(self)?)?;
        Ok(())
    }

    /// Writes `changes` over the ledger on the disk, under the lock: entries a restore changed
    /// meanwhile and not in `changes` stay as it left them.
    fn merge(
        state: &Path,
        changes: &BTreeMap<String, Entry>,
        _lock: &std::fs::File,
    ) -> anyhow::Result<Self> {
        let mut ledger = Self::load(state)?;
        ledger.v = 1;
        if !changes.is_empty() {
            ledger.files.extend(changes.iter().map(|(k, v)| (k.clone(), v.clone())));
            ledger.save(state)?;
        }
        Ok(ledger)
    }

    /// Every blob the ledger names, for the GC root.
    pub fn blobs(&self) -> Vec<String> {
        let mut blobs: Vec<String> = self.files.values().map(|e| e.stub.blob.clone()).collect();
        blobs.sort();
        blobs.dedup();
        blobs
    }
}

/// One transcript on the disk.
#[derive(Debug, Clone)]
pub struct Found {
    pub agent: &'static str,
    /// Relative to the home folder, `/`-separated.
    pub rel: String,
    pub path: PathBuf,
    pub size: u64,
    pub mtime_ms: u64,
}

/// Held while a file is removed and while one is restored, so a chat opened mid-pass never
/// misses a file that is going.
fn lock(state: &Path) -> anyhow::Result<std::fs::File> {
    std::fs::create_dir_all(state)?;
    let file = std::fs::File::options()
        .create(true)
        .truncate(false)
        .write(true)
        .open(state.join(LOCK_FILE))?;
    file.lock()?;
    Ok(file)
}

/// Every transcript under `home`, sorted by path. Symlinks are not followed.
pub fn scan(home: &Path) -> Vec<Found> {
    let mut out = Vec::new();
    for (agent, dir, depth) in SOURCES {
        walk(home, &home.join(dir), *depth, agent, &mut out);
    }
    out.sort_by(|a, b| a.rel.cmp(&b.rel));
    out
}

fn walk(home: &Path, dir: &Path, depth: usize, agent: &'static str, out: &mut Vec<Found>) {
    let Ok(read) = std::fs::read_dir(dir) else { return };
    for entry in read.flatten() {
        let Ok(kind) = entry.file_type() else { continue };
        let path = entry.path();
        if kind.is_dir() {
            if depth > 0 {
                walk(home, &path, depth - 1, agent, out);
            }
            continue;
        }
        if !kind.is_file() {
            continue;
        }
        let name = entry.file_name();
        let Some(name) = name.to_str() else { continue };
        if !is_transcript(agent, name) {
            continue;
        }
        let Ok(meta) = entry.metadata() else { continue };
        let Ok(rel) = path.strip_prefix(home) else { continue };
        let Some(rel) = rel.to_str() else { continue };
        out.push(Found {
            agent,
            rel: rel.replace(std::path::MAIN_SEPARATOR, "/"),
            path: path.clone(),
            size: meta.len(),
            mtime_ms: mtime_ms(&meta),
        });
    }
}

fn is_transcript(agent: &str, name: &str) -> bool {
    name.ends_with(".jsonl") && (agent != "codex" || name.starts_with("rollout-"))
}

fn mtime_ms(meta: &std::fs::Metadata) -> u64 {
    meta.modified()
        .ok()
        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
        .map_or(0, |d| d.as_millis() as u64)
}

/// Whether the transcript at `rel` belongs to session `sid`: Codex's `rollout-<time>-<sid>.jsonl`,
/// Claude's `<sid>.jsonl` or anything under its `<sid>/` folder (subagents).
pub fn belongs_to(rel: &str, sid: &str) -> bool {
    if sid.is_empty() {
        return false;
    }
    let name = rel.rsplit('/').next().unwrap_or(rel);
    if rel.starts_with(".codex/") {
        return name.starts_with("rollout-") && name.ends_with(&format!("-{sid}.jsonl"));
    }
    name == format!("{sid}.jsonl") || rel.split('/').any(|part| part == sid)
}

/// The session id a transcript's path names, when it names one.
pub fn session_of(rel: &str) -> Option<String> {
    let name = rel.rsplit('/').next()?.strip_suffix(".jsonl")?;
    if rel.starts_with(".codex/") {
        // rollout-2026-01-01T00-00-00-<uuid>: a uuid is the last 5 dash-separated groups.
        let parts: Vec<&str> = name.split('-').collect();
        return (parts.len() >= 6)
            .then(|| parts.get(parts.len() - 5..).map_or_else(String::new, |tail| tail.join("-")));
    }
    // ~/.claude/projects/<cwd>/<sid>.jsonl or <cwd>/<sid>/subagents/agent-*.jsonl
    let parts: Vec<&str> = rel.split('/').collect();
    match parts.len() {
        4 => Some(name.to_string()),
        n if n > 4 => Some(parts[3].to_string()),
        _ => None,
    }
}

/// What a pass did, or with `dry_run` would do.
#[derive(Debug, Default, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Report {
    pub dry_run: bool,
    pub delete_local: bool,
    pub older_than_days: f64,
    /// Every transcript found, and their bytes.
    pub files: u64,
    pub bytes: u64,
    /// By agent: files and bytes found.
    pub by_agent: BTreeMap<String, (u64, u64)>,
    /// Copied to the store (or would be), and their bytes.
    pub copied: u64,
    pub copied_bytes: u64,
    /// Copied and sealed bytes in the store (a dry run's is not known).
    pub stored_bytes: u64,
    /// Already copied and unchanged.
    pub unchanged: u64,
    /// Removed locally after a verified copy (or would be), and their bytes.
    pub removed: u64,
    pub removed_bytes: u64,
    /// Left as they are, by why.
    pub skipped: BTreeMap<String, u64>,
    /// Blobs in the GC root after the pass.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub root_blobs: Option<usize>,
    /// The first [`REPORT_FILES`] errors, `path: step: error`.
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub errors: Vec<String>,
    /// The first [`REPORT_FILES`] files acted on: `(path, bytes, action)`.
    pub list: Vec<(String, u64, &'static str)>,
}

impl Report {
    fn skip(&mut self, why: &str) {
        *self.skipped.entry(why.to_string()).or_default() += 1;
    }

    fn error(&mut self, rel: &str, step: &str, e: &anyhow::Error) {
        if self.errors.len() < REPORT_FILES {
            self.errors.push(format!("{rel}: {step}: {e:#}"));
        }
    }

    fn list(&mut self, rel: &str, bytes: u64, action: &'static str) {
        if self.list.len() < REPORT_FILES {
            self.list.push((rel.to_string(), bytes, action));
        }
    }
}

/// The GC root the transcript copies register under: like [`Cloud::root_pair`], a hash of the
/// key, with its own label so it never replaces the chat archives' tree.
pub fn root_pair(cloud: &Cloud) -> String {
    let id = crate::sha256_hex(
        &[b"cmux-session-cloud transcripts root\0".as_slice(), cloud.key.id_material()].concat(),
    );
    let short_id: String = id.chars().take(32).collect();
    format!("{}csh.{short_id}", cloud.root_prefix)
}

/// Reads `entry`'s copy back from the store and checks it: the blob's address, then the
/// plaintext's hash. Answers the plaintext.
pub fn read_back(cloud: &Cloud, record: &Stub) -> anyhow::Result<Vec<u8>> {
    let sealed = cloud.store.get(&record.blob)?;
    if crate::sha256_hex(&sealed) != record.blob {
        bail!("blob {} came back with other bytes", record.blob);
    }
    let plain = seal::open(&cloud.key, &sealed, record.plain_bytes as usize)?;
    if plain.len() as u64 != record.plain_bytes || crate::sha256_hex(&plain) != record.plain_sha256
    {
        bail!("blob {} decrypted to other bytes than were copied", record.blob);
    }
    Ok(plain)
}

/// One pass over `home`'s transcripts, with the ledger in `state`. `cloud` may be None only for a
/// dry run. `stop` is checked between two files.
pub fn pass(
    home: &Path,
    state: &Path,
    cloud: Option<&Cloud>,
    policy: &Policy,
    dry_run: bool,
    stop: &dyn Fn() -> bool,
) -> anyhow::Result<Report> {
    let cloud = match (cloud, dry_run) {
        (Some(cloud), _) => Some(cloud),
        (None, true) => None,
        (None, false) => bail!("cloud history is off: no session-cloud.json"),
    };
    let ledger = Ledger::load(state)?;
    let mut changes = BTreeMap::new();
    let mut report = Report {
        dry_run,
        delete_local: policy.delete_local,
        older_than_days: policy.older_than_ms as f64 / 86_400_000.0,
        ..Report::default()
    };
    let cutoff = policy.now_ms.saturating_sub(policy.older_than_ms);
    // Files to remove once every copy of this pass is in the ledger and the GC root.
    let mut to_remove: Vec<(Found, Entry, Option<String>)> = Vec::new();
    for found in scan(home) {
        report.files += 1;
        report.bytes += found.size;
        let agent = report.by_agent.entry(found.agent.to_string()).or_default();
        agent.0 += 1;
        agent.1 += found.size;
        if stop() {
            report.skip("stopped");
            continue;
        }
        if found.mtime_ms > cutoff {
            report.skip("recent");
            continue;
        }
        let current = ledger
            .files
            .get(&found.rel)
            .filter(|e| e.size == found.size && e.mtime_ms == found.mtime_ms)
            .cloned();
        let kept = session_of(&found.rel).is_some_and(|sid| policy.keep.contains(&sid));
        let remove = policy.delete_local && !kept;
        if dry_run {
            if current.is_some() {
                report.unchanged += 1;
            } else if found.size as usize > crate::store::MAX_BLOB {
                report.skip("over 64 MiB");
                continue;
            } else {
                report.copied += 1;
                report.copied_bytes += found.size;
            }
            if remove {
                report.removed += 1;
                report.removed_bytes += found.size;
                report.list(&found.rel, found.size, "would remove");
            } else {
                if kept && policy.delete_local {
                    report.skip("kept");
                }
                if current.is_none() {
                    report.list(&found.rel, found.size, "would copy");
                }
            }
            continue;
        }
        let Some(cloud) = cloud else { bail!("cloud history is off: no session-cloud.json") };
        let entry = match current {
            Some(entry) => {
                report.unchanged += 1;
                entry
            }
            None => match crate::offload::upload(&found.path, cloud) {
                Ok(record) => {
                    let entry = Entry {
                        stub: record,
                        size: found.size,
                        mtime_ms: found.mtime_ms,
                        removed_at_ms: None,
                    };
                    report.copied += 1;
                    report.copied_bytes += entry.stub.plain_bytes;
                    report.stored_bytes += entry.stub.stored_bytes;
                    report.list(&found.rel, found.size, "copied");
                    changes.insert(found.rel.clone(), entry.clone());
                    entry
                }
                Err(e) if e.to_string().contains("64 MiB") => {
                    report.skip("over 64 MiB");
                    continue;
                }
                Err(e) => {
                    report.error(&found.rel, "copy", &e);
                    report.skip("copy failed");
                    continue;
                }
            },
        };
        if !remove {
            if kept && policy.delete_local {
                report.skip("kept");
            }
            continue;
        }
        let sid = session_of(&found.rel);
        to_remove.push((found, entry, sid));
    }
    if dry_run {
        return Ok(report);
    }
    // Every copy of this pass goes into the ledger and the GC root before any file is removed,
    // so a pass that stops or crashes never leaves a removed file whose only copy a GC could
    // drop. Every pass sets the root, so it (90-day expiry) stays alive while the copies are
    // wanted.
    let ledger = Ledger::merge(state, &changes, &lock(state)?)?;
    let Some(cloud) = cloud else { return Ok(report) };
    if !ledger.files.is_empty() {
        let blobs = ledger.blobs();
        cloud.store.set_root(&root_pair(cloud), &blobs)?;
        report.root_blobs = Some(blobs.len());
    }
    for (found, entry, sid) in to_remove {
        if stop() {
            report.skip("stopped");
            continue;
        }
        // Removal: read the copy back now, whatever an earlier pass checked.
        if let Err(e) = read_back(cloud, &entry.stub) {
            report.error(&found.rel, "read-back", &e);
            report.skip("read-back failed");
            continue;
        }
        // `commit` removes the file only while it still holds the bytes copied; the stub it
        // leaves and the ledger row are on the disk before the lock goes.
        let held = match lock(state) {
            Ok(held) => held,
            Err(e) => {
                report.error(&found.rel, "lock", &e);
                report.skip("remove failed");
                continue;
            }
        };
        // Asked again now: a chat opened since the pass began is kept.
        if sid.as_deref().is_some_and(|sid| policy.kept_now.kept(sid)) {
            report.skip("kept");
            continue;
        }
        match crate::offload::commit(&found.path, &entry.stub) {
            Ok(Some(bytes)) => {
                report.removed += 1;
                report.removed_bytes += bytes;
                report.list(&found.rel, bytes, "removed");
                // Only this file's row: a row a restore wrote since stays as it is.
                let row = BTreeMap::from([(
                    found.rel.clone(),
                    Entry { removed_at_ms: Some(policy.now_ms), ..entry },
                )]);
                Ledger::merge(state, &row, &held)?;
            }
            Ok(None) => report.skip("changed"),
            Err(e) => {
                report.error(&found.rel, "remove", &e);
                report.skip("remove failed");
            }
        }
    }
    Ok(report)
}

/// Brings back every removed transcript of session `sid` (fetch on open). Answers how many came
/// back. A file already there is left as it is.
pub fn restore(home: &Path, state: &Path, cloud: &Cloud, sid: &str) -> anyhow::Result<usize> {
    restore_where(home, state, cloud, |rel| belongs_to(rel, sid))
}

/// Brings back every removed transcript (undo).
pub fn restore_all(home: &Path, state: &Path, cloud: &Cloud) -> anyhow::Result<usize> {
    restore_where(home, state, cloud, |_| true)
}

/// Whether any removed transcript of `sid` waits in the cloud: one `stat` when transcripts were
/// never offloaded here, else a ledger read under the lock; no store call. Under the lock, a
/// removal either went before (and this sees it) or comes after and asks
/// [`Policy::kept_now`] first.
pub fn needs_restore(home: &Path, state: &Path, sid: &str) -> bool {
    if !state.join(LEDGER_FILE).exists() {
        return false;
    }
    let _held = lock(state).ok();
    Ledger::load(state).is_ok_and(|ledger| {
        ledger.files.iter().any(|(rel, e)| belongs_to(rel, sid) && removed(home, rel, e))
    })
}

/// Gone from the disk with its copy in the cloud: the ledger says so, or its stub does (a pass
/// that stopped between the two).
fn removed(home: &Path, rel: &str, entry: &Entry) -> bool {
    let file = home.join(rel);
    !file.exists() && (entry.removed_at_ms.is_some() || stub::stub_path(&file).exists())
}

fn restore_where(
    home: &Path,
    state: &Path,
    cloud: &Cloud,
    want: impl Fn(&str) -> bool,
) -> anyhow::Result<usize> {
    let _held = lock(state)?;
    let mut ledger = Ledger::load(state)?;
    let mut back = 0;
    let mut first_error = None;
    for (rel, entry) in ledger.files.iter_mut() {
        if !want(rel) || (entry.removed_at_ms.is_none() && !removed(home, rel, entry)) {
            continue;
        }
        let file = home.join(rel);
        let stub_file = stub::stub_path(&file);
        let result = (|| -> anyhow::Result<()> {
            if !file.exists() {
                if !stub_file.exists() {
                    // The tombstone went too: write it again from the ledger.
                    crate::write_durable(&stub_file, &serde_json::to_vec(&entry.stub)?)?;
                }
                crate::fetch::fetch_file(&stub_file, cloud)?;
                back += 1;
            }
            match std::fs::remove_file(&stub_file) {
                Err(e) if e.kind() != std::io::ErrorKind::NotFound => return Err(e.into()),
                _ => {}
            }
            Ok(())
        })();
        match result {
            Ok(()) => {
                entry.removed_at_ms = None;
                // The file's mtime is now; record it so the next pass sees it as copied.
                if let Ok(meta) = std::fs::metadata(&file) {
                    entry.mtime_ms = mtime_ms(&meta);
                }
            }
            Err(e) => {
                first_error.get_or_insert(e.context(format!("cannot restore {rel}")));
            }
        }
    }
    ledger.save(state)?;
    match first_error {
        Some(e) if back == 0 => Err(e),
        _ => Ok(back),
    }
}

#[cfg(test)]
#[path = "transcripts_tests.rs"]
mod tests;
