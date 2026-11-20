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
//!
//! Both object formats work (SHA-1 and SHA-256), names are case-sensitive as on any Linux
//! checkout, and a blob of any size is read a range at a time in bounded memory. A commit this
//! cannot show as `git checkout` would (a path or link text that is not UTF-8) is refused with
//! [`Unsupported`] before anything is written, so the caller makes an ordinary checkout instead.

use std::collections::{BTreeSet, HashMap, VecDeque};
use std::ffi::{OsStr, OsString};
use std::io::{BufRead as _, BufReader, Read as _, Write as _};
use std::path::{Path, PathBuf};
use std::process::{ChildStdin, ChildStdout};
use std::sync::Arc;

use cmux_process::{Child, Command, Stdio};
use std::sync::{Mutex, PoisonError};

use sha1::{Digest as _, Sha1};
use sha2::Sha256;

use crate::manifest::{Case, Item, Kind, Manifest};
use crate::{Fetch, FetchError};

/// A commit the projection cannot show as `git checkout` would. It is found before the mount
/// point, the keep folder or the mirror's worktree is touched, so the caller falls back to an
/// ordinary checkout with nothing to clean up.
#[derive(Debug)]
pub struct Unsupported(pub String);

impl std::fmt::Display for Unsupported {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}; make an ordinary checkout instead", self.0)
    }
}

impl std::error::Error for Unsupported {}

/// The object format of a repository: how long its ids are and which hash sums its index.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ObjectFormat {
    Sha1,
    Sha256,
}

impl ObjectFormat {
    /// Bytes of one object id.
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
            Self::Sha256 => Sha256::digest(bytes).to_vec(),
        }
    }
}

/// The object format of the repository at `git_dir` (`extensions.objectFormat`).
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

