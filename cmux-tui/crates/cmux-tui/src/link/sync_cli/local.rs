//! The local side of `cmux link sync push`: which files of a working copy
//! go to the machine, and the git state that goes with them.
//!
//! In a git working copy (its top folder; a subfolder is refused): the
//! files `git ls-files --cached --others --exclude-standard` names (tracked,
//! and untracked ones that are not ignored, minus untracked `.env*` and credential files,
//! which are shared only on purpose), plus the repository itself as
//! `.git/`, so the branch, HEAD, index, stash and uncommitted changes
//! arrive exactly. What goes of the repository is allow-listed
//! ([`GIT_TOP`]); hooks never go at any level (they would run on the
//! machine, submodules' included), nor other worktrees' folders, lock files,
//! `FETCH_HEAD` (it names remote URLs) or LFS objects. Every git config file
//! (`config`, `config.worktree`, submodules' too) keeps only allow-listed
//! settings ([`clean_config`]), and URL user info is cut from them and from
//! reflogs. A linked worktree arrives as a plain repository: the common
//! folder without its checkout's own state, then the worktree's own HEAD,
//! index, logs and in-progress state over it. A repository that borrows
//! objects from another (`objects/info/alternates`, as `git clone --shared`
//! or `--reference` and worktree mirrors make) arrives standing alone: the
//! borrowed stores' object files (git's own: loose objects, packs, commit
//! graphs; nothing else of those folders) go into its `objects/` too, and the
//! alternates file, whose paths name folders of this Mac, never goes.
//!
//! Outside git, every regular file of the folder goes, except for a chat's
//! copy the dependency and build folders its project rebuilds on the
//! machine ([`skips::heavy`]) and secrets (`.env*`, key files: [`skips::secret`];
//! credential folders and files at any depth: [`skips::credential`]).
//! A symlink whose target stays inside the folder goes as a symlink
//! ([`super::links`]); other symlinks, special files and names the machine
//! cannot hold (control characters, over 255 bytes, not UTF-8) are skipped. Every skip is
//! named with why ([`Skips`]), except the git path's untracked `.env*` and
//! non-UTF-8 paths, which are counted.

use cmux_process::Command;
use std::collections::{BTreeMap, BTreeSet, HashSet};
use std::os::unix::ffi::OsStrExt as _;
use std::path::{Path, PathBuf};

use anyhow::{Context as _, bail};

use super::place;
use super::skips::{self, Skips, Why};

pub(super) use super::listed::{add_entry, add_working, entry_in, git_text, open_listed, walk_in};

/// Where one file to push comes from.
#[derive(Clone, Debug)]
pub(super) enum Source {
    File(PathBuf),
    /// A file an upload checked below its folder, opened one name at a time
    /// with no symlink followed, and only while it and the folder are still
    /// the device and inode they were when checked.
    Checked(Checked),
    /// Bytes made here (a cleaned git config or reflog).
    Bytes(Vec<u8>),
}

/// A file an upload checked ([`Source::Checked`]).
#[derive(Clone, Debug)]
pub(super) struct Checked {
    pub root: PathBuf,
    pub relative: String,
    pub root_identity: (u64, u64),
    pub identity: (u64, u64),
}

/// One file to push, by its path relative to the folder.
#[derive(Clone, Debug)]
pub(super) struct LocalFile {
    pub source: Source,
    /// 0644, 0755, 0600 or 0700: the executable bit and whether group and
    /// others could read it here.
    pub permissions: u32,
    /// The device and inode a [`Source::File`] had when it was listed: the
    /// read refuses another file found at its path since (a folder above it
    /// swapped for a symlink), see [`open_listed`].
    pub id: Option<(u64, u64)>,
}

/// The files to push and what was skipped.
pub(super) struct LocalSet {
    pub files: BTreeMap<String, LocalFile>,
    /// Symlinks kept as symlinks ([`super::links`]), by path.
    pub links: BTreeMap<String, super::Linked>,
    /// Skips counted without a name.
    pub skipped: u64,
    /// Skips named with why.
    pub skips: Skips,
    pub git: bool,
    /// The copy's limits, counted as files are added ([`super::size_cap`]); none for a share.
    pub cap: Option<super::size_cap::Cap>,
}

impl LocalSet {
    fn new(skips: Skips) -> Self {
        Self {
            files: BTreeMap::new(),
            links: BTreeMap::new(),
            skipped: 0,
            skips,
            git: false,
            cap: None,
        }
    }

