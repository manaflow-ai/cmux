//! A git commit as a projection's lower layer, for lane VMs and CI (hq
//! `docs/investigations/prior-art-projected-checkouts-2026-11-18.md`, step 6): the manifest is the
//! commit's tree (`git ls-tree -r -l`), and a file's bytes are its blob, read from the host's own
//! git object store on first read. No Mac is in the loop and no file is written to make a checkout.
//!
//! Three things keep tools working on it:
//! - **Stable mtimes.** Each path's mtime comes from a [`Book`] kept beside the mount: a path whose
//!   blob is the one it had last time keeps last time's mtime, and a path with new content gets
//!   "now". That is what a disk checkout looks like to cargo, so a fresh checkout at the same
//!   commit and the same mount path leaves `target/` fresh, and changed files still rebuild.
//! - **Build output on the real disk.** `target/` next to every `Cargo.lock`, `node_modules/` next
//!   to every `package.json` and `.build/` next to every `Package.swift` are links to folders on
//!   the machine's disk ([`Projection::real_dirs`]), so a build writes no byte through the mount.
//! - **git's own state on the real disk.** `.git` is a file naming a worktree of the host's mirror
//!   ([`Worktree`]), whose index is written here with the stat data the mount serves, so
//!   `git status` matches every file by stat and reads none.

use std::collections::{BTreeSet, HashMap, VecDeque};
use std::io::{BufRead as _, BufReader, Read as _, Write as _};
use std::path::{Path, PathBuf};
use std::process::{ChildStdin, ChildStdout};

use cmux_process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Condvar, Mutex, PoisonError, Weak};
use std::time::{Duration, Instant};

use sha1::{Digest as _, Sha1};

use crate::manifest::{Case, Item, Kind, Manifest};
#[cfg(any(target_os = "linux", test))]
use crate::sparse::Sparse;
use crate::{Fetch, FetchError};

/// What one manifest entry's bytes are.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Source {
    /// A folder or a link: nothing to read.
    None,
    /// A blob of the object store, by its id (hex).
    Blob(String),
    /// Bytes made here (the `.git` file).
    Bytes(Vec<u8>),
}

/// One path of a commit's tree.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TreeItem {
    pub path: String,
    /// git's mode: `0o100644`, `0o100755`, `0o120000` (a link) or `0o160000` (a submodule).
    pub mode: u32,
    /// The blob's id, or the submodule's commit.
    pub oid: String,
    /// The blob's size (0 for a submodule).
    pub size: u64,
}

const LINK: u32 = 0o120_000;
const GITLINK: u32 = 0o160_000;

/// The object format of a repository and its index checksum.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ObjectFormat {
    Sha1,
    Sha256,
}

impl ObjectFormat {
    #[must_use]
    pub fn id_bytes(self) -> usize {
        match self {
            Self::Sha1 => 20,
            Self::Sha256 => 32,
        }
    }

    fn digest(self, bytes: &[u8]) -> Vec<u8> {
        match self {
            Self::Sha1 => Sha1::digest(bytes).to_vec(),
            Self::Sha256 => sha2::Sha256::digest(bytes).to_vec(),
        }
    }
}

/// Reads the repository's object format (`sha1` or `sha256`).
pub fn object_format(git_dir: &Path) -> anyhow::Result<ObjectFormat> {
    let mut command = git(git_dir);
    command.args(["rev-parse", "--show-object-format"]);
    let text = String::from_utf8(output(command)?)?;
    match text.trim() {
        "sha1" => Ok(ObjectFormat::Sha1),
        "sha256" => Ok(ObjectFormat::Sha256),
        other => Err(Unsupported(format!("object format {other:?}")).into()),
    }
}

/// A commit the projection cannot represent as text; callers should use an ordinary checkout.
#[derive(Debug)]
pub struct Unsupported(pub String);

impl std::fmt::Display for Unsupported {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}; make an ordinary checkout instead", self.0)
    }
}
impl std::error::Error for Unsupported {}

fn git(git_dir: &Path) -> Command {
    let mut command = Command::new("git");
    command.arg("--git-dir").arg(git_dir);
    command
}

fn output(mut command: Command) -> anyhow::Result<Vec<u8>> {
    let out = command.stderr(Stdio::piped()).output()?;
    anyhow::ensure!(
        out.status.success(),
        "{command:?} failed: {}",
        String::from_utf8_lossy(&out.stderr).trim()
    );
    Ok(out.stdout)
}

/// The full id and the committer time (seconds) of `rev`.
pub fn resolve(git_dir: &Path, rev: &str) -> anyhow::Result<(String, i64)> {
    let mut command = git(git_dir);
    command.args(["show", "-s", "--format=%H %ct"]).arg(format!("{rev}^{{commit}}"));
    let text = String::from_utf8(output(command)?)?;
    let (id, time) = text.trim().split_once(' ').ok_or_else(|| anyhow::anyhow!("bad commit"))?;
    Ok((id.to_owned(), time.parse()?))
}

/// The blobs `commit` names that the object store does not have (a partial clone's mirror).
pub fn missing(git_dir: &Path, commit: &str) -> anyhow::Result<Vec<String>> {
    let mut command = git(git_dir);
    command.args(["rev-list", "--objects", "--no-walk", "--missing=print", commit]);
    let text = String::from_utf8(output(command)?)?;
    Ok(text.lines().filter_map(|line| line.strip_prefix('?')).map(str::to_owned).collect())
}

/// Fetches `oids` from the mirror's promisor remote in one request, as `git checkout` does for a
/// partial clone.
pub fn fetch_missing(git_dir: &Path, oids: &[String]) -> anyhow::Result<()> {
    if oids.is_empty() {
        return Ok(());
    }
    let mut child = git(git_dir)
        .args(["-c", "fetch.negotiationAlgorithm=noop", "fetch", "origin", "--no-tags"])
        .args(["--no-write-fetch-head", "--recurse-submodules=no", "--filter=blob:none"])
        .arg("--stdin")
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .spawn()?;
    if let Some(mut stdin) = child.stdin.take() {
        for oid in oids {
            writeln!(stdin, "{oid}")?;
        }
    }
    anyhow::ensure!(child.wait()?.success(), "fetching {} missing blobs failed", oids.len());
    Ok(())
}

