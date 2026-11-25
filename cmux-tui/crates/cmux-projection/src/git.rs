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
use std::sync::{Arc, Mutex, PoisonError, Weak};
use std::time::{Duration, Instant};

use sha1::{Digest as _, Sha1};

use crate::manifest::{Item, Kind, Manifest};
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
        let record = std::str::from_utf8(record)?;
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

/// Every path of `commit`'s tree with sizes 0, reading trees only. On a blobless mirror
/// (`--filter=blob:none`) `git ls-tree -l` fetches each blob it sizes, one request per blob,
/// which is the whole checkout's bytes; this reads none. [`fill_sizes`] then sets the sizes.
pub fn ls_tree_names(git_dir: &Path, commit: &str) -> anyhow::Result<Vec<TreeItem>> {
    let mut command = git(git_dir);
    command.args(["ls-tree", "-r", "-z", "--full-tree", commit]);
    parse_ls_tree(&output(command)?)
}

/// The sizes of the blobs in `oids` that the object store has, fetching none (`GIT_NO_LAZY_FETCH`).
pub fn local_sizes(git_dir: &Path, oids: &[&str]) -> anyhow::Result<HashMap<String, u64>> {
    let mut command = git(git_dir);
    command
        .env("GIT_NO_LAZY_FETCH", "1")
        .args(["cat-file", "--batch-check=%(objectname) %(objecttype) %(objectsize)"]);
    batch_sizes(command, oids.iter().map(|oid| (format!("{oid}\n"), 1)))
}

/// The sizes of those of `oids` the mirror's `origin` reports, with no blob fetched: protocol
/// v2's `object-info` (`git cat-file --batch-command`'s `remote-object-info`), which the serving
/// side answers when it sets `transfer.advertiseObjectInfo`. An origin that does not (GitHub's
/// does not) reports none, and the map is empty.
pub fn remote_sizes(git_dir: &Path, oids: &[&str]) -> anyhow::Result<HashMap<String, u64>> {
    let mut command = git(git_dir);
    command.args(["cat-file", "--batch-command=%(objectname) blob %(objectsize)"]);
    // One request per line; a line names many objects.
    let lines = oids
        .chunks(512)
        .map(|chunk| (format!("remote-object-info origin {}\n", chunk.join(" ")), chunk.len()));
    batch_sizes(command, lines)
}

/// Runs `command` (a `git cat-file` batch) on `lines`, each answered by its count of output
/// lines before the next is written (an unbuffered batch flushes each answer), so neither pipe
/// fills. A line git did not answer (it ended) stops the read.
fn batch_sizes(
    mut command: Command,
    lines: impl Iterator<Item = (String, usize)>,
) -> anyhow::Result<HashMap<String, u64>> {
    let mut sizes = HashMap::new();
    let mut lines = lines.peekable();
    if lines.peek().is_none() {
        return Ok(sizes);
    }
    let mut child =
        command.stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::null()).spawn()?;
    let mut stdin = child.stdin.take().ok_or_else(|| anyhow::anyhow!("no stdin"))?;
    let mut stdout =
        BufReader::new(child.stdout.take().ok_or_else(|| anyhow::anyhow!("no stdout"))?);
    'lines: for (line, answers) in lines {
        // git that ended (an origin with no object-info) closes its stdin: stop, as for no answer.
        if stdin.write_all(line.as_bytes()).and_then(|()| stdin.flush()).is_err() {
            break;
        }
        for _ in 0..answers {
            let mut answer = String::new();
            if stdout.read_line(&mut answer)? == 0 {
                break 'lines;
            }
            let mut fields = answer.split_whitespace();
            if let (Some(oid), Some("blob"), Some(size)) =
                (fields.next(), fields.next(), fields.next())
                && let Ok(size) = size.parse()
            {
                sizes.insert(oid.to_owned(), size);
            }
        }
    }
    drop(stdin);
    let _ = child.wait()?;
    Ok(sizes)
}

/// The blob sizes in a listing, by blob id. A listing is `git ls-tree -r -l -z` output (of any
/// commit) or lines of `OID SIZE` or `OID blob SIZE` (`git cat-file --batch-all-objects
/// --batch-check='%(objectname) %(objecttype) %(objectsize)'` of a store that has the blobs).
/// Only ids in `wanted` are kept, so a listing of a whole store costs no more memory than the
/// commit's missing blobs. Records of other kinds, or that do not parse, are skipped.
pub fn listing_sizes(listing: &[u8], wanted: &BTreeSet<&str>) -> HashMap<String, u64> {
    let mut sizes = HashMap::new();
    for record in listing.split(|byte| *byte == 0 || *byte == b'\n') {
        let Ok(record) = std::str::from_utf8(record) else { continue };
        // ls-tree: `MODE TYPE OID SIZE\tPATH`; the path may hold spaces.
        let head = record.split_once('\t').map_or(record, |(head, _)| head);
        let fields: Vec<&str> = head.split_whitespace().collect();
        let (oid, size) = match fields.as_slice() {
            [_, "blob", oid, size] | [oid, "blob", size] | [oid, size] => (*oid, *size),
            _ => continue,
        };
        if let (true, Ok(size)) = (wanted.contains(oid), size.parse()) {
            sizes.insert(oid.to_owned(), size);
        }
    }
    sizes
}