    /// Adds `file` as `relative`, `bytes` long, counted against the copy's limits: a
    /// [`super::size_cap::TooLarge`] error once one is passed, and nothing more is listed.
    pub(super) fn add(
        &mut self,
        relative: String,
        file: LocalFile,
        bytes: u64,
    ) -> anyhow::Result<()> {
        if let Some(cap) = self.cap.as_mut() {
            cap.charge(&relative, bytes)?;
        }
        self.files.insert(relative, file);
        Ok(())
    }
}

/// What [`collect`] leaves out beyond what every push does.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Rules {
    /// Outside git, dependency and build folders and secrets stay here (a
    /// chat's copy: `cmux link sync push`, `cmux link start-chat copy`).
    Copy,
    /// Every regular file goes (a `cmux link access` share, which filters
    /// by its own rule).
    Share,
}

/// What goes from the top of a git folder.
const GIT_TOP: &[&str] = &[
    "HEAD",
    "ORIG_HEAD",
    "MERGE_HEAD",
    "MERGE_MSG",
    "MERGE_MODE",
    "MERGE_RR",
    "CHERRY_PICK_HEAD",
    "REVERT_HEAD",
    "AUTO_MERGE",
    "SQUASH_MSG",
    "COMMIT_EDITMSG",
    "BISECT_LOG",
    "BISECT_START",
    "BISECT_TERMS",
    "BISECT_EXPECTED_REV",
    "BISECT_ANCESTORS_OK",
    "BISECT_NAMES",
    "BISECT_RUN",
    "config",
    "config.worktree",
    "description",
    "index",
    "packed-refs",
    "shallow",
    "info",
    "logs",
    "objects",
    "refs",
    "modules",
    "rebase-merge",
    "rebase-apply",
    "sequencer",
    "rr-cache",
];

/// A checkout's own state: in a linked worktree it comes from the worktree's
/// folder, never from the common one (which holds the main checkout's).
const PER_WORKTREE: &[&str] = &[
    "HEAD",
    "ORIG_HEAD",
    "MERGE_HEAD",
    "MERGE_MSG",
    "MERGE_MODE",
    "MERGE_RR",
    "CHERRY_PICK_HEAD",
    "REVERT_HEAD",
    "AUTO_MERGE",
    "SQUASH_MSG",
    "COMMIT_EDITMSG",
    "BISECT_LOG",
    "BISECT_START",
    "BISECT_TERMS",
    "BISECT_EXPECTED_REV",
    "BISECT_ANCESTORS_OK",
    "BISECT_NAMES",
    "BISECT_RUN",
    "config.worktree",
    "index",
    "rebase-merge",
    "rebase-apply",
    "sequencer",
    "logs/HEAD",
    "refs/bisect",
    "refs/worktree",
    "logs/refs/bisect",
    "logs/refs/worktree",
    "info/sparse-checkout",
];

/// Longest name and path the machine's file owner takes.
const MAX_NAME_BYTES: usize = 255;
const MAX_PATH_BYTES: usize = 4000;

/// The files a push of `folder` sends, by `rules`, counted against `cap` (a chat's copy, see
/// [`super::size_cap`]) as they are listed: it stops with a [`super::size_cap::TooLarge`] error the
/// moment a limit is passed; `None` counts nothing.
pub(super) fn collect(
    folder: &Path,
    rules: Rules,
    cap: Option<super::size_cap::Cap>,
) -> anyhow::Result<LocalSet> {
    let mut set = LocalSet::new(Skips::new(folder));
    set.cap = cap;
    let Some(git) = GitDirs::of(folder)? else {
        walk_plain(&mut set, rules, &|_| true, folder, folder)?;
        return Ok(set);
    };
    set.git = true;
    let top = place::Dir::open(folder)?;
    // Each file is counted as git lists it: past the copy's limit the listing stops there.
    let mut skipped = 0;
    working_files(folder, &mut skipped, &mut |path, untracked| {
        // An untracked credential file never goes either (tracked ones were committed on purpose).
        if untracked
            && (path.rsplit('/').next().is_some_and(|name| name.starts_with(".env"))
                || skips::credential(&path, false).is_some())
        {
            set.skipped += 1;
            return Ok(());
        }
        add_working(&mut set, &top, folder, &path)
    })?;
    set.skipped += skipped;
    // A share of files sends no git state (`cmux link access` keeps no `.git` path), so it reads none:
    // an unreadable reflog or config never fails it.
    if rules == Rules::Share {
        return Ok(set);
    }
    let linked = git.own != git.common;
    let common = place::Dir::open(&git.common)?;
    walk_in(&common, "", &mut |relative, dir, name, entry| {
        if linked && is_per_worktree(relative) {
            return Ok(());
        }
        add_git(&mut set, relative, &git.common.join(relative), dir, name, entry)
    })?;
    if linked {
        let own = place::Dir::open(&git.own)?;
        walk_in(&own, "", &mut |relative, dir, name, entry| {
            if relative == "commondir" || relative == "gitdir" {
                return Ok(());
            }
            add_git(&mut set, relative, &git.own.join(relative), dir, name, entry)
        })?;
    }
    // Borrowed objects go after the repository's own, which win a name both
    // hold (a loose object or pack of the same hash is the same data).
    for borrowed in borrowed_objects(&git.common.join("objects"))? {
        let handle = place::Dir::open(&borrowed)?;
        walk_in(&handle, "", &mut |relative, dir, name, entry| {
            if borrowed_skipped(relative) {
                return Ok(());
            }
            // Only git's own object files go: anything else in a borrowed
            // folder (which may be anywhere on this Mac) stays, counted.
            if !borrowed_object(relative) {
                set.skipped += 1;
                return Ok(());
            }
            let target = format!(".git/objects/{relative}");
            if set.files.contains_key(&target) {
                return Ok(());
            }
            add_entry(&mut set, target, &borrowed.join(relative), dir, name, entry)
        })?;
    }
    Ok(set)
}