/// Every path of `commit`'s tree, in git's order.
pub fn ls_tree(git_dir: &Path, commit: &str) -> anyhow::Result<Vec<TreeItem>> {
    let mut command = git(git_dir);
    command.args(["ls-tree", "-r", "-l", "-z", "--full-tree", commit]);
    parse_ls_tree(&output(command)?)
}

/// [`ls_tree`], kept in `cache` (a file for this commit): the listing of a commit never changes,
/// and with a cold page cache `ls-tree -l` reads every blob's header out of the packs (about 11 s
/// for cmux's 58,000 files, against 0.2 s warm), so a remount after a reboot skips git. A commit
/// with no listing yet takes its sizes from the newest other listing in `cache`'s folder and asks
/// git only for the blobs that one lacks: `ls-tree` without sizes reads only trees (1.2 s cold
/// for cmux, against 11.9 s with them).
pub fn ls_tree_cached(git_dir: &Path, commit: &str, cache: &Path) -> anyhow::Result<Vec<TreeItem>> {
    if let Some(items) = std::fs::read(cache).ok().and_then(|bytes| parse_ls_tree(&bytes).ok()) {
        return Ok(items);
    }
    let bytes = match sizes_kept_beside(cache) {
        Some(sizes) => listing_with_sizes(git_dir, commit, &sizes)?,
        None => {
            let mut command = git(git_dir);
            command.args(["ls-tree", "-r", "-l", "-z", "--full-tree", commit]);
            output(command)?
        }
    };
    let items = parse_ls_tree(&bytes)?;
    if let Some(parent) = cache.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let temp = cache.with_extension(format!("tmp{}", std::process::id()));
    std::fs::write(&temp, &bytes)?;
    std::fs::rename(&temp, cache)?;
    Ok(items)
}

/// Each blob's size in the newest listing beside `cache` (its folder's other files), if any.
fn sizes_kept_beside(cache: &Path) -> Option<HashMap<String, u64>> {
    let newest = std::fs::read_dir(cache.parent()?)
        .ok()?
        .flatten()
        .filter(|entry| entry.path() != cache && !entry.file_name().to_string_lossy().contains('.'))
        .filter_map(|entry| Some((entry.metadata().ok()?.modified().ok()?, entry.path())))
        .max()?
        .1;
    let items = parse_ls_tree(&std::fs::read(newest).ok()?).ok()?;
    Some(items.into_iter().map(|item| (item.oid, item.size)).collect())
}

/// `ls-tree -r -l -z` output for `commit`, its sizes from `sizes` and, for blobs not in it,
/// from one `cat-file --batch-check`.
fn listing_with_sizes(
    git_dir: &Path,
    commit: &str,
    sizes: &HashMap<String, u64>,
) -> anyhow::Result<Vec<u8>> {
    let mut command = git(git_dir);
    command.args(["ls-tree", "-r", "-z", "--full-tree", commit]);
    let bytes = output(command)?;
    let mut rows = Vec::new();
    let mut unknown = BTreeSet::new();
    for record in bytes.split(|byte| *byte == 0).filter(|record| !record.is_empty()) {
        let record = std::str::from_utf8(record)
            .map_err(|_| Unsupported("a git path is not UTF-8".into()))?;
        let (head, path) =
            record.split_once('\t').ok_or_else(|| anyhow::anyhow!("bad ls-tree line"))?;
        let mut fields = head.split_whitespace();
        let (Some(mode), Some(kind), Some(oid)) = (fields.next(), fields.next(), fields.next())
        else {
            anyhow::bail!("bad ls-tree line {record:?}");
        };
        if kind == "blob" && !sizes.contains_key(oid) {
            unknown.insert(oid);
        }
        rows.push((mode, kind, oid, path));
    }
    let found = object_sizes(git_dir, &unknown)?;
    let mut listing = Vec::with_capacity(bytes.len() + rows.len() * 8);
    for (mode, kind, oid, path) in rows {
        if kind == "blob" {
            let size = sizes
                .get(oid)
                .or_else(|| found.get(oid))
                .ok_or_else(|| anyhow::anyhow!("no size for blob {oid}"))?;
            write!(listing, "{mode} {kind} {oid} {size}\t{path}\0")?;
        } else {
            write!(listing, "{mode} {kind} {oid} -\t{path}\0")?;
        }
    }
    Ok(listing)
}

/// The sizes of `oids` in one `cat-file --batch-check`.
fn object_sizes(git_dir: &Path, oids: &BTreeSet<&str>) -> anyhow::Result<HashMap<String, u64>> {
    if oids.is_empty() {
        return Ok(HashMap::new());
    }
    // The ids come from a file, not a pipe: a long answer can never block git while the ids are
    // still being written to it.
    let input: String = oids.iter().map(|oid| format!("{oid}\n")).collect();
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |since| since.as_nanos());
    let path =
        std::env::temp_dir().join(format!("cmux-projection-oids-{}-{nanos}", std::process::id()));
    std::fs::write(&path, input)?;
    let file = std::fs::File::open(&path);
    let _ = std::fs::remove_file(&path);
    let mut command = git(git_dir);
    command
        .args(["cat-file", "--batch-check=%(objectname) %(objectsize)"])
        .stdin(Stdio::from(file?))
        .stdout(Stdio::piped())
        .stderr(Stdio::null());
    let out = command.output()?;
    anyhow::ensure!(out.status.success(), "cat-file --batch-check failed");
    Ok(String::from_utf8_lossy(&out.stdout)
        .lines()
        .filter_map(|line| {
            let (oid, size) = line.split_once(' ')?;
            Some((oid.to_owned(), size.parse().ok()?))
        })
        .collect())
}

