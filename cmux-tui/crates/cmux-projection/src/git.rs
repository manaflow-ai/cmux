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
use std::sync::{Mutex, PoisonError};

use sha1::{Digest as _, Sha1};

use crate::manifest::{Item, Kind, Manifest};
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

/// `git ls-tree -r -l -z` output as items: `MODE TYPE OID SIZE\tPATH\0`.
pub fn parse_ls_tree(bytes: &[u8]) -> anyhow::Result<Vec<TreeItem>> {
    let mut items = Vec::new();
    for record in bytes.split(|byte| *byte == 0).filter(|record| !record.is_empty()) {
        let record = std::str::from_utf8(record)?;
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
    /// Left out by the sparse patterns: not projected, marked skip-worktree in the index.
    pub skip_worktree: bool,
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
    /// The folder on the machine's disk that holds the build output folders.
    pub real_root: &'a Path,
    /// Link texts of the commit's symlinks, by blob id.
    pub links: &'a HashMap<String, String>,
    /// The sparse patterns (`--sparse`): the paths they leave out are not projected and are
    /// skip-worktree in the index. None projects every path.
    pub sparse: Option<&'a Sparse>,
}

/// The build output folder each marker file asks for, beside it.
const REAL_DIRS: [(&str, &str); 3] =
    [("Cargo.lock", "target"), ("package.json", "node_modules"), ("Package.swift", ".build")];

impl Projection {
    /// The projection of `commit`'s `items`, with mtimes from `book` (updated to this commit).
    /// The paths [`Layout::sparse`] leaves out are in the index only, marked skip-worktree.
    pub fn build(
        commit: &str,
        all_items: &[TreeItem],
        book: &mut Book,
        layout: &Layout<'_>,
    ) -> anyhow::Result<Self> {
        let (items, left_out): (Vec<&TreeItem>, Vec<&TreeItem>) = match layout.sparse {
            Some(sparse) => all_items.iter().partition(|item| sparse.includes(&item.path)),
            None => (all_items.iter().collect(), Vec::new()),
        };
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
        for item in &items {
            let (dir, name) = match item.path.rsplit_once('/') {
                Some((dir, name)) => (dir, name),
                None => ("", item.path.as_str()),
            };
            for (marker, output) in REAL_DIRS {
                if name != marker {
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
        for item in &items {
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
        for real in &wanted {
            let target = layout.real_root.join(real);
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
        let mut index = Vec::with_capacity(all_items.len());
        for item in &items {
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
                skip_worktree: false,
            });
        }
        for item in left_out {
            index.push(IndexEntry {
                path: item.path.clone(),
                mode: item.mode,
                oid: item.oid.clone(),
                size: item.size,
                mtime_ns: 0,
                entry: 0,
                skip_worktree: true,
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

/// The index of `entries`, with the stat data the mount serves for each: mtime and ctime from the
/// manifest, inode number entry + 1, owner `uid`/`gid`. git then finds every file unchanged by
/// stat alone. A skip-worktree entry (left out by the sparse patterns) carries no stat data and
/// git's extended flag `CE_SKIP_WORKTREE`, which needs index version 3; with none it is version 2.
pub fn index_bytes(entries: &[IndexEntry], uid: u32, gid: u32) -> anyhow::Result<Vec<u8>> {
    let extended = entries.iter().any(|entry| entry.skip_worktree);
    let mut out = Vec::with_capacity(entries.len() * 100 + 32);
    out.extend_from_slice(b"DIRC");
    out.extend_from_slice(&(if extended { 3u32 } else { 2u32 }).to_be_bytes());
    out.extend_from_slice(&u32::try_from(entries.len())?.to_be_bytes());
    for entry in entries {
        let (seconds, nanos) = if entry.mode == GITLINK || entry.skip_worktree {
            (0, 0)
        } else {
            (entry.mtime_ns.div_euclid(1_000_000_000), entry.mtime_ns.rem_euclid(1_000_000_000))
        };
        let (ino, uid, gid, size) = if entry.mode == GITLINK || entry.skip_worktree {
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
        let mut flags = u16::try_from(name.len().min(0xfff))?;
        if entry.skip_worktree {
            flags |= CE_EXTENDED;
        }
        out.extend_from_slice(&flags.to_be_bytes());
        if entry.skip_worktree {
            out.extend_from_slice(&CE_SKIP_WORKTREE.to_be_bytes());
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

/// The entry flag saying a second, extended flags word follows (index version 3).
const CE_EXTENDED: u16 = 0x4000;
/// The extended flag of a path the sparse patterns leave out.
const CE_SKIP_WORKTREE: u16 = 0x4000;

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
        Ok(Self { admin })
    }

    /// Whether the worktree at `admin` already has `sparse` as its patterns (no `--sparse` and no
    /// `info/sparse-checkout` count as the same), so an index written for other patterns is
    /// written again.
    #[must_use]
    pub fn sparse_matches(admin: &Path, sparse: Option<&Sparse>) -> bool {
        let held = std::fs::read_to_string(admin.join("info").join("sparse-checkout")).ok();
        held.as_deref() == sparse.map(Sparse::text)
    }

    /// Records `sparse` as this worktree's sparse patterns the way `git sparse-checkout set
    /// --no-cone` does: the patterns in `info/sparse-checkout`, `core.sparseCheckout=true` and
    /// `core.sparseCheckoutCone=false` in the worktree's own config. None turns sparse off again.
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

/// A projection's bytes from the host's git object store: a pool of `git cat-file --batch`
/// processes and the last few blobs read. Nothing is copied to disk.
pub struct GitBlobs {
    git_dir: PathBuf,
    sources: Vec<Source>,
    pool: Mutex<Vec<CatFile>>,
    recent: Mutex<VecDeque<(u32, std::sync::Arc<Vec<u8>>)>>,
}

impl GitBlobs {
    #[must_use]
    pub fn new(git_dir: &Path, sources: Vec<Source>) -> Self {
        Self {
            git_dir: git_dir.to_owned(),
            sources,
            pool: Mutex::new(Vec::new()),
            recent: Mutex::new(VecDeque::new()),
        }
    }

    fn bytes(&self, entry: u32) -> Result<std::sync::Arc<Vec<u8>>, FetchError> {
        {
            let recent = self.recent.lock().unwrap_or_else(PoisonError::into_inner);
            if let Some((_, bytes)) = recent.iter().find(|(at, _)| *at == entry) {
                return Ok(bytes.clone());
            }
        }
        let bytes = match self.sources.get(entry as usize) {
            Some(Source::Blob(oid)) => {
                let taken = self.pool.lock().unwrap_or_else(PoisonError::into_inner).pop();
                let mut cat = match taken {
                    Some(cat) => cat,
                    None => CatFile::spawn(&self.git_dir).map_err(|_| FetchError::Failed)?,
                };
                let bytes = cat.blob(oid)?;
                self.pool.lock().unwrap_or_else(PoisonError::into_inner).push(cat);
                bytes
            }
            Some(Source::Bytes(bytes)) => bytes.clone(),
            _ => return Err(FetchError::Failed),
        };
        let bytes = std::sync::Arc::new(bytes);
        let mut recent = self.recent.lock().unwrap_or_else(PoisonError::into_inner);
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
