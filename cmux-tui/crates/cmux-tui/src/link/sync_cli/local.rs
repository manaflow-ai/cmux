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

use std::collections::{BTreeMap, BTreeSet};
use std::os::unix::ffi::OsStrExt as _;
use std::path::{Path, PathBuf};
use std::process::Command;

use anyhow::{Context as _, bail};

use super::place;
use super::skips::{self, Skips, Why};

pub(super) use super::listed::{add_entry, entry_in, git_text, open_listed, walk_in};

/// Where one file to push comes from.
#[derive(Clone, Debug)]
pub(super) enum Source {
    File(PathBuf),
    /// Bytes made here (a cleaned git config or reflog).
    Bytes(Vec<u8>),
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

pub(super) fn collect(folder: &Path, rules: Rules) -> anyhow::Result<LocalSet> {
    let skips = Skips::new(folder);
    let mut set =
        LocalSet { files: BTreeMap::new(), links: BTreeMap::new(), skipped: 0, skips, git: false };
    let Some(git) = GitDirs::of(folder)? else {
        walk_plain(&mut set, rules, folder, folder)?;
        return Ok(set);
    };
    set.git = true;
    let top = place::Dir::open(folder)?;
    for (path, untracked) in working_files(folder, &mut set.skipped)? {
        // An untracked credential file never goes either (tracked ones were committed on purpose).
        if untracked
            && (path.rsplit('/').next().is_some_and(|name| name.starts_with(".env"))
                || skips::credential(&path, false).is_some())
        {
            set.skipped += 1;
            continue;
        }
        // Through the folders on its way, each opened by descriptor without following a symlink.
        match place::parent_of(&top, &path) {
            Ok(Some((dir, name))) => {
                let entry = dir.entry(&name)?;
                add_entry(&mut set, path.clone(), &folder.join(&path), &dir, &name, entry)?;
            }
            Ok(None) => {}
            Err(error) if swapped(&error) => {}
            Err(error) => return Err(error).with_context(|| format!("cannot read {path}")),
        }
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
        let Ok(top) = git(folder, &["rev-parse", "--show-toplevel"]) else { return Ok(None) };
        let top = std::fs::canonicalize(top.trim()).unwrap_or_else(|_| PathBuf::from(top.trim()));
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

/// Tracked and untracked-not-ignored paths, each with whether it is
/// untracked. A path that is not UTF-8 is skipped and counted.
fn working_files(folder: &Path, skipped: &mut u64) -> anyhow::Result<Vec<(String, bool)>> {
    let mut list = |extra: &[&str]| -> anyhow::Result<Vec<String>> {
        let mut args = vec!["ls-files", "-z"];
        args.extend_from_slice(extra);
        let output = git_bytes(folder, &args)?;
        let mut paths = Vec::new();
        for path in output.split(|byte| *byte == 0).filter(|path| !path.is_empty()) {
            match std::str::from_utf8(path) {
                Ok(path) => paths.push(path.to_string()),
                Err(_) => *skipped += 1,
            }
        }
        Ok(paths)
    };
    let mut paths: Vec<(String, bool)> =
        list(&["--cached"])?.into_iter().map(|path| (path, false)).collect();
    paths.extend(list(&["--others", "--exclude-standard"])?.into_iter().map(|path| (path, true)));
    paths.sort();
    paths.dedup_by(|later, earlier| later.0 == earlier.0);
    Ok(paths)
}

pub(super) fn git(folder: &Path, args: &[&str]) -> anyhow::Result<String> {
    String::from_utf8(git_bytes(folder, args)?).context("git printed text that is not UTF-8")
}

pub(super) fn git_bytes(folder: &Path, args: &[&str]) -> anyhow::Result<Vec<u8>> {
    let output =
        Command::new("git").arg("-C").arg(folder).args(args).output().context("cannot run git")?;
    if !output.status.success() {
        bail!("git {}: {}", args.join(" "), String::from_utf8_lossy(&output.stderr).trim());
    }
    Ok(output.stdout)
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
    let read = || git_text(dir, name, &entry, path, relative, set.skips.top());
    if data_at.is_none() && matches!(name, "config" | "config.worktree") {
        let text = String::from_utf8_lossy(&read()).into_owned();
        let source = Source::Bytes(clean_config(&text).into_bytes());
        set.files.insert(target, LocalFile { source, permissions: 0o644, id: None });
        return Ok(());
    }
    if data_at.is_some_and(|index| parts[index] == "logs") {
        let text = String::from_utf8_lossy(&read()).into_owned();
        let cleaned: String = text.split_inclusive('\n').map(without_user_info).collect();
        set.files.insert(
            target,
            LocalFile { source: Source::Bytes(cleaned.into_bytes()), permissions: 0o644, id: None },
        );
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
/// listed is never walked through, so nothing outside `top` is listed.
fn walk_plain(set: &mut LocalSet, rules: Rules, top: &Path, dir: &Path) -> anyhow::Result<()> {
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
    walk_plain_in(set, rules, top, dir, &handle)
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
                } else {
                    match handle.child(name) {
                        Ok(Some(child)) => walk_plain_in(set, rules, top, &path, &child)?,
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
mod tests {
    use std::path::Path;
    use std::process::Command;

    use super::{
        LocalFile, LocalSet, Rules, Skips, borrowed_object, borrowed_skipped, collect, entry_in,
        open_listed, place, unquote, walk_plain,
    };

    fn write(top: &Path, relative: &str) {
        let path = top.join(relative);
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, "x\n").unwrap();
    }

    /// A file is read only as the file listed: once a folder above it is swapped for a symlink that
    /// leads out of the folder copied, the same path names another file, and the read refuses it.
    #[test]
    fn a_read_refuses_a_file_found_through_a_folder_swapped_since_it_was_listed() {
        let root = tempfile::tempdir().unwrap();
        let (top, outside) = (root.path().join("top"), root.path().join("outside"));
        write(&top, "sub/notes.txt");
        write(&outside, "notes.txt");
        let path = top.join("sub/notes.txt");
        let listed = LocalFile::listed(&path, &std::fs::symlink_metadata(&path).unwrap());
        assert!(open_listed(&path, listed.id).is_ok());
        std::fs::rename(top.join("sub"), top.join("sub-old")).unwrap();
        std::os::unix::fs::symlink(&outside, top.join("sub")).unwrap();
        assert!(open_listed(&path, listed.id).is_err());
        assert!(open_listed(&path, None).is_ok(), "no listing: only the last name is checked");
    }

    /// A chat's copy of a plain folder never takes a credential folder's or
    /// file's contents at any depth (gh's `hosts.yml` OAuth tokens, Cargo's
    /// `credentials.toml`, cloud and cluster logins, `.netrc`-style files),
    /// by the same folder list the App refuses a selected folder by; the
    /// project's own files beside them go.
    #[test]
    fn a_plain_copy_leaves_credential_folders_and_files_here() {
        let top = tempfile::tempdir().unwrap();
        let top = std::fs::canonicalize(top.path()).unwrap();
        let secrets = [
            ".config/gh/hosts.yml",
            "home/.config/gh/hosts.yml",
            ".config/gcloud/credentials.db",
            ".config/hub",
            ".cargo/credentials.toml",
            ".cargo/credentials",
            ".aws/credentials",
            ".ssh/config",
            ".gnupg/pubring.kbx",
            ".docker/config.json",
            ".kube/config",
            ".azure/accessTokens.json",
            ".netrc",
            "deep/.npmrc",
            ".pypirc",
            ".git-credentials",
            ".gem/credentials",
            ".terraform.d/credentials.tfrc.json",
            ".secrets/token",
            "deep/.docker/daemon.json",
            ".docker/buildx/instances/x",
            "app/Library/Keychains/login.keychain-db",
            "deep/.config/gcloud/application_default_credentials.json",
            ".cargo/config.toml",
        ];
        for relative in secrets {
            write(&top, relative);
        }
        let kept = ["src/main.rs", ".config/app.toml", "gh/notes.md", "Library/notes.md"];
        for relative in kept {
            write(&top, relative);
        }
        let set = collect(&top, Rules::Copy).unwrap();
        for relative in secrets {
            assert!(!set.files.contains_key(relative), "{relative} went: {:?}", set.files.keys());
        }
        for relative in kept {
            assert!(set.files.contains_key(relative), "{relative} stayed: {:?}", set.files.keys());
        }
    }

    /// A folder swapped for a symlink after its parent was listed is never
    /// walked through: the walk opens each folder by name, relative to its
    /// parent, without following a symlink, so it lists nothing outside the
    /// selected folder (the race between the listing and the descent).
    #[test]
    fn a_folder_swapped_for_a_symlink_is_never_walked_through() {
        let root = tempfile::tempdir().unwrap();
        let root = std::fs::canonicalize(root.path()).unwrap();
        let (top, outside) = (root.join("top"), root.join("outside"));
        write(&outside, "secret.txt");
        write(&top, "a/kept.txt");
        std::os::unix::fs::symlink(&outside, top.join("swapped")).unwrap();
        std::os::unix::fs::symlink(&outside, top.join("a/swapped")).unwrap();
        for dir in [top.join("swapped"), top.join("a/swapped")] {
            let mut set = LocalSet {
                files: Default::default(),
                links: Default::default(),
                skipped: 0,
                skips: Skips::new(&top),
                git: false,
            };
            // As the walk descends into a name it listed as a folder.
            let _ = walk_plain(&mut set, Rules::Copy, &top, &dir);
            assert!(
                set.files.keys().all(|relative| !relative.ends_with("secret.txt")),
                "walked outside through {}: {:?}",
                dir.display(),
                set.files.keys()
            );
        }
    }

    /// An entry of a folder the walk holds open is read through that folder's descriptor, never its
    /// path: with the folder swapped for a symlink to elsewhere after it was opened, its symlink
    /// entry never becomes the regular file found at the same name outside.
    #[test]
    fn an_entry_of_an_open_folder_swapped_away_is_read_through_its_descriptor() {
        let root = tempfile::tempdir().unwrap();
        let root = std::fs::canonicalize(root.path()).unwrap();
        let (top, outside) = (root.join("top"), root.join("outside"));
        write(&top, "a/kept.txt");
        write(&outside, "link");
        std::os::unix::fs::symlink("kept.txt", top.join("a/link")).unwrap();
        let handle = place::Dir::open(&top.join("a")).unwrap();
        std::fs::rename(top.join("a"), top.join("a-old")).unwrap();
        std::os::unix::fs::symlink(&outside, top.join("a")).unwrap();
        let mut set = LocalSet {
            files: Default::default(),
            links: Default::default(),
            skipped: 0,
            skips: Skips::new(&top),
            git: false,
        };
        let path = top.join("a/link");
        entry_in(&mut set, Rules::Copy, "a/link", &path, &handle, "link", place::Entry::Link)
            .unwrap();
        assert!(set.files.is_empty(), "took a file from outside: {:?}", set.files.keys());
    }

    #[test]
    fn only_git_object_files_of_a_borrowed_store_go() {
        let loose = format!("ab/{}", "c".repeat(38));
        let loose_sha256 = format!("ab/{}", "c".repeat(62));
        for goes in [
            loose.as_str(),
            loose_sha256.as_str(),
            "pack/pack-0123abcd.pack",
            "pack/pack-0123abcd.idx",
            "pack/pack-0123abcd.rev",
            "pack/pack-0123abcd.promisor",
            "pack/pack-0123abcd.bitmap",
            "pack/pack-0123abcd.mtimes",
            "pack/pack-0123abcd.keep",
            "info/commit-graph",
            "info/commit-graphs/commit-graph-chain",
            "info/commit-graphs/graph-0123abcd.graph",
        ] {
            assert!(borrowed_object(goes), "{goes}");
        }
        for stays in [
            ".env",
            "ab/.env",
            "ab/cdef",
            "AB/CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC",
            "zz/cccccccccccccccccccccccccccccccccccccc",
            "pack/.env",
            "pack/pack-0123abcd.pack.lock",
            "pack/pack-.pack",
            "pack/notes.txt",
            "info/exclude",
            "info/commit-graphs/secret.txt",
            "deep/er/file",
        ] {
            assert!(!borrowed_object(stays), "{stays}");
        }
    }

    fn git(dir: &Path, args: &[&str]) {
        let status = Command::new("git")
            .arg("-C")
            .arg(dir)
            .args(["-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"])
            .args(args)
            .status()
            .unwrap();
        assert!(status.success(), "git {args:?}");
    }

    /// A symlinked git config (`config -> config.actual`) goes as the file it
    /// names, read through the git folder's descriptor, never as an empty one.
    #[test]
    fn a_symlinked_git_config_goes_as_the_file_it_names() {
        let root = tempfile::tempdir().unwrap();
        let repo = std::fs::canonicalize(root.path()).unwrap().join("repo");
        std::fs::create_dir(&repo).unwrap();
        git(&repo, &["init", "-q"]);
        git(&repo, &["config", "remote.origin.url", "https://example.invalid/r.git"]);
        std::fs::write(repo.join("a.txt"), "a\n").unwrap();
        std::fs::rename(repo.join(".git/config"), repo.join(".git/config.actual")).unwrap();
        std::os::unix::fs::symlink("config.actual", repo.join(".git/config")).unwrap();
        let set = collect(&repo, Rules::Copy).unwrap();
        let Some(super::Source::Bytes(bytes)) = set.files.get(".git/config").map(|f| &f.source)
        else {
            panic!("no config: {:?}", set.files.keys());
        };
        let text = String::from_utf8_lossy(bytes);
        assert!(
            text.contains("repositoryformatversion") && text.contains("example.invalid"),
            "{text}"
        );
    }

    /// A stray file in a borrowed object folder (a `.env`, a note) never
    /// goes; its loose objects and packs do.
    #[test]
    fn a_stray_file_in_a_borrowed_store_stays_here() {
        let root = tempfile::tempdir().unwrap();
        let root = std::fs::canonicalize(root.path()).unwrap();
        let base = root.join("base");
        std::fs::create_dir(&base).unwrap();
        git(&base, &["init", "-q"]);
        std::fs::write(base.join("a.txt"), "a\n").unwrap();
        git(&base, &["add", "a.txt"]);
        git(&base, &["commit", "-q", "-m", "packed"]);
        git(&base, &["repack", "-q", "-a", "-d"]);
        std::fs::write(base.join("b.txt"), "b\n").unwrap();
        git(&base, &["add", "b.txt"]);
        git(&base, &["commit", "-q", "-m", "loose"]);
        let objects = base.join(".git/objects");
        std::fs::write(objects.join(".env"), "TOKEN=x\n").unwrap();
        std::fs::write(objects.join("pack/notes.txt"), "x\n").unwrap();
        std::fs::create_dir(objects.join("stray")).unwrap();
        std::fs::write(objects.join("stray/id_rsa"), "x\n").unwrap();
        git(&root, &["clone", "-q", "--shared", "base", "copy"]);
        let copy = root.join("copy");

        let set = collect(&copy, Rules::Copy).unwrap();
        let borrowed: Vec<&str> =
            set.files.keys().filter_map(|path| path.strip_prefix(".git/objects/")).collect();
        assert!(
            borrowed.iter().any(|path| path.starts_with("pack/pack-") && path.ends_with(".pack")),
            "no pack went: {borrowed:?}"
        );
        assert!(
            borrowed.iter().any(|path| path.len() == 41 && path.as_bytes()[2] == b'/'),
            "no loose object went: {borrowed:?}"
        );
        for stray in [".env", "pack/notes.txt", "stray/id_rsa", "info/alternates"] {
            assert!(!borrowed.contains(&stray), "{stray} went: {borrowed:?}");
        }
        assert!(set.skipped >= 3, "the stray files were not counted: {}", set.skipped);
    }

    #[test]
    fn an_alternates_line_is_a_path_plain_or_c_quoted() {
        assert_eq!(unquote(b"/a/b/objects"), b"/a/b/objects");
        assert_eq!(unquote(br#""/a b/\"q\"/\\/x\tz/\303\251""#), b"/a b/\"q\"/\\/x\tz/\xc3\xa9");
        assert_eq!(unquote(b"\"unterminated"), b"\"unterminated");
    }

    #[test]
    fn a_borrowed_store_keeps_its_own_alternates_and_indexes() {
        for kept_here in [
            "info/alternates",
            "info/commit-graphs/commit-graph-chain",
            "pack/multi-pack-index",
            "pack/tmp_pack_x",
            "pack/pack-1.idx.lock",
        ] {
            assert!(borrowed_skipped(kept_here), "{kept_here}");
        }
        for goes in ["pack/pack-1.pack", "pack/pack-1.idx", "pack/pack-1.promisor", "ab/cdef"] {
            assert!(!borrowed_skipped(goes), "{goes}");
        }
    }
}