/// A dropped folder's own files for a one-off upload: git's ignore rules
/// apply when it is in a working copy, its top or any folder inside one, and
/// no git state goes, not even a bare repository's (a folder holding `HEAD`
/// with `objects/`, `refs/` or `commondir`, whatever its name). Another
/// repository inside it stays whole.
///
/// A folder `enter` refuses (by its path from `folder`) is left out whole
/// and counted once, never listed, so one this Mac's user cannot read (a
/// `.config` of mode 000) fails nothing.
pub(super) fn collect_files(
    folder: &Path,
    enter: &dyn Fn(&str) -> bool,
) -> anyhow::Result<LocalSet> {
    // The folder or one above it being git's own state (`bare/objects`, say).
    if folder.ancestors().any(git_state) {
        bail!("{} is in a git repository's own folder", folder.display());
    }
    let mut set = listed_files(folder, enter)?;
    let mut fenced: BTreeMap<PathBuf, bool> = BTreeMap::new();
    let before = set.files.len();
    set.files.retain(|relative, _| {
        !Path::new(relative).ancestors().skip(1).filter(|dir| !dir.as_os_str().is_empty()).any(
            |dir| *fenced.entry(dir.to_path_buf()).or_insert_with(|| fenced_dir(&folder.join(dir))),
        )
    });
    let left = u64::try_from(before.saturating_sub(set.files.len())).unwrap_or(u64::MAX);
    set.skipped = set.skipped.saturating_add(left);
    Ok(set)
}

/// A folder of git's own state: a bare repository, a `.git` folder by
/// another name, or a linked worktree's. Any `HEAD` beside any `objects`,
/// `refs` or `commondir` counts, a symlink or not, since git takes either.
fn git_state(dir: &Path) -> bool {
    let has = |name: &str| std::fs::symlink_metadata(dir.join(name)).is_ok();
    has("HEAD") && (has("objects") || has("refs") || has("commondir"))
}

/// A folder inside the dropped one that is git's state or another
/// repository's working copy (any `.git` in it): its files stay, since
/// their own ignore rules are not the dropped folder's.
fn fenced_dir(dir: &Path) -> bool {
    git_state(dir) || std::fs::symlink_metadata(dir.join(".git")).is_ok()
}

/// The top of the working copy `folder` is in, or None when it is in none.
/// A failed answer while `folder` or a folder above it holds a `.git` (a
/// repository git will not read, for its owner, an extension it does not
/// know or a `.git` pointing nowhere) is an error, as is `folder` inside
/// git's own folder: walking the folder plainly would send what git ignores.
fn work_tree_top(folder: &Path) -> anyhow::Result<Option<PathBuf>> {
    let output = Command::new("git")
        .args(["-c", "core.fsmonitor=false", "-c", "safe.bareRepository=explicit"])
        .args(["-c", "core.hooksPath=/dev/null", "-C"])
        .arg(folder)
        .args(["rev-parse", "--show-toplevel"])
        .output();
    let in_git =
        || folder.ancestors().any(|dir| std::fs::symlink_metadata(dir.join(".git")).is_ok());
    let output = match output {
        // With no git on this Mac, a folder with no `.git` on its way is plain.
        Err(error) if error.kind() == std::io::ErrorKind::NotFound && !in_git() => return Ok(None),
        other => other.context("cannot run git")?,
    };
    if !output.status.success() {
        if !in_git() {
            return Ok(None);
        }
        bail!(
            "git cannot read the repository {} is in: {}",
            folder.display(),
            String::from_utf8_lossy(&output.stderr).trim()
        );
    }
    let top = String::from_utf8(output.stdout).context("git printed text that is not UTF-8")?;
    let top = top.trim();
    if top.is_empty() {
        bail!("{} is inside a git repository's own folder", folder.display());
    }
    Ok(Some(std::fs::canonicalize(top).unwrap_or_else(|_| PathBuf::from(top))))
}