/// Where a lazy mount finds the sizes of the blobs its mirror lacks, tried in this order after
/// the mirror's own store, cheapest first. Each is keyed by blob id, not by commit: a listing or
/// store made at an older commit sizes every blob that commit shares with the one mounted, and
/// only the blobs added since are left for origin.
#[derive(Clone, Debug, Default)]
pub struct SizeSources {
    /// Listings ([`listing_sizes`]): one saved in a machine image, or served by a mirror host.
    pub listings: Vec<Vec<u8>>,
    /// Other object stores on this machine that hold blobs (an image's full clone), read with
    /// nothing fetched.
    pub stores: Vec<PathBuf>,
}

/// How many of a lazy tree's blobs each source sized. `fetched` blobs no source could size:
/// origin sent their bytes (one request), and they are local from then on.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct SizeCounts {
    pub local: usize,
    pub listed: usize,
    pub stores: usize,
    pub remote: usize,
    pub fetched: usize,
    pub fetched_bytes: u64,
}

/// A commit's tree, sized, on a mirror that may lack its blobs, and the blobs it still lacks.
pub struct LazyTree {
    pub items: Vec<TreeItem>,
    /// Blobs to fetch on first read ([`GitBlobs::lazy`]).
    pub missing: Vec<String>,
    /// Link blobs fetched now: a link's text is metadata.
    pub links_fetched: usize,
    pub sizes: SizeCounts,
}

/// The tree of `commit` for a lazy mount, fetching only its links' blobs and the blobs nothing
/// else can size. A missing blob's size comes from, in order: `sources`' listings, then its
/// stores, then the mirror's origin ([`remote_sizes`]); a blob none of them sizes is fetched
/// (with the rest of those, in one request) and sized locally. So a mount always works, and a
/// listing or store from an older commit leaves only the blobs added since to fetch.
pub fn lazy_tree(git_dir: &Path, commit: &str, sources: &SizeSources) -> anyhow::Result<LazyTree> {
    let mut items = ls_tree_names(git_dir, commit)?;
    let mut missing: BTreeSet<String> = missing(git_dir, commit)?.into_iter().collect();
    let links: Vec<String> = items
        .iter()
        .filter(|item| item.mode == LINK && missing.contains(&item.oid))
        .map(|item| item.oid.clone())
        .collect::<BTreeSet<_>>()
        .into_iter()
        .collect();
    fetch_missing(git_dir, &links)?;
    for link in &links {
        missing.remove(link);
    }
    let blobs: BTreeSet<&str> =
        items.iter().filter(|item| item.mode != GITLINK).map(|item| item.oid.as_str()).collect();
    let (absent, present): (Vec<&str>, Vec<&str>) =
        blobs.into_iter().partition(|oid| missing.contains(*oid));
    let mut counts = SizeCounts::default();
    let mut sizes = local_sizes(git_dir, &present)?;
    counts.local = sizes.len();
    let mut unknown: BTreeSet<&str> = absent.into_iter().collect();
    let mut take = |found: HashMap<String, u64>, unknown: &mut BTreeSet<&str>| {
        let mut taken = 0;
        for (oid, size) in found {
            if unknown.remove(oid.as_str()) {
                sizes.insert(oid, size);
                taken += 1;
            }
        }
        taken
    };
    for listing in &sources.listings {
        if unknown.is_empty() {
            break;
        }
        let found = listing_sizes(listing, &unknown);
        counts.listed += take(found, &mut unknown);
    }
    for store in &sources.stores {
        if unknown.is_empty() {
            break;
        }
        let wanted: Vec<&str> = unknown.iter().copied().collect();
        let found = local_sizes(store, &wanted)?;
        counts.stores += take(found, &mut unknown);
    }
    if !unknown.is_empty() {
        let wanted: Vec<&str> = unknown.iter().copied().collect();
        let found = remote_sizes(git_dir, &wanted)?;
        counts.remote += take(found, &mut unknown);
    }
    if !unknown.is_empty() {
        let wanted: Vec<String> = unknown.iter().map(|oid| (*oid).to_owned()).collect();
        fetch_missing(git_dir, &wanted)?;
        let refs: Vec<&str> = wanted.iter().map(String::as_str).collect();
        let found = local_sizes(git_dir, &refs)?;
        counts.fetched_bytes = found.values().sum();
        counts.fetched += take(found, &mut unknown);
        for oid in &wanted {
            missing.remove(oid);
        }
    }
    fill_sizes(&mut items, &sizes)?;
    Ok(LazyTree {
        items,
        missing: missing.into_iter().collect(),
        links_fetched: links.len(),
        sizes: counts,
    })
}