/// `git ls-tree -r -l -z` output as items: `MODE TYPE OID SIZE\tPATH\0`. A path that is not
/// UTF-8 is [`Unsupported`]: the manifest, the mount and the index all carry names as text.
pub fn parse_ls_tree(bytes: &[u8]) -> anyhow::Result<Vec<TreeItem>> {
    let mut items = Vec::new();
    for record in bytes.split(|byte| *byte == 0).filter(|record| !record.is_empty()) {
        let tab = record
            .iter()
            .position(|byte| *byte == b'\t')
            .ok_or_else(|| anyhow::anyhow!("bad ls-tree line"))?;
        let (head, path) = record.split_at(tab);
        let path = path.strip_prefix(b"\t").unwrap_or(path);
        let head = std::str::from_utf8(head)?;
        let path = std::str::from_utf8(path).map_err(|_| {
            Unsupported(format!(
                "the path {:?} is not UTF-8",
                String::from_utf8_lossy(path).into_owned()
            ))
        })?;
        let mut fields = head.split_whitespace();
        let (Some(mode), Some(_kind), Some(oid), Some(size)) =
            (fields.next(), fields.next(), fields.next(), fields.next())
        else {
            anyhow::bail!("bad ls-tree line {head:?}\t{path:?}");
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
    /// The folder on the machine's disk that holds the build output folders.
    pub real_root: &'a Path,
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
        // A commit's names are case-sensitive: `Foo` and `foo` are two files of a Linux checkout.
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
/// unchanged by stat alone. Ids and the closing checksum are `format`'s (SHA-1 or SHA-256), as
/// git writes them for that repository.
pub fn index_bytes(
    entries: &[IndexEntry],
    format: ObjectFormat,
    uid: u32,
    gid: u32,
) -> anyhow::Result<Vec<u8>> {
    let mut out = Vec::with_capacity(entries.len() * 100 + 32);
    out.extend_from_slice(b"DIRC");
    out.extend_from_slice(&2u32.to_be_bytes());
    out.extend_from_slice(&u32::try_from(entries.len())?.to_be_bytes());
    for entry in entries {
        let (seconds, nanos) = if entry.mode == GITLINK {
            (0, 0)
        } else {
            (entry.mtime_ns.div_euclid(1_000_000_000), entry.mtime_ns.rem_euclid(1_000_000_000))
        };
        let (ino, uid, gid, size) = if entry.mode == GITLINK {
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
        out.extend_from_slice(&flags.to_be_bytes());
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
    /// Checks that an existing admin directory belongs to this projection, without writing it.
    pub fn validate(git_dir: &Path, name: &str, at: &Path) -> anyhow::Result<Self> {
        let name_path = Path::new(name);
        anyhow::ensure!(
            name_path.components().count() == 1
                && matches!(name_path.components().next(), Some(std::path::Component::Normal(_))),
            "invalid worktree name {name:?}"
        );
        let admin = git_dir.join("worktrees").join(name_path);
        match std::fs::symlink_metadata(&admin) {
            Ok(metadata) => {
                anyhow::ensure!(
                    metadata.file_type().is_dir(),
                    "worktree admin {} is not a directory",
                    admin.display()
                );
                let expected_gitdir = format!("{}\n", at.join(".git").display());
                let checks = [
                    ("commondir", b"../..\n".as_slice()),
                    ("gitdir", expected_gitdir.as_bytes()),
                    ("locked", b"a cmux-projection mount\n".as_slice()),
                ];
                for (file, expected) in checks {
                    let held = std::fs::read(admin.join(file)).map_err(|error| {
                        anyhow::anyhow!(
                            "worktree admin {} is not owned by this projection: cannot read {file}: {error}",
                            admin.display()
                        )
                    })?;
                    anyhow::ensure!(
                        held == expected,
                        "worktree admin {} is not owned by this projection",
                        admin.display()
                    );
                }
            }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) => return Err(error.into()),
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
        let admin = &worktree.admin;

        let mut bare = git(git_dir);
        bare.args(["config", "--bool", "core.bare"]);
        let bare = output(bare).is_ok_and(|out| config_is_true(&out));
        let mut shared_bare = Command::new("git");
        shared_bare
            .arg("config")
            .arg("--file")
            .arg(git_dir.join("config"))
            .args(["--bool", "core.bare"]);
        let shared_bare = output(shared_bare).is_ok_and(|out| config_is_true(&out));
        let mut extension = git(git_dir);
        extension.args(["config", "--bool", "extensions.worktreeConfig"]);
        let extension_enabled = output(extension).is_ok_and(|out| config_is_true(&out));
        if shared_bare {
            // A bare mirror's `core.bare=true` used to live in the shared config.  Once
            // worktreeConfig is enabled that value is inherited by every ordinary worktree,
            // making `git status` there fail with "must be run in a work tree".  Move the
            // setting to the mirror's own worktree config before enabling the extension, then
            // remove it from the shared config so ordinary worktrees stay non-bare.
            let main_config = git_dir.join("config.worktree");
            let mut command = Command::new("git");
            command.arg("config").arg("--file").arg(&main_config);
            command.args(["core.bare", "true"]);
            output(command)?;
            if !extension_enabled {
                let mut command = git(git_dir);
                command.args(["config", "extensions.worktreeConfig", "true"]);
                output(command)?;
            }
            let mut command = git(git_dir);
            command.args(["config", "--unset", "core.bare"]);
            output(command)?;
        }

        std::fs::create_dir_all(git_dir.join("worktrees"))?;
        match std::fs::create_dir(admin) {
            Ok(()) => {}
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {
                // A concurrent claimant may have created this directory after the first
                // validation. Re-read all ownership markers before touching any file.
                Self::validate(git_dir, name, at)?;
            }
            Err(error) => return Err(error.into()),
        }
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
        // Git reads a worktree's own config only with extensions.worktreeConfig. Enable it for
        // bare mirrors too; without it the build output links show as untracked.
        if bare || extension_enabled {
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
            if bare {
                let mut command = Command::new("git");
                command.arg("config").arg("--file").arg(&config);
                command.args(["core.bare", "false"]);
                output(command)?;
            }
        }
        Ok(worktree)
    }

    /// The `.git` file's text for this worktree.
    #[must_use]
    pub fn gitfile(admin: &Path) -> String {
        format!("gitdir: {}\n", admin.display())
    }
}

/// Whether remounting may replace the worktree's HEAD and index.  A symbolic HEAD means that
/// somebody used ordinary Git in the mounted checkout (for example `git switch -c topic`), so a
/// non-fresh remount must refuse instead of silently discarding that branch and its staged state.
pub fn remount_needs_reset(admin: &Path, commit: &str, fresh: bool) -> anyhow::Result<bool> {
    let head = std::fs::read_to_string(admin.join("HEAD")).ok();
    if !fresh && head.as_deref().is_some_and(|head| head.trim_start().starts_with("ref:")) {
        anyhow::bail!(
            "existing projection worktree has a symbolic HEAD; refusing remount without --fresh"
        );
    }
    Ok(fresh || head.is_none_or(|head| head.trim() != commit) || !admin.join("index").exists())
}

fn config_is_true(value: &[u8]) -> bool {
    value.strip_suffix(b"\n").unwrap_or(value) == b"true"
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

/// The longest link text read: Linux's `PATH_MAX` less its NUL. `git checkout` cannot make a
/// longer link either.
const MAX_LINK_BYTES: u64 = 4095;

/// Link texts of every symlink in `items`, by blob id, read in one `git cat-file --batch`. A
/// link text that is not UTF-8, or longer than a link can be, is [`Unsupported`].
pub fn link_texts(git_dir: &Path, items: &[TreeItem]) -> anyhow::Result<HashMap<String, String>> {
    let mut paths: HashMap<&str, &str> = HashMap::new();
    for item in items.iter().filter(|item| item.mode == LINK) {
        paths.entry(item.oid.as_str()).or_insert(item.path.as_str());
    }
    let mut texts = HashMap::new();
    if paths.is_empty() {
        return Ok(texts);
    }
    let oids: BTreeSet<&str> = paths.keys().copied().collect();
    let mut cat = CatFile::spawn(git_dir)?;
    for oid in oids {
        let path = paths.get(oid).copied().unwrap_or_default();
        let size = cat.start(oid).map_err(|_| anyhow::anyhow!("no link blob {oid}"))?;
        if size > MAX_LINK_BYTES {
            return Err(Unsupported(format!(
                "the link {path:?} is {size} bytes, longer than a link can be"
            ))
            .into());
        }
        let bytes = cat.take(size).map_err(|_| anyhow::anyhow!("no link blob {oid}"))?;
        cat.end().map_err(|_| anyhow::anyhow!("no link blob {oid}"))?;
        let text = String::from_utf8(bytes)
            .map_err(|_| Unsupported(format!("the link {path:?} has a text that is not UTF-8")))?;
        texts.insert(oid.to_owned(), text);
    }
    Ok(texts)
}

/// The most payload bytes skipped to bring a `git cat-file --batch` back in step; past it the
/// process is ended instead (a new one starts in milliseconds, a multi-GiB drain takes seconds).
const DRAIN_BYTES: u64 = 1024 * 1024;

/// One long-lived `git cat-file --batch`.
///
/// A request is [`CatFile::start`], then the payload's bytes through [`CatFile::take`] and
/// [`CatFile::skip`] (never more than asked for in memory), then [`CatFile::end`]. Between a
/// start and its end the stream is mid-record ([`CatFile::in_step`] is false): such a process
/// is drained ([`CatFile::drain`]) or dropped, never asked for another object.
struct CatFile {
    stdin: ChildStdin,
    stdout: BufReader<ChildStdout>,
    /// Payload bytes of the current record still on the stream (its closing newline aside).
    left: u64,
    /// Whether the stream is at a header: false from a request until its record is read.
    in_step: bool,
    /// Held so the process ends with this handle, after its stdin (above) closes.
    _child: Child,
}

impl CatFile {
    fn spawn(git_dir: &Path) -> anyhow::Result<Self> {
        Self::spawn_with(OsStr::new("git"), git_dir, false)
    }

    fn spawn_local(git_dir: &Path) -> anyhow::Result<Self> {
        Self::spawn_with(OsStr::new("git"), git_dir, true)
    }

    fn spawn_with(program: &OsStr, git_dir: &Path, no_lazy_fetch: bool) -> anyhow::Result<Self> {
        let mut command = Command::new(program);
        command.arg("--git-dir").arg(git_dir);
        command.args(["cat-file", "--batch"]);
        if no_lazy_fetch {
            command.env("GIT_NO_LAZY_FETCH", "1");
        }
        let mut child =
            command.stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::null()).spawn()?;
        let stdin = child.stdin.take().ok_or_else(|| anyhow::anyhow!("no stdin"))?;
        let stdout =
            BufReader::new(child.stdout.take().ok_or_else(|| anyhow::anyhow!("no stdout"))?);
        Ok(Self { _child: child, stdin, stdout, left: 0, in_step: true })
    }

    /// Whether the stream is at a header, ready for the next request.
    fn in_step(&self) -> bool {
        self.in_step
    }

    /// Asks for blob `oid` and reads its header: the blob's size, with its payload next on the
    /// stream. A missing id or another kind of object is an error, the stream left at the next
    /// header when that costs at most [`DRAIN_BYTES`].
    fn start(&mut self, oid: &str) -> Result<u64, FetchError> {
        if !self.in_step || oid.contains(['\n', ' ']) {
            return Err(FetchError::Failed);
        }
        self.in_step = false;
        writeln!(self.stdin, "{oid}").map_err(|_| FetchError::Failed)?;
        self.stdin.flush().map_err(|_| FetchError::Failed)?;
        // A header is `OID TYPE SIZE`, or `OID missing`: far under this bound.
        let mut header = Vec::new();
        self.stdout
            .by_ref()
            .take(256)
            .read_until(b'\n', &mut header)
            .map_err(|_| FetchError::Failed)?;
        if header.pop() != Some(b'\n') {
            return Err(FetchError::Failed);
        }
        let header = std::str::from_utf8(&header).map_err(|_| FetchError::Failed)?;
        let mut fields = header.split(' ');
        let (Some(_), Some(kind), Some(size), None) =
            (fields.next(), fields.next(), fields.next(), fields.next())
        else {
            // `OID missing` (or `ambiguous`): no payload follows.
            self.in_step = header.ends_with(" missing") || header.ends_with(" ambiguous");
            return Err(FetchError::Failed);
        };
        let size: u64 = size.parse().map_err(|_| FetchError::Failed)?;
        self.left = size;
        if kind != "blob" {
            self.drain()?;
            return Err(FetchError::Failed);
        }
        Ok(size)
    }

    /// The next `len` bytes of the payload.
    fn take(&mut self, len: u64) -> Result<Vec<u8>, FetchError> {
        if len > self.left {
            return Err(FetchError::Failed);
        }
        let mut bytes = Vec::with_capacity(usize::try_from(len).map_err(|_| FetchError::Failed)?);
        let read = self
            .stdout
            .by_ref()
            .take(len)
            .read_to_end(&mut bytes)
            .map_err(|_| FetchError::Failed)?;
        if read as u64 != len {
            return Err(FetchError::Failed);
        }
        self.left -= len;
        Ok(bytes)
    }

    /// Skips the next `len` bytes of the payload, holding none of them.
    fn skip(&mut self, len: u64) -> Result<(), FetchError> {
        if len > self.left {
            return Err(FetchError::Failed);
        }
        let mut payload = self.stdout.by_ref().take(len);
        let skipped =
            std::io::copy(&mut payload, &mut std::io::sink()).map_err(|_| FetchError::Failed)?;
        if skipped != len {
            return Err(FetchError::Failed);
        }
        self.left -= len;
        Ok(())
    }

    /// Reads the newline that closes a fully read payload: the stream is then at the next header.
    fn end(&mut self) -> Result<(), FetchError> {
        if self.left != 0 {
            return Err(FetchError::Failed);
        }
        let mut newline = [0u8; 1];
        self.stdout.read_exact(&mut newline).map_err(|_| FetchError::Failed)?;
        if newline != *b"\n" {
            return Err(FetchError::Failed);
        }
        self.in_step = true;
        Ok(())
    }

    /// Skips the rest of the current payload and its newline, when that is at most
    /// [`DRAIN_BYTES`]; a longer rest leaves the process out of step, to be dropped.
    fn drain(&mut self) -> Result<(), FetchError> {
        if self.left > DRAIN_BYTES {
            return Err(FetchError::Failed);
        }
        self.skip(self.left)?;
        self.end()
    }

    /// The whole of blob `oid` when it holds at most `max` bytes; a bigger one is refused
    /// without reading it into memory.
    fn blob(&mut self, oid: &str, max: u64) -> Result<Vec<u8>, FetchError> {
        let size = self.start(oid)?;
        if size > max {
            let _ = self.drain();
            return Err(FetchError::Failed);
        }
        let bytes = self.take(size)?;
        self.end()?;
        Ok(bytes)
    }
}

/// Reads blobs of a git object store by id, for a seed ([`crate::peers::serve`]).
pub struct ObjectReader {
    cat: CatFile,
    git_dir: PathBuf,
    local: bool,
}

impl ObjectReader {
    pub fn spawn(git_dir: &Path) -> anyhow::Result<Self> {
        Ok(Self { cat: CatFile::spawn(git_dir)?, git_dir: git_dir.to_owned(), local: false })
    }

    /// Starts a reader that never asks a promisor remote for a missing object.
    pub fn spawn_local(git_dir: &Path) -> anyhow::Result<Self> {
        Ok(Self { cat: CatFile::spawn_local(git_dir)?, git_dir: git_dir.to_owned(), local: true })
    }

    /// The blob's bytes, or `None` when the store has no blob by that id or it is bigger than a
    /// peer takes ([`crate::peers::MAX_HTTP_BODY_BYTES`]), so a seed never holds a huge blob.
    pub fn blob(&mut self, oid: &str) -> Option<Vec<u8>> {
        let max = crate::peers::MAX_HTTP_BODY_BYTES as u64;
        let bytes = self.cat.blob(oid, max).ok();
        if !self.cat.in_step() {
            let respawned = if self.local {
                CatFile::spawn_local(&self.git_dir)
            } else {
                CatFile::spawn(&self.git_dir)
            };
            // With no new process the old one answers every later request as failed.
            if let Ok(cat) = respawned {
                self.cat = cat;
            }
        }
        bytes
    }
}

/// The most blobs (or ranges of one) kept in memory, and their bytes, so a file read in many
/// pieces costs one object read.
const RECENT_FILES: usize = 64;
const RECENT_BYTES: usize = 64 * 1024 * 1024;
/// Blobs up to this size are read whole and kept; a bigger one is streamed a range at a time and
/// only the ranges read are kept, each at most this size.
const WHOLE_BYTES: u64 = 8 * 1024 * 1024;
/// The most streams held part way through a big blob, ready to go on from where they stopped.
const STREAMS: usize = 4;

/// Bytes kept from a blob: the whole of it (`start` 0, `bytes` of length `size`) or one range.
struct Held {
    entry: u32,
    start: u64,
    /// The blob's size.
    size: u64,
    bytes: Arc<Vec<u8>>,
}

impl Held {
    /// `len` bytes at `offset` (fewer at the blob's end), when this holds all of them.
    fn get(&self, entry: u32, offset: u64, len: u64) -> Option<Vec<u8>> {
        if entry != self.entry || offset < self.start {
            return None;
        }
        let end = self.start.saturating_add(self.bytes.len() as u64);
        let want = offset.saturating_add(len).min(self.size);
        if want > end {
            return None;
        }
        Some(range(&self.bytes, self.start, offset, len))
    }
}

/// A `git cat-file --batch` part way through blob `entry`'s payload, at byte `at` of its `size`.
struct Stream {
    entry: u32,
    at: u64,
    size: u64,
    cat: CatFile,
}

/// `len` bytes at `offset` of a blob whose bytes from `start` on are `bytes` (fewer at its end).
fn range(bytes: &[u8], start: u64, offset: u64, len: u64) -> Vec<u8> {
    let from = usize::try_from(offset.saturating_sub(start)).unwrap_or(usize::MAX).min(bytes.len());
    let to = from.saturating_add(usize::try_from(len).unwrap_or(usize::MAX)).min(bytes.len());
    bytes.get(from..to).unwrap_or_default().to_vec()
}

/// A projection's bytes from the host's git object store: a pool of `git cat-file --batch`
/// processes, the streams part way through big blobs, and the last few blobs and ranges read.
/// Nothing is copied to disk, and memory stays bounded whatever a blob's size: at most
/// [`RECENT_BYTES`] kept, and a read holds only the range asked for.
pub struct GitBlobs {
    git_dir: PathBuf,
    /// The git program (a stand-in in tests).
    program: OsString,
    sources: Vec<Source>,
    pool: Mutex<Vec<CatFile>>,
    streams: Mutex<VecDeque<Stream>>,
    recent: Mutex<VecDeque<Held>>,
}

impl GitBlobs {
    #[must_use]
    pub fn new(git_dir: &Path, sources: Vec<Source>) -> Self {
        Self {
            git_dir: git_dir.to_owned(),
            program: OsString::from("git"),
            sources,
            pool: Mutex::new(Vec::new()),
            streams: Mutex::new(VecDeque::new()),
            recent: Mutex::new(VecDeque::new()),
        }
    }

    /// Bytes kept in memory now (never more than [`RECENT_BYTES`]).
    #[must_use]
    pub fn retained(&self) -> usize {
        let recent = self.recent.lock().unwrap_or_else(PoisonError::into_inner);
        recent.iter().map(|held| held.bytes.len()).sum()
    }

    fn cat(&self) -> Result<CatFile, FetchError> {
        let taken = self.pool.lock().unwrap_or_else(PoisonError::into_inner).pop();
        match taken {
            Some(cat) => Ok(cat),
            None => CatFile::spawn_with(&self.program, &self.git_dir, false)
                .map_err(|_| FetchError::Failed),
        }
    }

    /// Returns `cat` to the pool when it is ready for a request; a process out of step ends.
    fn put(&self, cat: CatFile) {
        if cat.in_step() {
            self.pool.lock().unwrap_or_else(PoisonError::into_inner).push(cat);
        }
    }

    fn held(&self, entry: u32, offset: u64, len: u64) -> Option<Vec<u8>> {
        let recent = self.recent.lock().unwrap_or_else(PoisonError::into_inner);
        recent.iter().find_map(|held| held.get(entry, offset, len))
    }

    /// Keeps `bytes`, forgetting the oldest until at most [`RECENT_FILES`] pieces and
    /// [`RECENT_BYTES`] bytes are kept. A piece bigger than [`WHOLE_BYTES`] is not kept.
    fn hold(&self, held: Held) {
        if held.bytes.len() as u64 > WHOLE_BYTES || held.bytes.is_empty() {
            return;
        }
        let mut recent = self.recent.lock().unwrap_or_else(PoisonError::into_inner);
        recent.push_front(held);
        let mut total = 0;
        let mut keep = 0;
        for held in recent.iter() {
            if keep >= RECENT_FILES || total + held.bytes.len() > RECENT_BYTES {
                break;
            }
            total += held.bytes.len();
            keep += 1;
        }
        recent.truncate(keep);
    }

    /// The stream of `entry` furthest along that has not passed `offset`.
    fn take_stream(&self, entry: u32, offset: u64) -> Option<Stream> {
        let mut streams = self.streams.lock().unwrap_or_else(PoisonError::into_inner);
        let at = streams
            .iter()
            .enumerate()
            .filter(|(_, stream)| stream.entry == entry && stream.at <= offset)
            .max_by_key(|(_, stream)| stream.at)
            .map(|(at, _)| at)?;
        streams.remove(at)
    }

    /// Keeps `stream` for the next range, ending the least recently used one past [`STREAMS`].
    fn keep_stream(&self, stream: Stream) {
        let retired = {
            let mut streams = self.streams.lock().unwrap_or_else(PoisonError::into_inner);
            streams.push_front(stream);
            if streams.len() > STREAMS { streams.pop_back() } else { None }
        };
        if let Some(mut retired) = retired {
            // A short rest is drained so the process serves again; a long one ends it.
            if retired.cat.drain().is_ok() {
                self.put(retired.cat);
            }
        }
    }

    /// Starts reading blob `entry`: the whole of it, kept, when it is small; else a stream at 0.
    fn open(&self, entry: u32, oid: &str) -> Result<Result<Arc<Vec<u8>>, Stream>, FetchError> {
        let mut cat = self.cat()?;
        let size = match cat.start(oid) {
            Ok(size) => size,
            Err(error) => {
                self.put(cat);
                return Err(error);
            }
        };
        if size > WHOLE_BYTES {
            return Ok(Err(Stream { entry, at: 0, size, cat }));
        }
        let bytes = cat.take(size)?;
        cat.end()?;
        self.put(cat);
        let bytes = Arc::new(bytes);
        self.hold(Held { entry, start: 0, size, bytes: bytes.clone() });
        Ok(Ok(bytes))
    }

    /// `len` bytes at `offset` of big blob `stream`, holding only them; the stream goes on from
    /// where they end.
    fn read_stream(
        &self,
        mut stream: Stream,
        offset: u64,
        len: u64,
    ) -> Result<Vec<u8>, FetchError> {
        if offset >= stream.size {
            self.keep_stream(stream);
            return Ok(Vec::new());
        }
        let len = len.min(stream.size - offset);
        stream.cat.skip(offset - stream.at)?;
        let bytes = stream.cat.take(len)?;
        stream.at = offset + len;
        let bytes = Arc::new(bytes);
        self.hold(Held {
            entry: stream.entry,
            start: offset,
            size: stream.size,
            bytes: bytes.clone(),
        });
        if stream.at == stream.size {
            stream.cat.end()?;
            self.put(stream.cat);
        } else {
            self.keep_stream(stream);
        }
        Ok(Arc::unwrap_or_clone(bytes))
    }
}

impl Fetch for GitBlobs {
    fn read(&self, entry: u32, offset: u64, len: u32) -> Result<Vec<u8>, FetchError> {
        let len = u64::from(len);
        let oid = match self.sources.get(entry as usize) {
            Some(Source::Blob(oid)) => oid,
            Some(Source::Bytes(bytes)) => return Ok(range(bytes, 0, offset, len)),
            _ => return Err(FetchError::Failed),
        };
        if let Some(bytes) = self.held(entry, offset, len) {
            return Ok(bytes);
        }
        let stream = match self.take_stream(entry, offset) {
            Some(stream) => stream,
            None => match self.open(entry, oid)? {
                Ok(whole) => return Ok(range(&whole, 0, offset, len)),
                Err(stream) => stream,
            },
        };
        self.read_stream(stream, offset, len)
    }

    /// Whole files, for small ones only: a blob over [`WHOLE_BYTES`] is refused (the overlay
    /// reads a big file a range at a time).
    fn batch(&self, entries: &[u32]) -> Vec<Result<Vec<u8>, FetchError>> {
        entries
            .iter()
            .map(|entry| {
                let oid = match self.sources.get(*entry as usize) {
                    Some(Source::Blob(oid)) => oid,
                    Some(Source::Bytes(bytes)) => return Ok(bytes.clone()),
                    _ => return Err(FetchError::Failed),
                };
                if let Some(bytes) = self.held(*entry, 0, WHOLE_BYTES + 1) {
                    return Ok(bytes);
                }
                match self.open(*entry, oid)? {
                    Ok(whole) => Ok(Arc::unwrap_or_clone(whole)),
                    Err(mut stream) => {
                        if stream.cat.drain().is_ok() {
                            self.put(stream.cat);
                        }
                        Err(FetchError::Failed)
                    }
                }
            })
            .collect()
    }

    fn cache(&self) -> bool {
        false
    }
}

#[cfg(test)]
#[path = "git_tests.rs"]
mod tests;