fn listed_files(folder: &Path, enter: &dyn Fn(&str) -> bool) -> anyhow::Result<LocalSet> {
    let mut set = LocalSet::new(Skips::new(folder));
    let Some(top) = work_tree_top(folder)? else {
        walk_plain(&mut set, Rules::Share, enter, folder, folder)?;
        return Ok(set);
    };
    // A repository whose working copy is somewhere else (its `core.worktree`)
    // lists files that are not this folder's.
    if !folder.starts_with(&top) {
        bail!("{} is not in its repository's working copy {}", folder.display(), top.display());
    }
    set.git = true;
    let handle = place::Dir::open(folder)?;
    // Run in the folder, git lists only what is under it, by paths from it.
    let mut refused: BTreeSet<String> = BTreeSet::new();
    let mut skipped = 0;
    working_files(folder, &mut skipped, &mut |path, untracked| {
        // A crafted index can name a file anywhere: only a plain path below
        // the folder is the folder's.
        if !below(&path)
            || untracked && path.rsplit('/').next().is_some_and(|name| name.starts_with(".env"))
        {
            set.skipped = set.skipped.saturating_add(1);
            return Ok(());
        }
        // A file in a folder `enter` refuses is never looked at; the folder
        // counts once.
        if let Some(dir) = refused_dir(&path, enter) {
            if refused.insert(dir) {
                set.skipped = set.skipped.saturating_add(1);
            }
            return Ok(());
        }
        add_working(&mut set, &handle, folder, &path)
    })?;
    set.skipped = set.skipped.saturating_add(skipped);
    Ok(set)
}

/// The first folder on the way to `path` (`a`, then `a/b`, ...) that
/// `enter` refuses.
fn refused_dir(path: &str, enter: &dyn Fn(&str) -> bool) -> Option<String> {
    path.match_indices('/')
        .filter_map(|(slash, _)| path.get(..slash))
        .find(|dir| !enter(dir))
        .map(str::to_string)
}

/// A relative path that stays below its folder: no root, no empty, `.` or
/// `..` part.
pub(super) fn below(path: &str) -> bool {
    !path.starts_with('/') && path.split('/').all(|part| !matches!(part, "" | "." | ".."))
}

/// Most alternates levels git follows.
const ALTERNATES_DEPTH: usize = 5;

/// The object folders `objects` borrows from (`info/alternates`), and the
/// ones those borrow from in turn, each once, nearest first. A path in an
/// alternates file is absolute or relative to the object folder holding it.
fn borrowed_objects(objects: &Path) -> anyhow::Result<Vec<PathBuf>> {
    let mut seen: BTreeSet<PathBuf> =
        BTreeSet::from([std::fs::canonicalize(objects).unwrap_or_else(|_| objects.into())]);
    let mut found = Vec::new();
    let mut level = vec![objects.to_path_buf()];
    for _ in 0..ALTERNATES_DEPTH {
        let mut next = Vec::new();
        for dir in &level {
            let Ok(bytes) = std::fs::read(dir.join("info/alternates")) else { continue };
            for line in bytes.split(|byte| *byte == b'\n') {
                let line = line.strip_suffix(b"\r").unwrap_or(line);
                if line.is_empty() || line.starts_with(b"#") {
                    continue;
                }
                let named = unquote(line);
                let path = dir.join(std::ffi::OsStr::from_bytes(&named));
                let path = std::fs::canonicalize(&path).with_context(|| {
                    format!(
                        "{} borrows objects from {}, which cannot be read",
                        dir.display(),
                        path.display()
                    )
                })?;
                if seen.insert(path.clone()) {
                    found.push(path.clone());
                    next.push(path);
                }
            }
        }
        level = next;
    }
    Ok(found)
}

