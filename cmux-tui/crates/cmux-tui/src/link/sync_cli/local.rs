//! The local side of `cmux link sync push`: which files of a working copy
//! go to the machine, and the git state that goes with them.
//!
//! In a git working copy: the files `git ls-files --cached --others
//! --exclude-standard` names (tracked, and untracked ones that are not
//! ignored, minus untracked `.env*` files, which are shared only on
//! purpose), plus the repository itself as `.git/`, so the branch, HEAD,
//! index, stash and uncommitted changes arrive exactly. A linked worktree
//! arrives as a plain repository: the common folder, then the worktree's
//! own HEAD, index and logs over it. Hooks never go (they would run on the
//! machine), nor other worktrees' folders, lock files or the fsmonitor
//! socket. `.git/config` is rewritten without credentials: URL user info,
//! `credential` sections, `extraheader` lines and settings that point at
//! paths of this Mac. Outside git, every regular file of the folder goes.
//! Symlinks and special files are skipped and counted.

use std::collections::BTreeMap;
use std::os::unix::fs::PermissionsExt as _;
use std::path::{Path, PathBuf};
use std::process::Command;

use anyhow::{Context as _, bail};

/// Where one file to push comes from.
#[derive(Clone, Debug)]
pub(super) enum Source {
    File(PathBuf),
    /// Bytes made here (the rewritten git config).
    Bytes(Vec<u8>),
}

/// One file to push, by its path relative to the folder.
#[derive(Clone, Debug)]
pub(super) struct LocalFile {
    pub source: Source,
    pub executable: bool,
}

/// The files to push and how many were skipped.
pub(super) struct LocalSet {
    pub files: BTreeMap<String, LocalFile>,
    pub skipped: u64,
    pub git: bool,
}

/// Names under `.git/` that never go: hooks run code, other worktrees'
/// folders belong to checkouts on this Mac, and the rest is transient.
const GIT_SKIPPED_TOP: &[&str] = &[
    "hooks",
    "worktrees",
    "commondir",
    "gitdir",
    "fsmonitor--daemon",
    "fsmonitor--daemon.ipc",
    "gc.pid",
    "gc.log",
];

pub(super) fn collect(folder: &Path) -> anyhow::Result<LocalSet> {
    let mut set = LocalSet { files: BTreeMap::new(), skipped: 0, git: false };
    let Some(git) = GitDirs::of(folder)? else {
        walk(folder, folder, "", &mut set, &|_: &str| true)?;
        return Ok(set);
    };
    set.git = true;
    for (path, untracked) in working_files(folder)? {
        if untracked && path.rsplit('/').next().is_some_and(|name| name.starts_with(".env")) {
            set.skipped += 1;
            continue;
        }
        add(&mut set, &path, &folder.join(&path))?;
    }
    let skip_git = |relative: &str| {
        let top = relative.split('/').next().unwrap_or_default();
        !GIT_SKIPPED_TOP.contains(&top) && !relative.ends_with(".lock") && relative != "config"
    };
    walk(&git.common, &git.common, ".git", &mut set, &skip_git)?;
    if git.own != git.common {
        walk(&git.own, &git.own, ".git", &mut set, &skip_git)?;
    }
    let config = std::fs::read_to_string(git.common.join("config")).unwrap_or_default();
    set.files.insert(
        ".git/config".into(),
        LocalFile { source: Source::Bytes(clean_config(&config).into_bytes()), executable: false },
    );
    Ok(set)
}

/// A working copy's own git folder and the common one (the same folder
/// except in a linked worktree).
struct GitDirs {
    own: PathBuf,
    common: PathBuf,
}

