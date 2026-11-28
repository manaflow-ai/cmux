//! One side's folder: an index of path to content hash that only rehashes a file whose stat
//! changed, the gitignore rules the seed export uses, and the writes and deletes a round asks
//! for, each compare-and-swap against the state the round decided on.
//!
//! A file's state is its [`Hash`]: the SHA-256 of its bytes, with `+x` when it is executable,
//! or `l:` and the SHA-256 of the target for a symlink. Directories are not entries (as in git):
//! one appears when a file under it is written. Absent is `None`.
//!
//! Compare-and-swap: a write lands in a temporary file beside the path, then the path is checked
//! against the hash the round expected and only then renamed over it. A file someone saved in
//! between is never overwritten: the write answers [`Outcome::Changed`] with what is there now
//! and the next round decides again with it. The window left is between that check and the
//! rename (microseconds), the same one an editor's own atomic save has.

use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::fs;
use std::io::{self, Read as _};
use std::os::unix::fs::{MetadataExt as _, PermissionsExt as _};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

use ignore::gitignore::{Gitignore, GitignoreBuilder};
use sha2::{Digest as _, Sha256};

/// A file's state: see the module docs.
pub type Hash = String;

/// Where each side keeps nothing of the user's: never synced, never watched.
pub const STATE_NAMES: [&str; 2] = [".git", ".cmux-sync"];
/// Temporary files of an in-flight write.
pub const TMP_MARK: &str = ".cmux-sync-tmp-";
/// A file larger than this is not synced; the round reports it instead of skipping it silently.
pub const MAX_FILE_BYTES: u64 = 512 * 1024 * 1024;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct Stat {
    size: u64,
    mtime_ns: i128,
    ctime_ns: i128,
    ino: u64,
    mode: u32,
}

impl Stat {
    fn of(meta: &fs::Metadata) -> Self {
        Self {
            size: meta.len(),
            mtime_ns: i128::from(meta.mtime()) * 1_000_000_000 + i128::from(meta.mtime_nsec()),
            ctime_ns: i128::from(meta.ctime()) * 1_000_000_000 + i128::from(meta.ctime_nsec()),
            ino: meta.ino(),
            mode: meta.mode(),
        }
    }
}

#[derive(Clone, Debug)]
struct Entry {
    stat: Stat,
    hash: Hash,
}

/// What a write or delete found.
#[derive(Clone, Debug, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub enum Outcome {
    /// It landed; the path now holds the hash asked for (or is gone).
    Done,
    /// The path no longer held what the round expected: it holds this now, and nothing changed.
    Changed(Option<Hash>),
    /// It could not be done (permissions, disk full): the first line of the error.
    Failed(String),
}

/// One side's folder and its index.
pub struct Replica {
    root: PathBuf,
    index: BTreeMap<String, Entry>,
    /// The gitignore of each folder that has one, by its relative path ("" for the root).
    ignores: HashMap<String, Gitignore>,
    /// What a scan could not read (a folder, a file, a name, a .gitignore), reported once each
    /// as an alert; those paths keep their last known state rather than reading as deleted.
    pub alerts: Vec<String>,
    reported: BTreeSet<String>,
    /// Files hashed since the last [`Replica::take_hashed`] (the scan cost a bench reports).
    hashed: u64,
}

static TMP_SEQ: AtomicU64 = AtomicU64::new(0);