/// An alternates line as a path: one in double quotes is C-quoted the way
/// git writes it (`\\`, `\"`, `\t`, `\n`, octal `\NNN`).
fn unquote(line: &[u8]) -> Vec<u8> {
    let Some(inner) = line.strip_prefix(b"\"").and_then(|rest| rest.strip_suffix(b"\"")) else {
        return line.to_vec();
    };
    let mut out = Vec::with_capacity(inner.len());
    let mut bytes = inner.iter().copied().peekable();
    while let Some(byte) = bytes.next() {
        if byte != b'\\' {
            out.push(byte);
            continue;
        }
        match bytes.next() {
            Some(b'n') => out.push(b'\n'),
            Some(b't') => out.push(b'\t'),
            Some(digit @ b'0'..=b'7') => {
                let mut value = u32::from(digit - b'0');
                for _ in 0..2 {
                    match bytes.peek().copied() {
                        Some(next @ b'0'..=b'7') => {
                            value = value * 8 + u32::from(next - b'0');
                            bytes.next();
                        }
                        _ => break,
                    }
                }
                out.push(u8::try_from(value).unwrap_or(u8::MAX));
            }
            Some(other) => out.push(other),
            None => out.push(b'\\'),
        }
    }
    out
}

/// Whether a file of a borrowed object folder (by its path in the folder)
/// stays here: its own alternates and the indexes that describe only its
/// packs or commits (the repository's own describe the copy).
fn borrowed_skipped(relative: &str) -> bool {
    matches!(
        relative,
        "info/alternates"
            | "info/http-alternates"
            | "info/packs"
            | "info/commit-graph"
            | "info/commit-graphs/commit-graph-chain"
    ) || relative.starts_with("pack/multi-pack-index")
        || relative.ends_with(".lock")
        || relative.rsplit('/').next().is_some_and(|name| name.starts_with("tmp_"))
}

/// Whether a file of a borrowed object folder (by its path in the folder)
/// is one of git's object files: a loose object (`xx/` and 38 more hex
/// digits, 62 for SHA-256), a pack and its companions, or a commit graph.
/// Symlinks are never followed ([`walk`], [`add`]).
fn borrowed_object(relative: &str) -> bool {
    let hex = |text: &str| {
        !text.is_empty() && text.bytes().all(|byte| matches!(byte, b'0'..=b'9' | b'a'..=b'f'))
    };
    let parts: Vec<&str> = relative.split('/').collect();
    match parts.as_slice() {
        [dir, file] if dir.len() == 2 && hex(dir) => matches!(file.len(), 38 | 62) && hex(file),
        ["pack", file] => file
            .strip_prefix("pack-")
            .and_then(|rest| rest.split_once('.'))
            .is_some_and(|(hash, extension)| {
                hex(hash)
                    && matches!(
                        extension,
                        "pack" | "idx" | "rev" | "promisor" | "bitmap" | "mtimes" | "keep"
                    )
            }),
        ["info", "commit-graph"] => true,
        ["info", "commit-graphs", "commit-graph-chain"] => true,
        ["info", "commit-graphs", file] => file
            .strip_prefix("graph-")
            .and_then(|rest| rest.strip_suffix(".graph"))
            .is_some_and(hex),
        _ => false,
    }
}

/// A working copy's own git folder and the common one (the same folder
/// except in a linked worktree).
pub(super) struct GitDirs {
    pub own: PathBuf,
    pub common: PathBuf,
}

impl GitDirs {
    /// None outside git. A subfolder of a working copy is refused: its
    /// repository is above it, so pushing it alone would lose the git state.
    pub(super) fn of(folder: &Path) -> anyhow::Result<Option<Self>> {
        let Some(top) = work_tree_top(folder)? else { return Ok(None) };
        if top != folder {
            bail!(
                "{} is inside the git working copy {}; push its top folder",
                folder.display(),
                top.display()
            );
        }
        let output =
            git(folder, &["rev-parse", "--path-format=absolute", "--git-dir", "--git-common-dir"])?;
        let mut lines = output.lines();
        match (lines.next(), lines.next()) {
            (Some(own), Some(common)) => Ok(Some(Self { own: own.into(), common: common.into() })),
            _ => bail!("git rev-parse gave no git folder for {}", folder.display()),
        }
    }
}

/// Calls `each(path, untracked)` for every tracked and untracked-not-ignored
/// path, once, as `git ls-files` prints it: the listing streams, so an error
/// from `each` (a copy's [`super::size_cap::TooLarge`] at the first file past
/// its limit) stops git there instead of after millions of names. A path that
/// is not UTF-8 is skipped and counted.
pub(super) fn working_files(
    folder: &Path,
    skipped: &mut u64,
    each: &mut dyn FnMut(String, bool) -> anyhow::Result<()>,
) -> anyhow::Result<()> {
    // A conflicted path is listed once a stage; it goes once.
    let mut tracked: HashSet<String> = HashSet::new();
    git_listing(folder, &["ls-files", "-z", "--cached"], &mut |path| {
        let Ok(path) = String::from_utf8(path) else {
            *skipped += 1;
            return Ok(());
        };
        if !tracked.insert(path.clone()) {
            return Ok(());
        }
        each(path, false)
    })?;
    git_listing(folder, &["ls-files", "-z", "--others", "--exclude-standard"], &mut |path| {
        let Ok(path) = String::from_utf8(path) else {
            *skipped += 1;
            return Ok(());
        };
        if tracked.contains(&path) {
            return Ok(());
        }
        each(path, true)
    })
}

