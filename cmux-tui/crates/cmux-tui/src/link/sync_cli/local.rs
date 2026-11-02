//! The local side of `cmux link sync push`: which files of a working copy
//! go to the machine, and the git state that goes with them.
//!
//! In a git working copy (its top folder; a subfolder is refused): the
//! files `git ls-files --cached --others --exclude-standard` names (tracked,
//! and untracked ones that are not ignored, minus untracked `.env*` files,
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
//! objects from another (`objects/info/alternates`) is refused.
//!
//! Outside git, every regular file of the folder goes, except for a chat's
//! copy the dependency and build folders its project rebuilds on the
//! machine ([`skips::heavy`]) and secrets (`.env*`, key files: [`skips::secret`]).
//! Symlinks, special files and names the machine cannot hold (control
//! characters, over 255 bytes, not UTF-8) are skipped too. Every skip is
//! named with why ([`Skips`]), except the git path's untracked `.env*` and
//! non-UTF-8 paths, which are counted.

use std::collections::BTreeMap;
use std::os::unix::fs::PermissionsExt as _;
use std::path::{Path, PathBuf};
use std::process::Command;

use anyhow::{Context as _, bail};

use super::skips::{self, Skips, Why};

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
}

/// The files to push and what was skipped.
pub(super) struct LocalSet {
    pub files: BTreeMap<String, LocalFile>,
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
    let mut set = LocalSet { files: BTreeMap::new(), skipped: 0, skips, git: false };
    let Some(git) = GitDirs::of(folder)? else {
        walk_plain(&mut set, rules, folder, folder)?;
        return Ok(set);
    };
    set.git = true;
    if git.common.join("objects/info/alternates").exists() {
        bail!(
            "{} borrows objects from another repository (objects/info/alternates); clone it without --shared or --reference first",
            folder.display()
        );
    }
    for (path, untracked) in working_files(folder, &mut set.skipped)? {
        if untracked && path.rsplit('/').next().is_some_and(|name| name.starts_with(".env")) {
            set.skipped += 1;
            continue;
        }
        add(&mut set, path.clone(), &folder.join(&path))?;
    }
    let linked = git.own != git.common;
    walk(&git.common, &git.common, &mut |relative, path| {
        if linked && is_per_worktree(relative) {
            return Ok(());
        }
        add_git(&mut set, relative, path)
    })?;
    if linked {
        walk(&git.own, &git.own, &mut |relative, path| {
            if relative == "commondir" || relative == "gitdir" {
                return Ok(());
            }
            add_git(&mut set, relative, path)
        })?;
    }
    Ok(set)
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
fn add_git(set: &mut LocalSet, relative: &str, path: &Path) -> anyhow::Result<()> {
    let parts: Vec<&str> = relative.split('/').collect();
    if !GIT_TOP.contains(&parts[0]) || relative.ends_with(".lock") {
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
    let name = parts.last().copied().unwrap_or_default();
    if data_at.is_none() && matches!(name, "config" | "config.worktree") {
        let text = std::fs::read_to_string(path).unwrap_or_default();
        let source = Source::Bytes(clean_config(&text).into_bytes());
        set.files.insert(target, LocalFile { source, permissions: 0o644 });
        return Ok(());
    }
    if data_at.is_some_and(|index| parts[index] == "logs") {
        let text = String::from_utf8_lossy(&std::fs::read(path).unwrap_or_default()).into_owned();
        let cleaned: String = text.split_inclusive('\n').map(without_user_info).collect();
        set.files.insert(
            target,
            LocalFile { source: Source::Bytes(cleaned.into_bytes()), permissions: 0o644 },
        );
        return Ok(());
    }
    add(set, target, path)
}

/// Adds the regular file at `path` as `relative`; anything else is named
/// as skipped (a symlink, a socket, a name the machine cannot hold). A file
/// deleted from the working tree is left out.
fn add(set: &mut LocalSet, relative: String, path: &Path) -> anyhow::Result<()> {
    match std::fs::symlink_metadata(path) {
        Ok(meta) if meta.file_type().is_file() && holdable(&relative) => {
            let permissions = permissions_of(meta.permissions().mode());
            set.files.insert(
                relative,
                LocalFile { source: Source::File(path.to_path_buf()), permissions },
            );
        }
        Ok(meta) => set.skips.note_entry(&relative, path, &meta),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(error) => return Err(error).with_context(|| format!("cannot read {}", path.display())),
    }
    Ok(())
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
/// module doc's rules. Folders are entered without following symlinks.
fn walk_plain(set: &mut LocalSet, rules: Rules, top: &Path, dir: &Path) -> anyhow::Result<()> {
    let entries =
        std::fs::read_dir(dir).with_context(|| format!("cannot list {}", dir.display()))?;
    for entry in entries {
        let entry = entry?;
        let path = entry.path();
        let Ok(relative) = path.strip_prefix(top) else { continue };
        let Some(relative) = relative.to_str() else {
            set.skips.note(&relative.to_string_lossy(), Why::NameNotUtf8);
            continue;
        };
        if relative == ".DS_Store" {
            continue;
        }
        let name = relative.rsplit('/').next().unwrap_or(relative);
        if entry.file_type()?.is_dir() {
            if rules == Rules::Copy && skips::heavy(dir, name) {
                set.skips.note(&format!("{relative}/"), Why::Heavy);
            } else {
                walk_plain(set, rules, top, &path)?;
            }
        } else if let Some(why) = skips::secret(name).filter(|_| rules == Rules::Copy) {
            set.skips.note(relative, why);
        } else {
            add(set, relative.to_string(), &path)?;
        }
    }
    Ok(())
}

/// Calls `visit(relative, path)` for every non-folder entry below `dir`
/// (`relative` to `top`). Folders are entered without following symlinks.
fn walk(
    top: &Path,
    dir: &Path,
    visit: &mut dyn FnMut(&str, &Path) -> anyhow::Result<()>,
) -> anyhow::Result<()> {
    let entries =
        std::fs::read_dir(dir).with_context(|| format!("cannot list {}", dir.display()))?;
    for entry in entries {
        let entry = entry?;
        let path = entry.path();
        let Some(relative) = path.strip_prefix(top).ok().and_then(Path::to_str).map(str::to_string)
        else {
            continue;
        };
        if relative == ".DS_Store" {
            continue;
        }
        if entry.file_type()?.is_dir() {
            walk(top, &path, visit)?;
        } else {
            visit(&relative, &path)?;
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