/// `git ls-tree -r -l -z` output as items: `MODE TYPE OID SIZE\tPATH\0`.
pub fn parse_ls_tree(bytes: &[u8]) -> anyhow::Result<Vec<TreeItem>> {
    let mut items = Vec::new();
    for record in bytes.split(|byte| *byte == 0).filter(|record| !record.is_empty()) {
        let record = std::str::from_utf8(record)
            .map_err(|_| Unsupported("a git path is not UTF-8".into()))?;
        let (head, path) =
            record.split_once('\t').ok_or_else(|| anyhow::anyhow!("bad ls-tree line"))?;
        let mut fields = head.split_whitespace();
        let (Some(mode), Some(_kind), Some(oid), Some(size)) =
            (fields.next(), fields.next(), fields.next(), fields.next())
        else {
            anyhow::bail!("bad ls-tree line {record:?}");
        };
        items.push(TreeItem {
            path: path.to_owned(),
            mode: u32::from_str_radix(mode, 8)?,
            oid: oid.to_owned(),
            size: if size == "-" { 0 } else { size.parse()? },
        });
    }
    Ok(items)
}

/// Each path's last blob and mtime at one mount path: the record that keeps mtimes the same for
/// the same content, checkout after checkout. One line per path: `OID MTIME_NS PATH`.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Book {
    paths: HashMap<String, (String, i64)>,
}

impl Book {
    /// The book at `file` (empty when there is none or it does not parse).
    #[must_use]
    pub fn load(file: &Path) -> Self {
        let Ok(text) = std::fs::read_to_string(file) else { return Self::default() };
        let mut paths = HashMap::new();
        for line in text.lines() {
            let mut parts = line.splitn(3, ' ');
            if let (Some(oid), Some(Ok(ns)), Some(path)) =
                (parts.next(), parts.next().map(str::parse::<i64>), parts.next())
            {
                paths.insert(path.to_owned(), (oid.to_owned(), ns));
            }
        }
        Self { paths }
    }

    /// The mtime to serve for `path` holding `oid`: last time's when the blob is the same, else
    /// `now_ns`. The book then holds exactly the paths asked for since [`Book::retain`].
    pub fn mtime(&mut self, path: &str, oid: &str, now_ns: i64) -> i64 {
        match self.paths.get(path) {
            Some((last, ns)) if last == oid => *ns,
            _ => {
                self.paths.insert(path.to_owned(), (oid.to_owned(), now_ns));
                now_ns
            }
        }
    }

    /// Forgets every path not in `keep`, so a path that comes back later counts as new content.
    pub fn retain(&mut self, keep: &BTreeSet<&str>) {
        self.paths.retain(|path, _| keep.contains(path.as_str()));
    }

    /// Writes the book to `file` (through a temporary file, so a crash leaves the old one).
    pub fn save(&self, file: &Path) -> anyhow::Result<()> {
        let mut text = String::new();
        for (path, (oid, ns)) in &self.paths {
            text.push_str(&format!("{oid} {ns} {path}\n"));
        }
        let temp = file.with_extension("tmp");
        std::fs::write(&temp, text)?;
        std::fs::rename(&temp, file)?;
        Ok(())
    }
}

/// One file of the commit as the index records it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct IndexEntry {
    pub path: String,
    pub mode: u32,
    pub oid: String,
    pub size: u64,
    pub mtime_ns: i64,
    /// The manifest entry, whose inode number the mount serves (entry + 1).
    pub entry: u32,
}

/// A commit ready to mount: its manifest, where each entry's bytes come from, and its index.
pub struct Projection {
    pub commit: String,
    pub manifest: Manifest,
    pub sources: Vec<Source>,
    pub index: Vec<IndexEntry>,
    /// Paths that are links to folders on the machine's disk (build output).
    pub real_dirs: Vec<String>,
}

/// What [`Projection::build`] needs besides the tree.
pub struct Layout<'a> {
    /// Committer time of the commit, nanoseconds: the folders' mtime.
    pub commit_ns: i64,
    /// "Now", nanoseconds: the mtime of content the book has not seen at its path.
    pub now_ns: i64,
    /// The `.git` file's text (`gitdir: ...`), or none.
    pub gitfile: Option<String>,
    /// The folder on the machine's disk that holds the build output folders, or none: no links
    /// to build output folders at all (a read-only lower that many checkouts share, where each
    /// checkout's own upper keeps its `target/`).
    pub real_root: Option<&'a Path>,
    /// Link texts of the commit's symlinks, by blob id.
    pub links: &'a HashMap<String, String>,
}

/// The build output folder each marker file asks for, beside it.
const REAL_DIRS: [(&str, &str); 3] =
    [("Cargo.lock", "target"), ("package.json", "node_modules"), ("Package.swift", ".build")];