/// Runs git as [`git_bytes`] does and calls `each` with every NUL-ended name
/// it prints, as it prints it. An error from `each` stops git (killed, then
/// reaped) and is returned.
fn git_listing(
    folder: &Path,
    args: &[&str],
    each: &mut dyn FnMut(Vec<u8>) -> anyhow::Result<()>,
) -> anyhow::Result<()> {
    use std::io::{BufRead as _, Read as _};
    let mut child = git_command(folder, args)
        .stdout(cmux_process::Stdio::piped())
        .stderr(cmux_process::Stdio::piped())
        .spawn()
        .context("cannot run git")?;
    // git's stderr is read beside its stdout, so a full stderr pipe never blocks it.
    let stderr = child.stderr.take().map(|mut stderr| {
        std::thread::spawn(move || {
            let mut bytes = Vec::new();
            let _ = stderr.read_to_end(&mut bytes);
            bytes
        })
    });
    let stdout = child.stdout.take().context("git gave no output pipe")?;
    let mut reader = std::io::BufReader::new(stdout);
    let mut read = || -> anyhow::Result<()> {
        let mut name = Vec::new();
        loop {
            name.clear();
            if reader.read_until(0, &mut name).context("cannot read git's output")? == 0 {
                return Ok(());
            }
            if name.last() == Some(&0) {
                name.pop();
            }
            if !name.is_empty() {
                each(std::mem::take(&mut name))?;
            }
        }
    };
    let listed = read();
    if listed.is_err() {
        let _ = child.kill();
    }
    drop(reader);
    let status = child.wait().context("cannot wait for git")?;
    let stderr = stderr.and_then(|reader| reader.join().ok()).unwrap_or_default();
    listed?;
    if !status.success() {
        bail!("git {}: {}", args.join(" "), String::from_utf8_lossy(&stderr).trim());
    }
    Ok(())
}

pub(super) fn git(folder: &Path, args: &[&str]) -> anyhow::Result<String> {
    String::from_utf8(git_bytes(folder, args)?).context("git printed text that is not UTF-8")
}

/// git reading a folder, never running anything the folder's own config
/// names (an fsmonitor or a hook) and never taking a bare repository in it
/// for its own.
pub(super) fn git_bytes(folder: &Path, args: &[&str]) -> anyhow::Result<Vec<u8>> {
    let output = git_command(folder, args).output().context("cannot run git")?;
    if !output.status.success() {
        bail!("git {}: {}", args.join(" "), String::from_utf8_lossy(&output.stderr).trim());
    }
    Ok(output.stdout)
}

/// git in `folder` with `args`, by [`git_bytes`]'s rules.
fn git_command(folder: &Path, args: &[&str]) -> Command {
    let mut command = Command::new("git");
    command
        .args(["-c", "core.fsmonitor=false", "-c", "safe.bareRepository=explicit"])
        .args(["-c", "core.hooksPath=/dev/null", "-C"])
        .arg(folder)
        .args(args);
    command
}

/// Whether `relative` (in a git folder) is a checkout's own state.
fn is_per_worktree(relative: &str) -> bool {
    PER_WORKTREE.iter().any(|name| relative == *name || relative.starts_with(&format!("{name}/")))
}