impl GitDirs {
    fn of(folder: &Path) -> anyhow::Result<Option<Self>> {
        if !folder.join(".git").exists() {
            return Ok(None);
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

/// Tracked and untracked-not-ignored paths, each with whether it is untracked.
fn working_files(folder: &Path) -> anyhow::Result<Vec<(String, bool)>> {
    let list = |extra: &[&str]| -> anyhow::Result<Vec<String>> {
        let mut args = vec!["ls-files", "-z"];
        args.extend_from_slice(extra);
        Ok(git(folder, &args)?
            .split('\0')
            .filter(|path| !path.is_empty())
            .map(str::to_string)
            .collect())
    };
    let mut paths: Vec<(String, bool)> =
        list(&["--cached"])?.into_iter().map(|path| (path, false)).collect();
    paths.extend(list(&["--others", "--exclude-standard"])?.into_iter().map(|path| (path, true)));
    paths.sort();
    paths.dedup_by(|later, earlier| later.0 == earlier.0);
    Ok(paths)
}

fn git(folder: &Path, args: &[&str]) -> anyhow::Result<String> {
    let output =
        Command::new("git").arg("-C").arg(folder).args(args).output().context("cannot run git")?;
    if !output.status.success() {
        bail!("git {}: {}", args.join(" "), String::from_utf8_lossy(&output.stderr).trim());
    }
    Ok(String::from_utf8(output.stdout).context("git printed a path that is not UTF-8")?)
}

/// Adds the regular file at `path` as `relative`; anything else is counted
/// as skipped (a symlink, a socket, a file deleted from the working tree).
fn add(set: &mut LocalSet, relative: &str, path: &Path) -> anyhow::Result<()> {
    match std::fs::symlink_metadata(path) {
        Ok(meta) if meta.file_type().is_file() => {
            let executable = meta.permissions().mode() & 0o111 != 0;
            set.files.insert(
                relative.to_string(),
                LocalFile { source: Source::File(path.to_path_buf()), executable },
            );
        }
        Ok(_) => set.skipped += 1,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(error) => return Err(error).with_context(|| format!("cannot read {}", path.display())),
    }
    Ok(())
}

/// Adds every regular file below `dir` (relative to `top`, under `prefix`)
/// whose relative path `keep` admits.
fn walk(
    top: &Path,
    dir: &Path,
    prefix: &str,
    set: &mut LocalSet,
    keep: &dyn Fn(&str) -> bool,
) -> anyhow::Result<()> {
    let entries =
        std::fs::read_dir(dir).with_context(|| format!("cannot list {}", dir.display()))?;
    for entry in entries {
        let entry = entry?;
        let path = entry.path();
        let relative = path.strip_prefix(top).unwrap_or(&path).to_string_lossy().into_owned();
        if !keep(&relative) || (prefix.is_empty() && relative == ".DS_Store") {
            continue;
        }
        let target =
            if prefix.is_empty() { relative.clone() } else { format!("{prefix}/{relative}") };
        if entry.file_type()?.is_dir() {
            walk(top, &path, prefix, set, keep)?;
        } else {
            add(set, &target, &path)?;
        }
    }
    Ok(())
}

/// `config` without credentials or settings that name paths of this Mac.
pub(super) fn clean_config(config: &str) -> String {
    let mut out = String::new();
    let mut skipping = false;
    for line in config.lines() {
        let trimmed = line.trim_start();
        if trimmed.starts_with('[') {
            skipping = trimmed.to_ascii_lowercase().starts_with("[credential");
        }
        if skipping {
            continue;
        }
        let key = trimmed.split(['=', ' ', '\t']).next().unwrap_or_default().to_ascii_lowercase();
        if matches!(
            key.as_str(),
            "extraheader" | "worktree" | "hookspath" | "fsmonitor" | "sshcommand" | "askpass"
        ) {
            continue;
        }
        out.push_str(&without_user_info(line));
        out.push('\n');
    }
    out
}

/// `line` with `scheme://user[:password]@` cut to `scheme://`.
fn without_user_info(line: &str) -> String {
    let Some(scheme_end) = line.find("://") else { return line.to_string() };
    let rest = &line[scheme_end + 3..];
    let authority_end = rest.find(['/', '?', '#', ' ', '"']).unwrap_or(rest.len());
    match rest[..authority_end].rfind('@') {
        Some(at) => format!("{}{}", &line[..scheme_end + 3], &rest[at + 1..]),
        None => line.to_string(),
    }
}