impl Projection {
    /// The projection of `commit`'s `items`, with mtimes from `book` (updated to this commit).
    pub fn build(
        commit: &str,
        items: &[TreeItem],
        book: &mut Book,
        layout: &Layout<'_>,
    ) -> anyhow::Result<Self> {
        let paths: BTreeSet<&str> = items.iter().map(|item| item.path.as_str()).collect();
        let mut folders = BTreeSet::new();
        for path in &paths {
            let mut at = *path;
            while let Some((above, _)) = at.rsplit_once('/') {
                if !folders.insert(above) {
                    break;
                }
                at = above;
            }
        }
        let mut wanted = BTreeSet::new();
        for item in items {
            let (dir, name) = match item.path.rsplit_once('/') {
                Some((dir, name)) => (dir, name),
                None => ("", item.path.as_str()),
            };
            for (marker, output) in REAL_DIRS {
                if name != marker || layout.real_root.is_none() {
                    continue;
                }
                let real =
                    if dir.is_empty() { output.to_owned() } else { format!("{dir}/{output}") };
                if !paths.contains(real.as_str()) && !folders.contains(real.as_str()) {
                    wanted.insert(real);
                }
            }
        }
        let mut list = Vec::with_capacity(items.len() + wanted.len() + 1);
        let mut sources = HashMap::with_capacity(items.len() + 1);
        let mut mtimes = HashMap::with_capacity(items.len());
        for item in items {
            let mtime_ns = if item.mode == GITLINK {
                layout.commit_ns
            } else {
                book.mtime(&item.path, &item.oid, layout.now_ns)
            };
            mtimes.insert(item.path.as_str(), mtime_ns);
            let (kind, link, source) = match item.mode {
                GITLINK => (Kind::Dir, None, Source::None),
                LINK => {
                    let text = layout
                        .links
                        .get(&item.oid)
                        .ok_or_else(|| anyhow::anyhow!("no link text for {}", item.path))?;
                    (Kind::Link, Some(text.clone()), Source::None)
                }
                _ => (Kind::File, None, Source::Blob(item.oid.clone())),
            };
            let mode = match item.mode {
                GITLINK => 0o755,
                LINK => 0o777,
                mode if mode & 0o111 != 0 => 0o755,
                _ => 0o644,
            };
            sources.insert(item.path.clone(), source);
            list.push(Item {
                path: item.path.clone(),
                kind,
                mode,
                size: item.size,
                mtime_ns,
                link,
            });
        }
        book.retain(&paths);
        if let Some(text) = &layout.gitfile {
            anyhow::ensure!(!paths.contains(".git"), "the commit has a .git of its own");
            sources.insert(".git".to_owned(), Source::Bytes(text.clone().into_bytes()));
            list.push(Item {
                path: ".git".into(),
                kind: Kind::File,
                mode: 0o644,
                size: text.len() as u64,
                mtime_ns: layout.commit_ns,
                link: None,
            });
        }
        // `wanted` is empty without a `real_root`.
        for (real, root) in wanted.iter().filter_map(|real| Some((real, layout.real_root?))) {
            let target = root.join(real);
            list.push(Item {
                path: real.clone(),
                kind: Kind::Link,
                mode: 0o777,
                size: 0,
                mtime_ns: layout.commit_ns,
                link: Some(target.to_string_lossy().into_owned()),
            });
        }
        let manifest = Manifest::build_with(layout.commit_ns, list, Case::Sensitive)?;
        let mut by_entry = vec![Source::None; manifest.len()];
        let mut index = Vec::with_capacity(items.len());
        for item in items {
            let entry = manifest
                .resolve(&item.path)
                .ok_or_else(|| anyhow::anyhow!("{} is not in the manifest", item.path))?;
            if let Some(source) = sources.remove(&item.path) {
                *by_entry
                    .get_mut(entry as usize)
                    .ok_or_else(|| anyhow::anyhow!("manifest entry {entry} is out of range"))? =
                    source;
            }
            index.push(IndexEntry {
                path: item.path.clone(),
                mode: item.mode,
                oid: item.oid.clone(),
                size: item.size,
                mtime_ns: mtimes.get(item.path.as_str()).copied().unwrap_or(layout.commit_ns),
                entry,
            });
        }
        if let (Some(source), Some(entry)) = (sources.remove(".git"), manifest.resolve(".git")) {
            *by_entry
                .get_mut(entry as usize)
                .ok_or_else(|| anyhow::anyhow!("manifest entry {entry} is out of range"))? = source;
        }
        index.sort_by(|a, b| a.path.as_bytes().cmp(b.path.as_bytes()));
        Ok(Self {
            commit: commit.to_owned(),
            manifest,
            sources: by_entry,
            index,
            real_dirs: wanted.into_iter().collect(),
        })
    }
}

/// The index (version 2) of `entries`, with the stat data the mount serves for each: mtime and
/// ctime from the manifest, inode number entry + 1, owner `uid`/`gid`. git then finds every file
/// unchanged by stat alone.
pub fn index_bytes(
    entries: &[IndexEntry],
    format: ObjectFormat,
    uid: u32,
    gid: u32,
) -> anyhow::Result<Vec<u8>> {
    index_bytes_sparse(entries, &[], format, uid, gid)
}

/// [`index_bytes`], plus `skipped`: the commit's paths a sparse checkout leaves out, as git
/// records them (skip-worktree, no stat), so the index still holds the whole commit and git sees
/// nothing deleted. Index version 3 when there are any (its extended flags carry the bit).
pub fn index_bytes_sparse(
    entries: &[IndexEntry],
    skipped: &[TreeItem],
    format: ObjectFormat,
    uid: u32,
    gid: u32,
) -> anyhow::Result<Vec<u8>> {
    let skip = skipped.iter().map(|item| IndexEntry {
        path: item.path.clone(),
        mode: item.mode,
        oid: item.oid.clone(),
        size: 0,
        mtime_ns: 0,
        entry: u32::MAX,
    });
    let mut all: Vec<(IndexEntry, bool)> = entries
        .iter()
        .cloned()
        .map(|entry| (entry, false))
        .chain(skip.map(|e| (e, true)))
        .collect();
    if !skipped.is_empty() {
        all.sort_by(|a, b| a.0.path.as_bytes().cmp(b.0.path.as_bytes()));
    }
    let version: u32 = if skipped.is_empty() { 2 } else { 3 };
    let mut out = Vec::with_capacity(all.len() * 100 + 32);
    out.extend_from_slice(b"DIRC");
    out.extend_from_slice(&version.to_be_bytes());
    out.extend_from_slice(&u32::try_from(all.len())?.to_be_bytes());
    for (entry, skip_worktree) in &all {
        let (seconds, nanos) = if entry.mode == GITLINK || *skip_worktree {
            (0, 0)
        } else {
            (entry.mtime_ns.div_euclid(1_000_000_000), entry.mtime_ns.rem_euclid(1_000_000_000))
        };
        let (ino, uid, gid, size) = if entry.mode == GITLINK || *skip_worktree {
            (0, 0, 0, 0)
        } else {
            (u64::from(entry.entry) + 1, uid, gid, entry.size)
        };
        let start = out.len();
        // ctime, mtime (seconds, nanoseconds), dev, ino, mode, uid, gid, size: 32 bits each, the
        // low bits of a wider number, as git stores them.
        let fields = [
            seconds as u32,
            nanos as u32,
            seconds as u32,
            nanos as u32,
            0,
            ino as u32,
            entry.mode,
            uid,
            gid,
            size as u32,
        ];
        for field in fields {
            out.extend_from_slice(&field.to_be_bytes());
        }
        out.extend_from_slice(&hex(&entry.oid, format)?);
        let name = entry.path.as_bytes();
        let flags = u16::try_from(name.len().min(0xfff))?;
        if *skip_worktree {
            // The extended bit, then the extended flags with skip-worktree.
            out.extend_from_slice(&(flags | 0x4000).to_be_bytes());
            out.extend_from_slice(&0x4000u16.to_be_bytes());
        } else {
            out.extend_from_slice(&flags.to_be_bytes());
        }
        out.extend_from_slice(name);
        let len = out.len() - start;
        let padded = (len + 8) & !7;
        out.resize(start + padded, 0);
    }
    let digest = format.digest(&out);
    out.extend_from_slice(&digest);
    Ok(out)
}