/// Sets each blob item's size from `sizes`; an item with none is an error naming its path.
pub fn fill_sizes(items: &mut [TreeItem], sizes: &HashMap<String, u64>) -> anyhow::Result<()> {
    for item in items.iter_mut().filter(|item| item.mode != GITLINK) {
        item.size = *sizes
            .get(&item.oid)
            .ok_or_else(|| anyhow::anyhow!("no size for {} ({})", item.path, item.oid))?;
    }
    Ok(())
}

/// `git ls-tree -r [-l] -z` output as items: `MODE TYPE OID [SIZE]\tPATH\0` (no size reads as 0).
pub fn parse_ls_tree(bytes: &[u8]) -> anyhow::Result<Vec<TreeItem>> {
    let mut items = Vec::new();
    for record in bytes.split(|byte| *byte == 0).filter(|record| !record.is_empty()) {
        let record = std::str::from_utf8(record)?;
        let (head, path) =
            record.split_once('\t').ok_or_else(|| anyhow::anyhow!("bad ls-tree line"))?;
        let mut fields = head.split_whitespace();
        // Without `-l` there is no size field: [`ls_tree_names`] reads no object.
        let (Some(mode), Some(_kind), Some(oid)) = (fields.next(), fields.next(), fields.next())
        else {
            anyhow::bail!("bad ls-tree line {record:?}");
        };
        let size = fields.next().unwrap_or("-");
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
        let manifest = Manifest::build(layout.commit_ns, list)?;
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
pub fn index_bytes(entries: &[IndexEntry], uid: u32, gid: u32) -> anyhow::Result<Vec<u8>> {
    index_bytes_sparse(entries, &[], uid, gid)
}

/// [`index_bytes`], plus `skipped`: the commit's paths a sparse checkout leaves out, as git
/// records them (skip-worktree, no stat), so the index still holds the whole commit and git sees
/// nothing deleted. Index version 3 when there are any (its extended flags carry the bit).
pub fn index_bytes_sparse(
    entries: &[IndexEntry],
    skipped: &[TreeItem],
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
        out.extend_from_slice(&hex(&entry.oid)?);
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
    let digest = Sha1::digest(&out);
    out.extend_from_slice(&digest);
    Ok(out)
}

fn hex(oid: &str) -> anyhow::Result<[u8; 20]> {
    anyhow::ensure!(oid.len() == 40, "not a sha-1 object id: {oid}");
    let mut bytes = [0u8; 20];
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
        let admin = git_dir.join("worktrees").join(name);
        std::fs::create_dir_all(&admin)?;
        // Each file is written only when its bytes change: build scripts watch `HEAD` (cmux's
        // build identity does), and a rewrite with the same commit would rerun them.
        write_if_changed(&admin.join("commondir"), b"../..\n")?;
        let gitdir = format!("{}\n", at.join(".git").display());
        write_if_changed(&admin.join("gitdir"), gitdir.as_bytes())?;
        // A worktree registered on a branch at `commit` (`git worktree add -b`, as `wt new` does)
        // keeps its branch; any other HEAD becomes `commit`, detached.
        if !branch_at(git_dir, &admin.join("HEAD"), commit) {
            write_if_changed(&admin.join("HEAD"), format!("{commit}\n").as_bytes())?;
        }
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
            // With per-worktree config on, a bare mirror's `core.bare = true` reaches its
            // worktrees too, and git refuses `status` in one ("must be run in a work tree").
            let mut read = Command::new("git");
            read.arg("config").arg("--file").arg(&config).args(["--get", "core.bare"]);
            if output(read).unwrap_or_default() != b"false\n" {
                let mut command = Command::new("git");
                command.arg("config").arg("--file").arg(&config).args(["core.bare", "false"]);
                output(command)?;
            }
        }
        Ok(Self { admin })
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

/// Whether the `HEAD` file `head` names a branch whose tip is `commit`.
fn branch_at(git_dir: &Path, head: &Path, commit: &str) -> bool {
    let Ok(text) = std::fs::read_to_string(head) else { return false };
    let Some(branch) = text.trim().strip_prefix("ref: ") else { return false };
    let mut command = git(git_dir);
    command.args(["rev-parse", "--verify", "--quiet"]).arg(format!("{branch}^{{commit}}"));
    output(command).is_ok_and(|out| out.trim_ascii() == commit.as_bytes())
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
        let bytes = cat.blob(oid).map_err(|_| anyhow::anyhow!("no link blob {oid}"))?;
        texts.insert(oid.to_owned(), String::from_utf8(bytes)?);
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
        let mut child = git(git_dir)
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

    fn blob(&mut self, oid: &str) -> Result<Vec<u8>, FetchError> {
        writeln!(self.stdin, "{oid}").map_err(|_| FetchError::Failed)?;
        self.stdin.flush().map_err(|_| FetchError::Failed)?;
        let mut header = String::new();
        self.stdout.read_line(&mut header).map_err(|_| FetchError::Failed)?;
        let mut fields = header.split_whitespace();
        let (Some(_), Some("blob"), Some(size)) = (fields.next(), fields.next(), fields.next())
        else {
            return Err(FetchError::Failed);
        };
        let size: usize = size.parse().map_err(|_| FetchError::Failed)?;
        let mut bytes = vec![0u8; size + 1];
        self.stdout.read_exact(&mut bytes).map_err(|_| FetchError::Failed)?;
        bytes.pop();
        Ok(bytes)
    }
}

/// Reads blobs of a git object store by id, for a seed ([`crate::peers::serve`]).
pub struct ObjectReader(CatFile);

impl ObjectReader {
    pub fn spawn(git_dir: &Path) -> anyhow::Result<Self> {
        Ok(Self(CatFile::spawn(git_dir)?))
    }

    /// The blob's bytes, or `None` when the store has no blob by that id.
    pub fn blob(&mut self, oid: &str) -> Option<Vec<u8>> {
        self.0.blob(oid).ok()
    }
}

/// The most blobs kept in memory, and their bytes, so a file read in many pieces costs one
/// object read.
const RECENT_FILES: usize = 64;
const RECENT_BYTES: usize = 64 * 1024 * 1024;

/// How long a pooled `git cat-file --batch` may sit unused, and the recent blobs stay held, before
/// the mount gives that memory back. Each process keeps its own delta-base cache and heap (tens of
/// MB, some past 150 MB), and a pool grows to the busiest moment's concurrency (16 on a lane VM
/// after one build), so a mount nobody reads kept about 600 MB until it was unmounted. An agent's
/// checkout sits idle most of its life: that memory is what packs more agents on a host.
const IDLE: Duration = Duration::from_secs(30);
/// How often the reaper looks.
const SWEEP: Duration = Duration::from_secs(10);

struct Pooled {
    cat: CatFile,
    used: Instant,
}

/// What [`GitBlobs`] holds between reads, shared with its reaper thread by a weak handle.
struct Held {
    /// Most recently used last: a read takes from the end, so the oldest age out first.
    pool: Mutex<Vec<Pooled>>,
    recent: Mutex<VecDeque<(u32, Arc<Vec<u8>>)>>,
    last_read: Mutex<Instant>,
}

impl Held {
    /// Ends every pooled process unused for `idle` (dropping it closes its stdin, and git exits),
    /// and drops the recent blobs when the mount was not read for `idle`.
    fn sweep(&self, now: Instant, idle: Duration) {
        let ended: Vec<Pooled> = {
            let mut pool = self.pool.lock().unwrap_or_else(PoisonError::into_inner);
            let (old, fresh): (Vec<_>, Vec<_>) =
                pool.drain(..).partition(|p| now.saturating_duration_since(p.used) >= idle);
            *pool = fresh;
            old
        };
        drop(ended);
        let quiet = now.saturating_duration_since(
            *self.last_read.lock().unwrap_or_else(PoisonError::into_inner),
        ) >= idle;
        if quiet {
            let gone =
                std::mem::take(&mut *self.recent.lock().unwrap_or_else(PoisonError::into_inner));
            drop(gone);
        }
    }
}

/// A projection's bytes from the host's git object store: a pool of `git cat-file --batch`
/// processes and the last few blobs read. Nothing is copied to disk. Both are given back after
/// [`IDLE`] unused, by a thread that ends with the mount.
pub struct GitBlobs {
    git_dir: PathBuf,
    sources: Vec<Source>,
    held: Arc<Held>,
    lazy: Option<Lazy>,
}

/// The most blobs, and their bytes, one lazy fetch asks for.
const FETCH_FILES: usize = 256;
const FETCH_BYTES: u64 = 16 * 1024 * 1024;

/// A blobless mirror's missing blobs, fetched from its promisor remote on first read, a folder's
/// small missing files in the same request (the folder read ahead the overlay does for a source it
/// caches; here the object store is the cache).
struct Lazy {
    missing: Mutex<std::collections::HashSet<String>>,
    /// Each entry's folder, and each folder's file entries.
    parents: Vec<u32>,
    folders: HashMap<u32, Vec<u32>>,
    sizes: Vec<u64>,
    fetches: std::sync::atomic::AtomicU64,
}

impl GitBlobs {
    #[must_use]
    pub fn new(git_dir: &Path, sources: Vec<Source>) -> Self {
        let held = Arc::new(Held {
            pool: Mutex::new(Vec::new()),
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
        Self { git_dir: git_dir.to_owned(), sources, held, lazy: None }
    }

    /// How many `git cat-file` processes wait in the pool (tests).
    #[cfg(test)]
    fn pooled(&self) -> usize {
        self.held.pool.lock().unwrap_or_else(PoisonError::into_inner).len()
    }

    /// Fetches the blobs in `missing` on first read instead of before the mount. `manifest` is
    /// the projection's (its entries are `sources`' indexes).
    #[must_use]
    pub fn lazy(mut self, manifest: &Manifest, missing: Vec<String>) -> Self {
        let count = u32::try_from(manifest.len()).unwrap_or(u32::MAX);
        let mut parents = Vec::with_capacity(manifest.len());
        let mut sizes = Vec::with_capacity(manifest.len());
        let mut folders: HashMap<u32, Vec<u32>> = HashMap::new();
        for index in 0..count {
            let entry = manifest.entry(index);
            let parent = entry.map_or(u32::MAX, |entry| entry.parent);
            parents.push(parent);
            sizes.push(entry.map_or(0, |entry| entry.size));
            if entry.is_some_and(|entry| entry.kind == Kind::File) {
                folders.entry(parent).or_default().push(index);
            }
        }
        self.lazy = Some(Lazy {
            missing: Mutex::new(missing.into_iter().collect()),
            parents,
            folders,
            sizes,
            fetches: std::sync::atomic::AtomicU64::new(0),
        });
        self
    }

    /// How many fetches lazy reads have made.
    #[must_use]
    pub fn fetches(&self) -> u64 {
        self.lazy.as_ref().map_or(0, |lazy| lazy.fetches.load(std::sync::atomic::Ordering::Relaxed))
    }

    /// Makes `entry`'s blob local if the mirror lacks it, with its folder's other missing files.
    fn ensure(&self, entry: u32, oid: &str) -> Result<(), FetchError> {
        let Some(lazy) = &self.lazy else { return Ok(()) };
        // Held across the fetch, so two reads in one folder make one request.
        let mut missing = lazy.missing.lock().unwrap_or_else(PoisonError::into_inner);
        if !missing.contains(oid) {
            return Ok(());
        }
        let mut wanted = vec![oid.to_owned()];
        let mut bytes = lazy.sizes.get(entry as usize).copied().unwrap_or(0);
        let parent = lazy.parents.get(entry as usize).copied().unwrap_or(u32::MAX);
        for other in lazy.folders.get(&parent).into_iter().flatten() {
            if wanted.len() >= FETCH_FILES {
                break;
            }
            let size = lazy.sizes.get(*other as usize).copied().unwrap_or(0);
            if let Some(Source::Blob(id)) = self.sources.get(*other as usize)
                && id != oid
                && bytes + size <= FETCH_BYTES
                && missing.contains(id)
                && !wanted.contains(id)
            {
                wanted.push(id.clone());
                bytes += size;
            }
        }
        lazy.fetches.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        // The mirror's remote did not answer: the read fails as "Host is down", as a Mac away does.
        fetch_missing(&self.git_dir, &wanted).map_err(|_| FetchError::Away)?;
        for id in &wanted {
            missing.remove(id);
        }
        Ok(())
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
                self.ensure(entry, oid)?;
                let taken = self.held.pool.lock().unwrap_or_else(PoisonError::into_inner).pop();
                let mut cat = match taken {
                    Some(pooled) => pooled.cat,
                    None => CatFile::spawn(&self.git_dir).map_err(|_| FetchError::Failed)?,
                };
                let bytes = cat.blob(oid)?;
                self.held
                    .pool
                    .lock()
                    .unwrap_or_else(PoisonError::into_inner)
                    .push(Pooled { cat, used: Instant::now() });
                bytes
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