/// Adds the file at `relative` of a git folder as `.git/<relative>`, by the
/// rules in the module doc.
fn add_git(
    set: &mut LocalSet,
    relative: &str,
    path: &Path,
    dir: &place::Dir,
    name: &str,
    entry: place::Entry,
) -> anyhow::Result<()> {
    let parts: Vec<&str> = relative.split('/').collect();
    if !GIT_TOP.contains(&parts[0]) || relative.ends_with(".lock") {
        return Ok(());
    }
    // Paths of this Mac: the borrowed objects go instead ([`collect`]).
    if matches!(relative, "objects/info/alternates" | "objects/info/http-alternates") {
        return Ok(());
    }
    // Below refs/, logs/ and objects/ names are refs and hashes, never
    // hooks or config files, so a branch called `hooks` still goes.
    let data_at = parts.iter().position(|part| matches!(*part, "refs" | "logs" | "objects"));
    let before_data = &parts[..data_at.unwrap_or(parts.len())];
    if before_data.iter().any(|part| matches!(*part, "hooks" | "worktrees" | "lfs" | "FETCH_HEAD"))
    {
        return Ok(());
    }
    let target = format!(".git/{relative}");
    let read = || git_text(dir, name, &entry, path);
    if data_at.is_none() && matches!(name, "config" | "config.worktree") {
        let Some(bytes) = read()? else { return Ok(()) };
        let text = String::from_utf8_lossy(&bytes).into_owned();
        let bytes = clean_config(&text).into_bytes();
        let size = bytes.len() as u64;
        let source = Source::Bytes(bytes);
        set.add(target, LocalFile { source, permissions: 0o644, id: None }, size)?;
        return Ok(());
    }
    if data_at.is_some_and(|index| parts[index] == "logs") {
        let Some(bytes) = read()? else { return Ok(()) };
        let text = String::from_utf8_lossy(&bytes).into_owned();
        let cleaned: String = text.split_inclusive('\n').map(without_user_info).collect();
        let size = cleaned.len() as u64;
        let source = Source::Bytes(cleaned.into_bytes());
        set.add(target, LocalFile { source, permissions: 0o644, id: None }, size)?;
        return Ok(());
    }
    add_entry(set, target, path, dir, name, entry)
}

/// Whether the machine's file owner can hold a file at `relative`: no name
/// over 255 bytes or with a control character, no path over 4000 bytes.
pub(super) fn holdable(relative: &str) -> bool {
    relative.len() <= MAX_PATH_BYTES
        && relative
            .split('/')
            .all(|name| name.len() <= MAX_NAME_BYTES && !name.chars().any(char::is_control))
}

/// The synced permissions for a file whose mode is `mode`: 0644, 0755, 0600
/// or 0700, by its executable bit and whether group and others could read it.
pub(super) fn permissions_of(mode: u32) -> u32 {
    match (mode & 0o111 != 0, mode & 0o077 == 0) {
        (true, true) => 0o700,
        (true, false) => 0o755,
        (false, true) => 0o600,
        (false, false) => 0o644,
    }
}

/// Adds every file below `dir` of a folder outside git (`top`), by the
/// module doc's rules. Each folder is opened by name in the folder that
/// listed it, never through a symlink ([`place::Dir::child`]), and listed
/// through that handle: a folder swapped for a symlink after its parent was
/// listed is never walked through, so nothing outside `top` is listed. A
/// folder `enter` refuses (by its path from `top`) is never entered and counts
/// once as skipped.
fn walk_plain(
    set: &mut LocalSet,
    rules: Rules,
    enter: &dyn Fn(&str) -> bool,
    top: &Path,
    dir: &Path,
) -> anyhow::Result<()> {
    let mut handle =
        place::Dir::open(top).with_context(|| format!("cannot list {}", top.display()))?;
    let below =
        dir.strip_prefix(top).with_context(|| format!("{} is not in the folder", dir.display()))?;
    for name in below.iter() {
        let Some(name) = name.to_str() else { return Ok(()) };
        match handle.child(name) {
            Ok(Some(child)) => handle = child,
            Ok(None) => return Ok(()),
            Err(error) if swapped(&error) => return Ok(()),
            Err(error) => {
                return Err(error).with_context(|| format!("cannot list {}", dir.display()));
            }
        }
    }
    walk_plain_in(set, rules, enter, top, dir, &handle)
}

/// Whether opening a folder failed because something else is at its name
/// now (a symlink, a file).
pub(super) fn swapped(error: &std::io::Error) -> bool {
    matches!(error.raw_os_error(), Some(libc::ELOOP | libc::ENOTDIR))
}

/// [`walk_plain`] in the folder `dir` that `handle` holds open.
fn walk_plain_in(
    set: &mut LocalSet,
    rules: Rules,
    enter: &dyn Fn(&str) -> bool,
    top: &Path,
    dir: &Path,
    handle: &place::Dir,
) -> anyhow::Result<()> {
    let names = handle.names().with_context(|| format!("cannot list {}", dir.display()))?;
    for name in names {
        let path = dir.join(&name);
        let Ok(relative) = path.strip_prefix(top) else { continue };
        let Some(relative) = relative.to_str() else {
            set.skips.note(&relative.to_string_lossy(), Why::NameNotUtf8);
            continue;
        };
        if relative == ".DS_Store" {
            continue;
        }
        let name = relative.rsplit('/').next().unwrap_or(relative);
        let entry =
            handle.entry(name).with_context(|| format!("cannot read {}", path.display()))?;
        match entry {
            place::Entry::Missing => {}
            place::Entry::Dir => {
                if let Some(why) =
                    skips::credential(relative, true).filter(|_| rules == Rules::Copy)
                {
                    set.skips.note(&format!("{relative}/"), why);
                } else if rules == Rules::Copy && skips::heavy(dir, name) {
                    set.skips.note(&format!("{relative}/"), Why::Heavy);
                } else if !enter(relative) {
                    set.skipped = set.skipped.saturating_add(1);
                } else {
                    match handle.child(name) {
                        Ok(Some(child)) => walk_plain_in(set, rules, enter, top, &path, &child)?,
                        Ok(None) => {}
                        // A symlink or file there since it was listed: as any entry.
                        Err(error) if swapped(&error) => {
                            let now = handle.entry(name)?;
                            if !matches!(now, place::Entry::Dir) {
                                entry_in(set, rules, relative, &path, handle, name, now)?;
                            }
                        }
                        Err(error) => {
                            return Err(error)
                                .with_context(|| format!("cannot list {}", path.display()));
                        }
                    }
                }
            }
            other => entry_in(set, rules, relative, &path, handle, name, other)?,
        }
    }
    Ok(())
}