impl Replica {
    pub fn new(root: impl Into<PathBuf>) -> io::Result<Self> {
        let root = root.into();
        fs::create_dir_all(&root)?;
        let root = root.canonicalize()?;
        Ok(Self {
            root,
            index: BTreeMap::new(),
            ignores: HashMap::new(),
            alerts: Vec::new(),
            reported: BTreeSet::new(),
            hashed: 0,
        })
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    /// The folder as path to hash, from the index.
    pub fn tree(&self) -> BTreeMap<String, Hash> {
        self.index.iter().map(|(p, e)| (p.clone(), e.hash.clone())).collect()
    }

    pub fn get(&self, path: &str) -> Option<&Hash> {
        self.index.get(path).map(|e| &e.hash)
    }

    pub fn len(&self) -> usize {
        self.index.len()
    }

    pub fn is_empty(&self) -> bool {
        self.index.is_empty()
    }

    pub fn take_hashed(&mut self) -> u64 {
        std::mem::take(&mut self.hashed)
    }

    /// The relative path of an absolute one under the root, `None` outside it or for the root.
    pub fn relative(&self, abs: &Path) -> Option<String> {
        let rel = abs.strip_prefix(&self.root).ok()?;
        let s = rel.to_str()?;
        (!s.is_empty()).then(|| s.to_owned())
    }

    fn abs(&self, rel: &str) -> PathBuf {
        self.root.join(rel)
    }

    /// Whether a relative path is never synced: a state folder, a temporary write, or ignored by
    /// a `.gitignore` in any folder above it.
    pub fn ignored(&self, rel: &str, is_dir: bool) -> bool {
        let parts: Vec<&str> = rel.split('/').collect();
        if parts.iter().any(|p| STATE_NAMES.contains(p) || p.starts_with(TMP_MARK)) {
            return true;
        }
        // Each folder's .gitignore, from the root down, on the path relative to that folder.
        for depth in 0..parts.len() {
            let dir = parts[..depth].join("/");
            if let Some(gi) = self.ignores.get(&dir) {
                // Every ancestor folder of the path below `dir` counts too (an ignored folder
                // ignores what is in it).
                for end in depth + 1..=parts.len() {
                    let sub = parts[depth..end].join("/");
                    let sub_is_dir = end < parts.len() || is_dir;
                    if gi.matched(&sub, sub_is_dir).is_ignore() {
                        return true;
                    }
                }
            }
        }
        false
    }

    fn load_ignore(&mut self, dir_rel: &str) {
        let dir = if dir_rel.is_empty() { self.root.clone() } else { self.abs(dir_rel) };
        let file = dir.join(".gitignore");
        if file.is_file() {
            let mut b = GitignoreBuilder::new(&dir);
            if let Some(e) = b.add(&file) {
                self.report(
                    format!("{dir_rel}/.gitignore"),
                    format!(
                        "a .gitignore line is unusable, ignored: {}",
                        first_line(&e.to_string())
                    ),
                );
            }
            match b.build() {
                Ok(gi) => {
                    self.ignores.insert(dir_rel.to_owned(), gi);
                    return;
                }
                Err(e) => self.report(
                    format!("{dir_rel}/.gitignore"),
                    format!(
                        "a .gitignore is unusable, syncing as if absent: {}",
                        first_line(&e.to_string())
                    ),
                ),
            }
        }
        self.ignores.remove(dir_rel);
    }

    /// One alert per (key), until the key reads fine again.
    fn report(&mut self, key: String, reason: String) {
        if self.reported.insert(key.clone()) {
            self.alerts.push(format!("{reason}: {key}"));
        }
    }

    /// Walks the whole folder: every file's state, rehashing only what changed since the index
    /// saw it. Returns the paths whose state changed.
    pub fn full_scan(&mut self) -> BTreeSet<String> {
        let mut seen = BTreeSet::new();
        let mut changed = BTreeSet::new();
        self.ignores.clear();
        self.walk("", &mut seen, &mut changed);
        let gone: Vec<String> = self.index.keys().filter(|p| !seen.contains(*p)).cloned().collect();
        for p in gone {
            self.index.remove(&p);
            changed.insert(p);
        }
        changed
    }

    fn walk(&mut self, dir_rel: &str, seen: &mut BTreeSet<String>, changed: &mut BTreeSet<String>) {
        self.load_ignore(dir_rel);
        let dir = if dir_rel.is_empty() { self.root.clone() } else { self.abs(dir_rel) };
        let read = match fs::read_dir(&dir) {
            Ok(r) => r,
            Err(e) => {
                // Unreadable: what the index holds under it stays as it was, never "deleted".
                self.report(
                    format!("{dir_rel}/"),
                    format!(
                        "folder unreadable, its files keep their last state: {}",
                        first_line(&e.to_string())
                    ),
                );
                let prefix = if dir_rel.is_empty() { String::new() } else { format!("{dir_rel}/") };
                seen.extend(
                    self.index
                        .range(prefix.clone()..)
                        .take_while(|(p, _)| p.starts_with(&prefix))
                        .map(|(p, _)| p.clone()),
                );
                return;
            }
        };
        self.reported.remove(&format!("{dir_rel}/"));
        let mut names: Vec<(String, bool)> = vec![];
        for e in read {
            let e = match e {
                Ok(e) => e,
                Err(err) => {
                    self.report(
                        format!("{dir_rel}/"),
                        format!(
                            "folder listing broke off, its files keep their last state: {}",
                            first_line(&err.to_string())
                        ),
                    );
                    let prefix =
                        if dir_rel.is_empty() { String::new() } else { format!("{dir_rel}/") };
                    seen.extend(
                        self.index
                            .range(prefix.clone()..)
                            .take_while(|(p, _)| p.starts_with(&prefix))
                            .map(|(p, _)| p.clone()),
                    );
                    continue;
                }
            };
            let Ok(name) = e.file_name().into_string() else {
                self.report(
                    format!("{dir_rel}/{:?}", e.file_name()),
                    "name is not UTF-8, not synced".into(),
                );
                continue;
            };
            // file_type() does not follow symlinks: a link to a folder syncs as a link.
            let is_dir = e.file_type().is_ok_and(|t| t.is_dir());
            names.push((name, is_dir));
        }
        names.sort();
        for (name, is_dir) in names {
            let rel = if dir_rel.is_empty() { name } else { format!("{dir_rel}/{name}") };
            if is_dir {
                if !self.ignored(&rel, true) {
                    self.walk(&rel, seen, changed);
                }
            } else if !self.ignored(&rel, false) {
                seen.insert(rel.clone());
                if self.refresh(&rel) {
                    changed.insert(rel);
                }
            }
        }
    }

    /// Reads the state of the paths a watcher named (files, folders, or paths now gone) into the
    /// index. A folder is walked; a gone folder drops every entry under it. Returns the paths
    /// whose state changed.
    pub fn rescan_paths(&mut self, paths: impl IntoIterator<Item = String>) -> BTreeSet<String> {
        let mut changed = BTreeSet::new();
        for rel in paths {
            let abs = self.abs(&rel);
            match fs::symlink_metadata(&abs) {
                Ok(meta) if meta.is_dir() => {
                    if rel.rsplit('/').next().is_some_and(|n| STATE_NAMES.contains(&n)) {
                        continue;
                    }
                    let mut seen = BTreeSet::new();
                    self.walk(&rel, &mut seen, &mut changed);
                    let prefix = format!("{rel}/");
                    let gone: Vec<String> = self
                        .index
                        .range(prefix.clone()..)
                        .take_while(|(p, _)| p.starts_with(&prefix))
                        .filter(|(p, _)| !seen.contains(*p))
                        .map(|(p, _)| p.clone())
                        .collect();
                    for p in gone {
                        self.index.remove(&p);
                        changed.insert(p);
                    }
                    if self.index.remove(&rel).is_some() {
                        changed.insert(rel);
                    }
                }
                Ok(_) => {
                    if rel.ends_with(".gitignore") {
                        let dir = rel.rsplit_once('/').map_or("", |(d, _)| d).to_owned();
                        self.load_ignore(&dir);
                    }
                    if self.ignored(&rel, false) {
                        if self.index.remove(&rel).is_some() {
                            changed.insert(rel);
                        }
                    } else if self.refresh(&rel) {
                        changed.insert(rel);
                    }
                }
                Err(e) if e.kind() != io::ErrorKind::NotFound => {
                    self.report(
                        rel.clone(),
                        format!("not synced, stat failed: {}", first_line(&e.to_string())),
                    );
                }
                Err(_) => {
                    // Gone: the file, or a folder and everything under it.
                    if self.index.remove(&rel).is_some() {
                        changed.insert(rel.clone());
                    }
                    let prefix = format!("{rel}/");
                    let under: Vec<String> = self
                        .index
                        .range(prefix.clone()..)
                        .take_while(|(p, _)| p.starts_with(&prefix))
                        .map(|(p, _)| p.clone())
                        .collect();
                    for p in under {
                        self.index.remove(&p);
                        changed.insert(p);
                    }
                }
            }
        }
        changed
    }

    /// Reads one file's state into the index; true when it changed.
    fn refresh(&mut self, rel: &str) -> bool {
        let before = self.index.get(rel).map(|e| e.hash.clone());
        self.sync_index(rel);
        before != self.index.get(rel).map(|e| e.hash.clone())
    }

    /// The index follows the disk; a path that cannot be read keeps its last state (an alert
    /// says why), so an unreadable file never reads as a delete.
    fn sync_index(&mut self, rel: &str) -> Now {
        let now = self.state_now(rel);
        match &now {
            Now::Present(e) => {
                self.reported.remove(rel);
                self.index.insert(rel.to_owned(), e.clone());
            }
            Now::Absent => {
                self.reported.remove(rel);
                self.index.remove(rel);
            }
            Now::Unknown(why) => self.report(rel.to_owned(), format!("not synced, {why}")),
        }
        now
    }

    /// What is at the path on disk now, trusting the index when the stat is unchanged.
    fn state_now(&mut self, rel: &str) -> Now {
        let abs = self.abs(rel);
        let meta = match fs::symlink_metadata(&abs) {
            Ok(m) => m,
            Err(e) if e.kind() == io::ErrorKind::NotFound => return Now::Absent,
            Err(e) => return Now::Unknown(format!("stat failed: {}", first_line(&e.to_string()))),
        };
        if meta.is_dir() {
            return Now::Absent;
        }
        let stat = Stat::of(&meta);
        if let Some(e) = self.index.get(rel)
            && e.stat == stat
        {
            return Now::Present(e.clone());
        }
        if meta.file_type().is_symlink() {
            return match fs::read_link(&abs) {
                Ok(target) => {
                    self.hashed += 1;
                    Now::Present(Entry {
                        stat,
                        hash: format!("l:{}", sha_hex(target.as_os_str().as_encoded_bytes())),
                    })
                }
                Err(e) => Now::Unknown(format!("readlink failed: {}", first_line(&e.to_string()))),
            };
        }
        if !meta.is_file() {
            return Now::Unknown("not a file, folder or symlink".into());
        }
        if meta.len() > MAX_FILE_BYTES {
            return Now::Unknown(format!("over {} MiB", MAX_FILE_BYTES >> 20));
        }
        let mut h = Sha256::new();
        let read = (|| -> io::Result<()> {
            let mut f = fs::File::open(&abs)?;
            let mut buf = vec![0u8; 256 * 1024];
            loop {
                let n = f.read(&mut buf)?;
                if n == 0 {
                    return Ok(());
                }
                h.update(&buf[..n]);
            }
        })();
        if let Err(e) = read {
            return Now::Unknown(format!("read failed: {}", first_line(&e.to_string())));
        }
        self.hashed += 1;
        let exec = meta.mode() & 0o111 != 0;
        let hex = hex(&h.finalize());
        Now::Present(Entry { stat, hash: if exec { format!("{hex}+x") } else { hex } })
    }

    /// The bytes at the path and their hash now (the index follows), or `None` when absent. For
    /// a symlink the bytes are its target.
    pub fn read(&mut self, rel: &str) -> io::Result<Option<(Hash, Vec<u8>)>> {
        let abs = self.abs(rel);
        let meta = match fs::symlink_metadata(&abs) {
            Ok(m) => m,
            Err(e) if e.kind() == io::ErrorKind::NotFound => {
                self.index.remove(rel);
                return Ok(None);
            }
            Err(e) => return Err(e),
        };
        let bytes = if meta.file_type().is_symlink() {
            fs::read_link(&abs)?.as_os_str().as_encoded_bytes().to_vec()
        } else if meta.is_file() {
            fs::read(&abs)?
        } else {
            return Ok(None);
        };
        let hash = hash_of(&bytes, meta.file_type().is_symlink(), meta.mode() & 0o111 != 0);
        // The bytes read are the truth; a write racing the read shows up as a new watcher event.
        self.index.insert(rel.to_owned(), Entry { stat: Stat::of(&meta), hash: hash.clone() });
        Ok(Some((hash, bytes)))
    }

    /// Puts `bytes` (with state `hash`) at the path if it still holds `expect`.
    pub fn write(&mut self, rel: &str, expect: Option<&str>, hash: &str, bytes: &[u8]) -> Outcome {
        match self.write_inner(rel, expect, hash, bytes) {
            Ok(o) => o,
            Err(e) => Outcome::Failed(first_line(&e.to_string())),
        }
    }

    fn write_inner(
        &mut self,
        rel: &str,
        expect: Option<&str>,
        hash: &str,
        bytes: &[u8],
    ) -> io::Result<Outcome> {
        if !safe_rel(rel) {
            return Ok(Outcome::Failed(format!("unsafe path {rel:?}")));
        }
        let abs = self.abs(rel);
        let parent = abs.parent().unwrap_or(&self.root).to_path_buf();
        // A file in the way of a parent folder (the other side made `a/b`, this side has a file
        // `a`) is a conflict the round sees on `a`; here it only fails.
        fs::create_dir_all(&parent)?;
        let name = abs.file_name().and_then(|n| n.to_str()).unwrap_or("f");
        let seq = TMP_SEQ.fetch_add(1, Ordering::Relaxed);
        let tmp = parent.join(format!("{TMP_MARK}{}-{seq}-{name}", std::process::id()));
        let is_link = hash.starts_with("l:");
        if is_link {
            let target = std::ffi::OsStr::from_bytes_lossless(bytes);
            std::os::unix::fs::symlink(target, &tmp)?;
        } else {
            fs::write(&tmp, bytes)?;
            let mode = if hash.ends_with("+x") { 0o755 } else { 0o644 };
            fs::set_permissions(&tmp, fs::Permissions::from_mode(mode))?;
        }
        let now = match self.sync_index(rel) {
            Now::Present(e) => Some(e.hash),
            Now::Absent => None,
            Now::Unknown(why) => {
                let _ = fs::remove_file(&tmp);
                return Ok(Outcome::Failed(why));
            }
        };
        if now.as_deref() != expect {
            let _ = fs::remove_file(&tmp);
            return Ok(Outcome::Changed(now));
        }
        if let Err(e) = fs::rename(&tmp, &abs) {
            let _ = fs::remove_file(&tmp);
            return Err(e);
        }
        if let Ok(meta) = fs::symlink_metadata(&abs) {
            self.index
                .insert(rel.to_owned(), Entry { stat: Stat::of(&meta), hash: hash.to_owned() });
        }
        Ok(Outcome::Done)
    }

    /// Removes the path if it still holds `expect`; empty folders it leaves are removed too.
    pub fn delete(&mut self, rel: &str, expect: &str) -> Outcome {
        if !safe_rel(rel) {
            return Outcome::Failed(format!("unsafe path {rel:?}"));
        }
        let now = match self.sync_index(rel) {
            Now::Present(e) => Some(e.hash),
            Now::Absent => None,
            Now::Unknown(why) => return Outcome::Failed(why),
        };
        if now.as_deref() != Some(expect) {
            return if now.is_none() { Outcome::Done } else { Outcome::Changed(now) };
        }
        let abs = self.abs(rel);
        if let Err(e) = fs::remove_file(&abs)
            && e.kind() != io::ErrorKind::NotFound
        {
            return Outcome::Failed(first_line(&e.to_string()));
        }
        self.index.remove(rel);
        let mut dir = abs.parent().map(Path::to_path_buf);
        while let Some(d) = dir {
            if d == self.root || fs::remove_dir(&d).is_err() {
                break;
            }
            dir = d.parent().map(Path::to_path_buf);
        }
        Outcome::Done
    }
}

/// A path's state on disk, or why it could not be read.
enum Now {
    Present(Entry),
    Absent,
    Unknown(String),
}

/// A relative path that stays under the root and names nothing of the state folders.
pub fn safe_rel(rel: &str) -> bool {
    !rel.is_empty()
        && !rel.starts_with('/')
        && rel
            .split('/')
            .all(|p| !p.is_empty() && p != "." && p != ".." && !STATE_NAMES.contains(&p))
}

/// The state of bytes as a file (or a symlink's target).
pub fn hash_of(bytes: &[u8], symlink: bool, exec: bool) -> Hash {
    let hex = sha_hex(bytes);
    if symlink {
        format!("l:{hex}")
    } else if exec {
        format!("{hex}+x")
    } else {
        hex
    }
}

fn sha_hex(bytes: &[u8]) -> String {
    hex(&Sha256::digest(bytes))
}

fn hex(bytes: &[u8]) -> String {
    use std::fmt::Write as _;
    let mut s = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        let _ = write!(s, "{b:02x}");
    }
    s
}

pub fn first_line(s: &str) -> String {
    s.lines().next().unwrap_or("").chars().take(300).collect()
}

trait FromBytesLossless {
    fn from_bytes_lossless(bytes: &[u8]) -> &std::ffi::OsStr;
}

impl FromBytesLossless for std::ffi::OsStr {
    fn from_bytes_lossless(bytes: &[u8]) -> &std::ffi::OsStr {
        use std::os::unix::ffi::OsStrExt as _;
        std::ffi::OsStr::from_bytes(bytes)
    }
}