fn hex(oid: &str, format: ObjectFormat) -> anyhow::Result<Vec<u8>> {
    let len = format.id_bytes();
    anyhow::ensure!(oid.len() == len * 2, "not a {format:?} object id: {oid}");
    let mut bytes = vec![0u8; len];
    for (byte, pair) in bytes.iter_mut().zip(oid.as_bytes().chunks_exact(2)) {
        let pair = std::str::from_utf8(pair)?;
        *byte = u8::from_str_radix(pair, 16)?;
    }
    Ok(bytes)
}

/// A worktree of the host's mirror whose files are the mount: its state folder lives in the
/// mirror (`worktrees/NAME`), on the real disk, as `git worktree add` would make it.
pub struct Worktree {
    pub admin: PathBuf,
}

impl Worktree {
    /// Validates a name and refuses to take over an ordinary or differently mounted worktree.
    pub fn validate(git_dir: &Path, name: &str, at: &Path) -> anyhow::Result<Self> {
        let path = Path::new(name);
        anyhow::ensure!(
            path.components().count() == 1
                && matches!(path.components().next(), Some(std::path::Component::Normal(_))),
            "invalid worktree name {name:?}"
        );
        let admin = git_dir.join("worktrees").join(path);
        if admin.exists() {
            let expected = format!("{}\n", at.join(".git").display());
            let held = std::fs::read_to_string(admin.join("gitdir"))
                .map_err(|error| anyhow::anyhow!("cannot inspect worktree {name:?}: {error}"))?;
            anyhow::ensure!(held == expected, "worktree {name:?} is not owned by this projection");
        }
        Ok(Self { admin })
    }

    /// Registers worktree `name` of `git_dir` at `at` on `commit` (detached), with `index`, and a
    /// `locked` note so `git worktree prune` keeps it while the mount is down. `excludes` are
    /// paths git should not list as untracked (the build output links), kept in this worktree's
    /// own config.
    pub fn write(
        git_dir: &Path,
        name: &str,
        at: &Path,
        commit: &str,
        index: &[u8],
        excludes: &[String],
    ) -> anyhow::Result<Self> {
        let worktree = Self::validate(git_dir, name, at)?;
        let admin = worktree.admin.clone();
        std::fs::create_dir_all(&admin)?;
        // Each file is written only when its bytes change: build scripts watch `HEAD` (cmux's
        // build identity does), and a rewrite with the same commit would rerun them.
        write_if_changed(&admin.join("commondir"), b"../..\n")?;
        let gitdir = format!("{}\n", at.join(".git").display());
        write_if_changed(&admin.join("gitdir"), gitdir.as_bytes())?;
        write_if_changed(&admin.join("HEAD"), format!("{commit}\n").as_bytes())?;
        write_if_changed(&admin.join("locked"), b"a cmux-projection mount\n")?;
        let exclude = admin.join("projection-exclude");
        let mut text = String::new();
        for path in excludes {
            text.push_str(&format!("/{path}\n"));
        }
        write_if_changed(&exclude, text.as_bytes())?;
        write_if_changed(&admin.join("index"), index)?;
        // git reads a worktree's own config only with extensions.worktreeConfig (the lane mirrors
        // have it); without it the build output links show as untracked, and nothing else differs.
        let mut command = git(git_dir);
        command.args(["config", "--bool", "extensions.worktreeConfig"]);
        if output(command).is_ok_and(|out| out.starts_with(b"true")) {
            let config = admin.join("config.worktree");
            let mut read = Command::new("git");
            read.arg("config").arg("--file").arg(&config).args(["--get", "core.excludesFile"]);
            let set = output(read).unwrap_or_default();
            if set.strip_suffix(b"\n") != Some(exclude.as_os_str().as_encoded_bytes()) {
                let mut command = Command::new("git");
                command.arg("config").arg("--file").arg(&config);
                command.arg("core.excludesFile").arg(&exclude);
                output(command)?;
            }
        }
        Ok(worktree)
    }

    /// Whether the worktree at `admin` already has `sparse` as its patterns (no `--sparse` and no
    /// `info/sparse-checkout` count as the same), so an index written for other patterns is
    /// written again.
    #[must_use]
    #[cfg(any(target_os = "linux", test))]
    pub fn sparse_matches(admin: &Path, sparse: Option<&Sparse>) -> bool {
        let held = std::fs::read_to_string(admin.join("info").join("sparse-checkout")).ok();
        held.as_deref() == sparse.map(Sparse::text)
    }