/// Sections whose settings may go, with the keys kept in each (lower case).
const CONFIG_KEYS: &[(&str, &[&str])] = &[
    (
        "core",
        &[
            "repositoryformatversion",
            "filemode",
            "bare",
            "logallrefupdates",
            "ignorecase",
            "precomposeunicode",
            "symlinks",
            "autocrlf",
            "eol",
            "safecrlf",
            "quotepath",
            "abbrev",
        ],
    ),
    (
        "extensions",
        &["objectformat", "worktreeconfig", "refstorage", "preciousobjects", "partialclone"],
    ),
    (
        "remote",
        &[
            "url",
            "pushurl",
            "fetch",
            "push",
            "tagopt",
            "prune",
            "mirror",
            "promisor",
            "partialclonefilter",
        ],
    ),
    ("branch", &["remote", "merge", "rebase", "pushremote", "description"]),
    ("submodule", &["url", "path", "active", "update", "branch", "shallow", "ignore"]),
    ("pull", &["rebase", "ff"]),
    ("push", &["default", "autosetupremote"]),
    ("init", &["defaultbranch"]),
];

/// `config` with only allow-listed settings ([`CONFIG_KEYS`]), URL user info
/// cut, and no continued values: credentials, extra headers, include files,
/// commands and paths of this Mac never go.
pub(super) fn clean_config(config: &str) -> String {
    let mut out = String::new();
    let mut keys: Option<&[&str]> = None;
    let mut continued = false;
    for line in config.lines() {
        if std::mem::replace(&mut continued, line.trim_end().ends_with('\\')) {
            continue;
        }
        let mut rest = line.trim();
        if let Some(header) = rest.strip_prefix('[') {
            let Some(end) = header.find(']') else {
                keys = None;
                continue;
            };
            let section = &header[..end];
            let plain = section.split('"').next().unwrap_or_default();
            let name = plain.split([' ', '.']).next().unwrap_or_default().to_ascii_lowercase();
            // The old `[section.sub]` form is not allow-listed; a quoted
            // subsection name (`[remote "my.fork"]`) may hold dots.
            keys = CONFIG_KEYS
                .iter()
                .find(|(allowed, _)| *allowed == name)
                .map(|(_, keys)| *keys)
                .filter(|_| !plain.contains('.'));
            if keys.is_some() {
                out.push('[');
                out.push_str(section);
                out.push_str("]\n");
            }
            // `[core] key = value` on one line: the setting follows the header.
            rest = header[end + 1..].trim();
            if rest.is_empty() {
                continue;
            }
        }
        let Some(allowed) = keys else { continue };
        if rest.starts_with(['#', ';']) || rest.ends_with('\\') {
            continue;
        }
        let key = rest.split(['=', ' ', '\t']).next().unwrap_or_default().to_ascii_lowercase();
        if allowed.contains(&key.as_str()) {
            out.push('\t');
            out.push_str(&without_user_info(rest));
            out.push('\n');
        }
    }
    out
}

/// `text` with every `scheme://user[:password]@` cut to `scheme://`.
fn without_user_info(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut rest = text;
    while let Some(scheme_end) = rest.find("://") {
        out.push_str(&rest[..scheme_end + 3]);
        rest = &rest[scheme_end + 3..];
        let authority_end = rest.find(['/', ' ', '\t', '"', '\n']).unwrap_or(rest.len());
        if let Some(at) = rest[..authority_end].rfind('@') {
            rest = &rest[at + 1..];
        }
    }
    out.push_str(rest);
    out
}

#[cfg(test)]
#[path = "local_tests.rs"]
mod tests;