    /// Records `sparse` as this worktree's sparse patterns the way `git sparse-checkout set
    /// --no-cone` does: the patterns in `info/sparse-checkout`, `core.sparseCheckout=true` and
    /// `core.sparseCheckoutCone=false` in the worktree's own config. None turns sparse off again.
    #[cfg(any(target_os = "linux", test))]
    pub fn set_sparse(&self, git_dir: &Path, sparse: Option<&Sparse>) -> anyhow::Result<()> {
        let file = self.admin.join("info").join("sparse-checkout");
        let config = self.admin.join("config.worktree");
        let Some(sparse) = sparse else {
            if file.exists() {
                std::fs::remove_file(&file)?;
            }
            for key in ["core.sparseCheckout", "core.sparseCheckoutCone"] {
                let mut unset = Command::new("git");
                unset.arg("config").arg("--file").arg(&config).args(["--unset", key]);
                // Exit 5 (no such key) is the state wanted.
                let _ = output(unset);
            }
            return Ok(());
        };
        let mut command = git(git_dir);
        command.args(["config", "--bool", "extensions.worktreeConfig"]);
        anyhow::ensure!(
            output(command).is_ok_and(|out| out.starts_with(b"true")),
            "--sparse needs the worktree's own config: run `git --git-dir {} config \
             extensions.worktreeConfig true` first",
            git_dir.display()
        );
        std::fs::create_dir_all(self.admin.join("info"))?;
        write_if_changed(&file, sparse.text().as_bytes())?;
        for (key, value) in [("core.sparseCheckout", "true"), ("core.sparseCheckoutCone", "false")]
        {
            let mut read = Command::new("git");
            read.arg("config").arg("--file").arg(&config).args(["--get", key]);
            if output(read).is_ok_and(|out| out.strip_suffix(b"\n") == Some(value.as_bytes())) {
                continue;
            }
            let mut set = Command::new("git");
            set.arg("config").arg("--file").arg(&config).args([key, value]);
            output(set)?;
        }
        Ok(())
    }

    /// The `.git` file's text for this worktree.
    #[must_use]
    pub fn gitfile(admin: &Path) -> String {
        format!("gitdir: {}\n", admin.display())
    }
}

/// Writes `bytes` to `file` (through a temporary file) unless it already holds them, so its mtime
/// moves only when its content does.
fn write_if_changed(file: &Path, bytes: &[u8]) -> anyhow::Result<()> {
    if std::fs::read(file).is_ok_and(|held| held == bytes) {
        return Ok(());
    }
    let temp = file.with_extension("projection.tmp");
    std::fs::write(&temp, bytes)?;
    std::fs::rename(&temp, file)?;
    Ok(())
}

/// Link texts of every symlink in `items`, by blob id, read in one `git cat-file --batch`.
pub fn link_texts(git_dir: &Path, items: &[TreeItem]) -> anyhow::Result<HashMap<String, String>> {
    let oids: BTreeSet<&str> =
        items.iter().filter(|item| item.mode == LINK).map(|item| item.oid.as_str()).collect();
    let mut texts = HashMap::new();
    if oids.is_empty() {
        return Ok(texts);
    }
    let mut cat = CatFile::spawn(git_dir)?;
    for oid in oids {
        let bytes = cat.blob_limited(oid, 4095).map_err(|_| {
            Unsupported(format!("link blob {oid} is missing or exceeds the 4095-byte target limit"))
        })?;
        let text = String::from_utf8(bytes)
            .map_err(|_| Unsupported(format!("link blob {oid} is not UTF-8")))?;
        texts.insert(oid.to_owned(), text);
    }
    Ok(texts)
}

/// One long-lived `git cat-file --batch`.
struct CatFile {
    stdin: ChildStdin,
    stdout: BufReader<ChildStdout>,
    /// Held so the process ends with this handle, after its stdin (above) closes.
    _child: Child,
}

impl CatFile {
    fn spawn(git_dir: &Path) -> anyhow::Result<Self> {
        Self::spawn_from(git(git_dir))
    }

    /// A reader that answers only from the objects `git_dir` holds: a blob it lacks is never
    /// fetched from its promisor remote. `GIT_NO_LAZY_FETCH` turns lazy fetches off (git 2.44 and
    /// later); `GIT_ALLOW_PROTOCOL=none` makes one fail at once without the network on an older
    /// git. Either way git ends the process on the first blob it lacks, so the caller spawns a
    /// fresh one ([`ObjectReader`]).
    fn spawn_local(git_dir: &Path) -> anyhow::Result<Self> {
        let mut command = git(git_dir);
        command.env("GIT_NO_LAZY_FETCH", "1").env("GIT_ALLOW_PROTOCOL", "none");
        Self::spawn_from(command)
    }

    fn spawn_from(mut command: Command) -> anyhow::Result<Self> {
        let mut child = command
            .args(["cat-file", "--batch"])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()?;
        let stdin = child.stdin.take().ok_or_else(|| anyhow::anyhow!("no stdin"))?;
        let stdout =
            BufReader::new(child.stdout.take().ok_or_else(|| anyhow::anyhow!("no stdout"))?);
        Ok(Self { _child: child, stdin, stdout })
    }

    fn record(&mut self, oid: &str) -> Result<(String, u64), FetchError> {
        writeln!(self.stdin, "{oid}").map_err(|_| FetchError::Failed)?;
        self.stdin.flush().map_err(|_| FetchError::Failed)?;
        let mut header = String::new();
        self.stdout.read_line(&mut header).map_err(|_| FetchError::Failed)?;
        let mut fields = header.split_whitespace();
        let (Some(_), Some(kind), Some(size), None) =
            (fields.next(), fields.next(), fields.next(), fields.next())
        else {
            return Err(FetchError::Failed);
        };
        Ok((kind.to_owned(), size.parse().map_err(|_| FetchError::Failed)?))
    }

    fn drain(&mut self, size: u64) -> Result<(), FetchError> {
        let mut limited = self.stdout.by_ref().take(size);
        std::io::copy(&mut limited, &mut std::io::sink()).map_err(|_| FetchError::Failed)?;
        if limited.limit() != 0 {
            return Err(FetchError::Failed);
        }
        let mut newline = [0_u8; 1];
        self.stdout.read_exact(&mut newline).map_err(|_| FetchError::Failed)?;
        if newline != *b"\n" {
            return Err(FetchError::Failed);
        }
        Ok(())
    }

    fn blob(&mut self, oid: &str) -> Result<Vec<u8>, FetchError> {
        let (kind, size) = self.record(oid)?;
        if kind != "blob" {
            self.drain(size)?;
            return Err(FetchError::Failed);
        }
        let mut bytes = Vec::with_capacity(usize::try_from(size).map_err(|_| FetchError::Failed)?);
        self.stdout.by_ref().take(size).read_to_end(&mut bytes).map_err(|_| FetchError::Failed)?;
        if bytes.len() as u64 != size {
            return Err(FetchError::Failed);
        }
        let mut newline = [0_u8; 1];
        self.stdout.read_exact(&mut newline).map_err(|_| FetchError::Failed)?;
        if newline != *b"\n" {
            return Err(FetchError::Failed);
        }
        Ok(bytes)
    }

    fn blob_limited(&mut self, oid: &str, max: u64) -> Result<Vec<u8>, FetchError> {
        let (kind, size) = self.record(oid)?;
        if kind != "blob" || size > max {
            self.drain(size)?;
            return Err(FetchError::Failed);
        }
        let mut bytes = Vec::with_capacity(usize::try_from(size).map_err(|_| FetchError::Failed)?);
        self.stdout.by_ref().take(size).read_to_end(&mut bytes).map_err(|_| FetchError::Failed)?;
        if bytes.len() as u64 != size {
            return Err(FetchError::Failed);
        }
        let mut newline = [0_u8; 1];
        self.stdout.read_exact(&mut newline).map_err(|_| FetchError::Failed)?;
        if newline != *b"\n" {
            return Err(FetchError::Failed);
        }
        Ok(bytes)
    }
}

/// Reads blobs of a git object store by id, for a seed ([`crate::peers::serve`]), from what the
/// store holds and nothing else. A seed's mirror is a partial clone, so a plain `cat-file` fetched
/// every blob it lacked from GitHub, one round trip per blob, inside the batch stream: a checkout
/// that asked the seed for 54 blobs it lacked waited about 560 ms each (30 s), when the next
/// source could have answered them in one request.
pub struct ObjectReader {
    git_dir: PathBuf,
    cat: Option<CatFile>,
}

impl ObjectReader {
    pub fn spawn(git_dir: &Path) -> anyhow::Result<Self> {
        Ok(Self { git_dir: git_dir.to_owned(), cat: Some(CatFile::spawn_local(git_dir)?) })
    }

    /// A reader that refuses promisor fetches, for a seed serving only local objects.
    pub fn spawn_local(git_dir: &Path) -> anyhow::Result<Self> {
        Self::spawn(git_dir)
    }

    /// The blob's bytes, or `None` when the store has no blob by that id. A miss may have ended
    /// the `cat-file` (see [`CatFile::spawn_local`]), so the next read starts a fresh one.
    pub fn blob(&mut self, oid: &str) -> Option<Vec<u8>> {
        let cat = match &mut self.cat {
            Some(cat) => cat,
            None => self.cat.insert(CatFile::spawn_local(&self.git_dir).ok()?),
        };
        // Local object readers serve S3 uploads and seed responses. Keep the local path
        // unbounded; the peer receive path applies MAX_HTTP_BODY_BYTES independently.
        let bytes = cat.blob(oid).ok();
        if bytes.is_none() {
            self.cat = None;
        }
        bytes
    }
}

/// The most blobs kept in memory, and their bytes, so a file read in many pieces costs one
/// object read.
const RECENT_FILES: usize = 64;
const RECENT_BYTES: usize = 64 * 1024 * 1024;

/// How long a pooled `git cat-file --batch` may sit unused, and the recent blobs stay held, before
/// the mount gives that memory back. Each process keeps its own delta-base cache and heap (tens of
/// MB, some past 150 MB). An agent's checkout sits idle most of its life: that memory is what packs
/// more agents on a host.
const IDLE: Duration = Duration::from_secs(30);
/// How often the reaper looks.
const SWEEP: Duration = Duration::from_secs(10);
/// The most `git cat-file --batch` processes one mount runs at once. The pool starts empty, the
/// first read starts one, and a second (up to this cap) starts only while every live one is busy;
/// past the cap a read waits for the next free one (a blob read takes about a millisecond). The
/// mount runs 16 FUSE workers, and the pool used to grow to all 16: on one lane VM 128 checkouts
/// held 1,459 git processes and 73 GB, and the host thrashed. 4 keeps a parallel build's reads
/// moving (the kernel's page cache and the recent blobs below answer most repeats) at a quarter of
/// the worst case.
const MAX_CATS: usize = 4;

struct Pooled {
    cat: CatFile,
    used: Instant,
}

/// The pool's processes: the free ones, and how many are alive (free and in use).
#[derive(Default)]
struct Pool {
    /// Most recently used last: a read takes from the end, so the oldest age out first.
    free: Vec<Pooled>,
    live: usize,
}

/// What [`GitBlobs`] holds between reads, shared with its reaper thread by a weak handle.
struct Held {
    pool: Mutex<Pool>,
    /// Signalled when a process goes back to the pool or ends, for a read waiting at the cap.
    freed: Condvar,
    /// The most processes alive at once (tests and the bench).
    peak: AtomicUsize,
    recent: Mutex<VecDeque<(u32, Arc<Vec<u8>>)>>,
    last_read: Mutex<Instant>,
}

impl Held {
    /// A free process, a new one while fewer than [`MAX_CATS`] live, or the next one freed.
    fn take(&self, git_dir: &Path) -> Result<CatFile, FetchError> {
        let mut pool = self.pool.lock().unwrap_or_else(PoisonError::into_inner);
        loop {
            if let Some(pooled) = pool.free.pop() {
                return Ok(pooled.cat);
            }
            if pool.live < MAX_CATS {
                pool.live += 1;
                self.peak.fetch_max(pool.live, Ordering::Relaxed);
                drop(pool);
                return CatFile::spawn(git_dir).map_err(|_| {
                    self.ended(1);
                    FetchError::Failed
                });
            }
            pool = self.freed.wait(pool).unwrap_or_else(PoisonError::into_inner);
        }
    }

    /// Puts a process that answered back in the pool.
    fn give(&self, cat: CatFile) {
        self.pool
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .free
            .push(Pooled { cat, used: Instant::now() });
        self.freed.notify_one();
    }

    /// Counts `n` processes gone (a failed read drops its process: its pipe state is unknown).
    fn ended(&self, n: usize) {
        let mut pool = self.pool.lock().unwrap_or_else(PoisonError::into_inner);
        pool.live = pool.live.saturating_sub(n);
        drop(pool);
        self.freed.notify_all();
    }

    /// Ends every pooled process unused for `idle` (dropping it closes its stdin, and git exits),
    /// and, when the mount was not read for `idle`, drops the recent blobs and gives the freed
    /// heap back to the system.
    fn sweep(&self, now: Instant, idle: Duration) {
        let ended: Vec<Pooled> = {
            let mut pool = self.pool.lock().unwrap_or_else(PoisonError::into_inner);
            let (old, fresh): (Vec<_>, Vec<_>) =
                pool.free.drain(..).partition(|p| now.saturating_duration_since(p.used) >= idle);
            pool.free = fresh;
            pool.live = pool.live.saturating_sub(old.len());
            old
        };
        let any_ended = !ended.is_empty();
        drop(ended);
        let quiet = now.saturating_duration_since(
            *self.last_read.lock().unwrap_or_else(PoisonError::into_inner),
        ) >= idle;
        if quiet {
            let gone =
                std::mem::take(&mut *self.recent.lock().unwrap_or_else(PoisonError::into_inner));
            let any_gone = !gone.is_empty();
            drop(gone);
            if any_ended || any_gone {
                trim_heap();
            }
        }
    }
}

/// Returns freed heap pages to the system. glibc keeps what a burst of reads freed (the recent
/// blobs, up to 64 MB, and the read buffers) mapped in the process until asked, so an idle mount
/// kept its busiest moment's RSS.
fn trim_heap() {
    #[cfg(all(target_os = "linux", target_env = "gnu"))]
    // SAFETY: malloc_trim only returns free heap pages to the system; it touches no live allocation.
    unsafe {
        libc::malloc_trim(0);
    }
}

/// A projection's bytes from the host's git object store: a pool of `git cat-file --batch`
/// processes and the last few blobs read. Nothing is copied to disk. Both are given back after
/// [`IDLE`] unused, by a thread that ends with the mount.
pub struct GitBlobs {
    git_dir: PathBuf,
    sources: Vec<Source>,
    held: Arc<Held>,
}

impl GitBlobs {
    #[must_use]
    pub fn new(git_dir: &Path, sources: Vec<Source>) -> Self {
        let held = Arc::new(Held {
            pool: Mutex::new(Pool::default()),
            freed: Condvar::new(),
            peak: AtomicUsize::new(0),
            recent: Mutex::new(VecDeque::new()),
            last_read: Mutex::new(Instant::now()),
        });
        let weak: Weak<Held> = Arc::downgrade(&held);
        // Without the thread (spawn refused) the mount still works; it only keeps its memory.
        let _ = std::thread::Builder::new().name("projection-reaper".into()).spawn(move || {
            loop {
                std::thread::sleep(SWEEP);
                let Some(held) = weak.upgrade() else { return };
                held.sweep(Instant::now(), IDLE);
            }
        });
        Self { git_dir: git_dir.to_owned(), sources, held }
    }

    /// How many `git cat-file` processes wait in the pool (tests).
    #[cfg(test)]
    fn pooled(&self) -> usize {
        self.held.pool.lock().unwrap_or_else(PoisonError::into_inner).free.len()
    }

    /// The most `git cat-file` processes alive at once (tests).
    #[cfg(test)]
    fn peak(&self) -> usize {
        self.held.peak.load(Ordering::Relaxed)
    }

    fn bytes(&self, entry: u32) -> Result<Arc<Vec<u8>>, FetchError> {
        *self.held.last_read.lock().unwrap_or_else(PoisonError::into_inner) = Instant::now();
        {
            let recent = self.held.recent.lock().unwrap_or_else(PoisonError::into_inner);
            if let Some((_, bytes)) = recent.iter().find(|(at, _)| *at == entry) {
                return Ok(bytes.clone());
            }
        }
        let bytes = match self.sources.get(entry as usize) {
            Some(Source::Blob(oid)) => {
                let mut cat = self.held.take(&self.git_dir)?;
                match cat.blob(oid) {
                    Ok(bytes) => {
                        self.held.give(cat);
                        bytes
                    }
                    Err(e) => {
                        drop(cat);
                        self.held.ended(1);
                        return Err(e);
                    }
                }
            }
            Some(Source::Bytes(bytes)) => bytes.clone(),
            _ => return Err(FetchError::Failed),
        };
        let bytes = Arc::new(bytes);
        let mut recent = self.held.recent.lock().unwrap_or_else(PoisonError::into_inner);
        recent.push_front((entry, bytes.clone()));
        let mut total = 0;
        let mut keep = 0;
        for (_, held) in recent.iter() {
            total += held.len();
            if keep >= RECENT_FILES || (keep > 0 && total > RECENT_BYTES) {
                break;
            }
            keep += 1;
        }
        recent.truncate(keep);
        Ok(bytes)
    }
}

impl Fetch for GitBlobs {
    fn read(&self, entry: u32, offset: u64, len: u32) -> Result<Vec<u8>, FetchError> {
        let bytes = self.bytes(entry)?;
        let start = usize::try_from(offset).unwrap_or(usize::MAX).min(bytes.len());
        let end = start.saturating_add(len as usize).min(bytes.len());
        Ok(bytes.iter().skip(start).take(end.saturating_sub(start)).copied().collect())
    }

    fn batch(&self, entries: &[u32]) -> Vec<Result<Vec<u8>, FetchError>> {
        entries.iter().map(|entry| self.bytes(*entry).map(|bytes| bytes.to_vec())).collect()
    }

    fn cache(&self) -> bool {
        false
    }
}

#[cfg(test)]
#[path = "git_tests.rs"]
mod tests;
