//! A folder is opened as a part of its own work tree only.
//!
//! For the folder of a request git gives a top folder and a git folder.
//! Data in a git folder and in a `.git` file decides both, so they can be
//! folders that the request's folder is no part of. [`check`] passes a
//! folder only when:
//!
//! - the request's real folder is the top folder or below it;
//! - the top folder's `.git` entry is the git folder (a folder); or it
//!   names the git folder (a file), and then the git folder names that file
//!   back, by its record of a linked work tree or by its `core.worktree`
//!   setting, or it names no work tree and is not in a work tree; or the
//!   entry is a link to the git folder, and then the git folder is of no
//!   other work tree ([`link_names`]);
//! - the git folder uses no common folder, or the common folder of the
//!   repository that has it as the git folder of a linked work tree.
//!
//! The check is one look, at the open. It does not see a change of the
//! `.git` entry after it, and of the git folder it reads these records
//! only.
//!
//! git prints each folder on a line of its own, and a folder's name can
//! have a line break: [`two_folders`] reads such an answer.

use std::fs;
use std::io::Read;
use std::path::{Path, PathBuf};

use crate::repository::path_from_bytes;
use crate::run::GitFailure;

/// How the problem text of each refusal of the open starts.
const REFUSED: &str = "this folder is not opened: ";

/// How a problem text ends when a person must decide what is right. A
/// problem text names no command to run: the open does not know for which
/// folder a command changes the git folder.
const ASK: &str = "; ask the person who owns this folder what to do";

/// The most bytes of a `.git` file or of a git folder's record that are
/// read: git's own limit for a `.git` file.
const MAX_RECORD_BYTES: u64 = 1024 * 1024;

/// The most line breaks of an answer that [`two_folders`] reads. An answer
/// for two folders with plain names has two.
const MAX_LINE_BREAKS: usize = 64;

/// The two folders that git printed, one on a line each. A folder's name
/// can have a line break, so each line break is tried as the end of the
/// first folder, and a cut counts only when each part is the absolute path
/// of a folder that is there. `None` unless exactly one cut counts: with
/// two, the answer names more than one pair of folders, and no pair is
/// taken.
pub fn two_folders(stdout: &[u8]) -> Option<(PathBuf, PathBuf)> {
    let mut folders = folders(stdout, 2)?.into_iter();
    Some((folders.next()?, folders.next()?))
}

/// Whether the whole of git's answer is one folder that is there, after an
/// empty line when the answer starts with one.
pub(crate) fn is_one_folder(stdout: &[u8]) -> bool {
    let line = stdout.strip_prefix(b"\n").unwrap_or(stdout);
    line.strip_suffix(b"\n").is_some_and(is_folder)
}

/// The `count` folders that git printed, one on a line each, when exactly
/// one way to cut the answer gives `count` folders that are there.
fn folders(stdout: &[u8], count: usize) -> Option<Vec<PathBuf>> {
    let lines = stdout.strip_suffix(b"\n")?;
    if lines.iter().filter(|byte| **byte == b'\n').count() > MAX_LINE_BREAKS {
        return None;
    }
    let mut ways = Vec::new();
    cut(lines, count, &mut Vec::new(), &mut ways);
    let way = ways.pop()?;
    ways.is_empty().then_some(way)
}

/// Adds to `ways` each way to cut `lines` into `count` folders that are
/// there, after the folders of `before`. It stops after the second way.
fn cut(lines: &[u8], count: usize, before: &mut Vec<PathBuf>, ways: &mut Vec<Vec<PathBuf>>) {
    if count <= 1 {
        if is_folder(lines) {
            let mut way = before.clone();
            way.push(path_from_bytes(lines));
            ways.push(way);
        }
        return;
    }
    for (at, byte) in lines.iter().enumerate() {
        if *byte != b'\n' {
            continue;
        }
        if ways.len() > 1 {
            return;
        }
        let Some((first, rest)) = lines.split_at_checked(at) else { continue };
        let Some((_, rest)) = rest.split_first() else { continue };
        if !is_folder(first) {
            continue;
        }
        before.push(path_from_bytes(first));
        cut(rest, count.saturating_sub(1), before, ways);
        before.pop();
    }
}

/// Whether `bytes` are the absolute path of a folder that is there.
fn is_folder(bytes: &[u8]) -> bool {
    // A part that cannot be an absolute path is no path at all: no look.
    if cfg!(unix) && bytes.first() != Some(&b'/') {
        return false;
    }
    let path = path_from_bytes(bytes);
    path.is_absolute() && path.is_dir()
}

/// Refuses `directory`, the folder of a request, unless it is a part of the
/// work tree `top`, and `top` and `git_dir` name each other. `top` and
/// `git_dir` are git's answers for `directory`. `core_worktree` gives the
/// `core.worktree` setting that git reads there, when one is set.
pub(crate) fn check(
    directory: &Path,
    top: &Path,
    git_dir: &Path,
    core_worktree: impl FnOnce() -> Result<Option<Vec<u8>>, GitFailure>,
) -> Result<(), GitFailure> {
    if !is_below(directory, top) {
        return Err(GitFailure::Exit(format!(
            "{REFUSED}it is not in the work tree that git gives for it ({})",
            top.display()
        )));
    }
    let why = match names(top, git_dir, core_worktree)? {
        Names::EachOther => return Ok(()),
        Names::OtherCommonFolder => {
            return Err(GitFailure::Exit(format!(
                "{REFUSED}the git folder that git gives for the work tree {} uses the common \
                 folder of a repository, and it is not the git folder of a linked work tree of \
                 that repository",
                top.display()
            )));
        }
        Names::LinkToAnother => {
            return Err(GitFailure::Exit(format!(
                "{REFUSED}the `.git` entry of the work tree {} is a link to a git folder that \
                 is in a work tree or names a work tree",
                top.display()
            )));
        }
        Names::Not => String::new(),
        Names::InAnotherWorkTree => {
            format!(": the git folder is the `.git` folder of another work tree{ASK}")
        }
        Names::OtherPlace => {
            format!(": the git folder has the record of a work tree at another place{ASK}")
        }
    };
    Err(GitFailure::Exit(format!(
        "{REFUSED}the work tree {} and the git folder that git gives for it do not name each \
         other{why}",
        top.display()
    )))
}

/// Whether a work tree and the git folder that git gives for it name each
/// other.
enum Names {
    EachOther,
    Not,
    /// The `.git` file names the git folder, the git folder names no work
    /// tree (it has no record of one and no `core.worktree` setting), and
    /// it is in a work tree.
    InAnotherWorkTree,
    /// The `.git` file names the git folder, and the git folder has the
    /// record of a work tree at another place.
    OtherPlace,
    /// The `.git` entry is a link to the git folder, and the git folder is
    /// in a work tree or names one.
    LinkToAnother,
    /// The two name each other, and the git folder uses the common folder
    /// of a repository that does not have it as a linked work tree's.
    OtherCommonFolder,
}

/// Whether the real folder of `directory` is the folder `top` or below it.
fn is_below(directory: &Path, top: &Path) -> bool {
    let (Ok(directory), Ok(real_top)) = (fs::canonicalize(directory), fs::canonicalize(top)) else {
        return false;
    };
    // A real path has no link. Its text can still differ from the text of
    // the same folder's other real path (the case of a letter, on a file
    // system that ignores it): then each folder above is looked at.
    directory.starts_with(real_top) || directory.ancestors().any(|above| is_same(above, top))
}

/// Whether the work tree `top` and `git_dir` name each other, and `git_dir`
/// uses a common folder that is its own.
fn names(
    top: &Path,
    git_dir: &Path,
    core_worktree: impl FnOnce() -> Result<Option<Vec<u8>>, GitFailure>,
) -> Result<Names, GitFailure> {
    Ok(match entry_names(top, git_dir, core_worktree)? {
        Names::EachOther if !has_own_common_folder(git_dir) => Names::OtherCommonFolder,
        other => other,
    })
}

/// Whether `git_dir` uses no common folder, or the common folder of the
/// repository that has it as the git folder of a linked work tree
/// (`<common>/worktrees/<name>`). git reads the common folder from the file
/// `commondir` of a git folder, from that git folder when it is relative.
fn has_own_common_folder(git_dir: &Path) -> bool {
    match record(&git_dir.join("commondir")) {
        Record::Missing => true,
        Record::Text(common) => {
            let common = git_dir.join(path_from_bytes(without_line_end(&common)));
            git_dir
                .file_name()
                .is_some_and(|name| is_same(&common.join("worktrees").join(name), git_dir))
        }
        Record::Unreadable => false,
    }
}

/// Whether the `.git` entry of the work tree `top` leads to `git_dir`, and
/// `git_dir` names the work tree back.
fn entry_names(
    top: &Path,
    git_dir: &Path,
    core_worktree: impl FnOnce() -> Result<Option<Vec<u8>>, GitFailure>,
) -> Result<Names, GitFailure> {
    let each_other = |named: bool| if named { Names::EachOther } else { Names::Not };
    let entry = top.join(".git");
    let Ok(kind) = fs::symlink_metadata(&entry).map(|metadata| metadata.file_type()) else {
        return Ok(Names::Not);
    };
    if kind.is_symlink() {
        return link_names(&entry, git_dir, core_worktree);
    }
    if kind.is_dir() {
        // The git folder is in the work tree.
        return Ok(each_other(is_same(&entry, git_dir)));
    }
    if !kind.is_file() {
        return Ok(Names::Not);
    }
    if !git_file_target(&entry, top).is_some_and(|named| is_same(&named, git_dir)) {
        return Ok(Names::Not);
    }
    match record(&git_dir.join("gitdir")) {
        // A linked work tree: its git folder records the place of the
        // work tree's `.git` file.
        Record::Text(place) => {
            let place = git_dir.join(path_from_bytes(without_line_end(&place)));
            let in_top = place.parent().is_some_and(|folder| is_same(folder, top));
            let named = in_top && place.file_name().is_some_and(|name| name == ".git");
            Ok(if named { Names::EachOther } else { Names::OtherPlace })
        }
        // A git folder with no such record names its work tree by a
        // setting, as a submodule's does. git reads a relative value from
        // the git folder.
        //
        // With no setting it names no work tree, as the git folder that git
        // makes apart from a work tree. The file then gets the rule of a
        // link ([`link_names`]), with its limit: a git folder of no work
        // tree is opened.
        Record::Missing => Ok(match core_worktree()? {
            Some(setting) => each_other(
                !setting.is_empty() && is_same(&git_dir.join(path_from_bytes(&setting)), top),
            ),
            None => match is_in_a_work_tree(git_dir) {
                Some(false) => Names::EachOther,
                Some(true) => Names::InAnotherWorkTree,
                None => Names::Not,
            },
        }),
        Record::Unreadable => Ok(Names::Not),
    }
}

/// Whether the `.git` entry `link` of a work tree, a link, is opened. It
/// leads to `git_dir`, and `git_dir` is of no other work tree: its real name
/// is not `.git` (the git folder in a work tree), it has no record of a
/// linked work tree, and it has no `core.worktree` setting. A tool for many
/// repositories makes such a link to a git folder that it keeps at another
/// place.
///
/// A limit: a git folder that names no work tree does not say which folder
/// it is for, so each folder whose `.git` entry is a link to it is opened.
fn link_names(
    link: &Path,
    git_dir: &Path,
    core_worktree: impl FnOnce() -> Result<Option<Vec<u8>>, GitFailure>,
) -> Result<Names, GitFailure> {
    if !is_same(link, git_dir) {
        return Ok(Names::Not);
    }
    let Some(in_a_work_tree) = is_in_a_work_tree(git_dir) else { return Ok(Names::Not) };
    let has_record = !matches!(record(&git_dir.join("gitdir")), Record::Missing);
    if in_a_work_tree || has_record || core_worktree()?.is_some() {
        return Ok(Names::LinkToAnother);
    }
    Ok(Names::EachOther)
}

/// Whether `git_dir` is the git folder in a work tree: its real name is
/// `.git`. `None` when its real path is not read.
fn is_in_a_work_tree(git_dir: &Path) -> Option<bool> {
    let real = fs::canonicalize(git_dir).ok()?;
    Some(real.file_name().is_none_or(|name| name.eq_ignore_ascii_case(".git")))
}

/// Whether the two paths lead to one folder that is there.
fn is_same(left: &Path, right: &Path) -> bool {
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        let folder = |path: &Path| {
            let metadata = fs::metadata(path).ok()?;
            metadata.is_dir().then(|| (metadata.dev(), metadata.ino()))
        };
        folder(left).is_some_and(|left| folder(right) == Some(left))
    }
    #[cfg(not(unix))]
    {
        let folder = |path: &Path| fs::canonicalize(path).ok().filter(|real| real.is_dir());
        folder(left).is_some_and(|left| folder(right) == Some(left))
    }
}

/// The git folder that the `.git` file `file` of the work tree `top` names,
/// read as git reads it: `gitdir: `, then a path to the line's end, from the
/// file's folder when it is relative.
fn git_file_target(file: &Path, top: &Path) -> Option<PathBuf> {
    let Record::Text(text) = record(file) else { return None };
    let path = without_line_end(text.strip_prefix(b"gitdir: ")?);
    (!path.is_empty()).then(|| top.join(path_from_bytes(path)))
}

/// `text` with each line break and carriage return taken off its end, as
/// git takes them off.
fn without_line_end(mut text: &[u8]) -> &[u8] {
    while let Some(shorter) = text.strip_suffix(b"\n").or_else(|| text.strip_suffix(b"\r")) {
        text = shorter;
    }
    text
}

/// What a small file of a work tree or of a git folder holds.
enum Record {
    Text(Vec<u8>),
    Missing,
    /// No regular file, larger than [`MAX_RECORD_BYTES`], with a NUL byte,
    /// or not readable.
    Unreadable,
}

/// The text of the regular file `path`. A link, a named pipe and a folder
/// are not read.
fn record(path: &Path) -> Record {
    let mut options = fs::OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        // No link, and no wait for the other end of a named pipe.
        options.custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK);
    }
    let file = match options.open(path) {
        Ok(file) => file,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Record::Missing,
        Err(_) => return Record::Unreadable,
    };
    if !file.metadata().is_ok_and(|metadata| metadata.is_file()) {
        return Record::Unreadable;
    }
    let mut text = Vec::new();
    if file.take(MAX_RECORD_BYTES.saturating_add(1)).read_to_end(&mut text).is_err() {
        return Record::Unreadable;
    }
    let small = u64::try_from(text.len()).is_ok_and(|length| length <= MAX_RECORD_BYTES);
    if small && !text.contains(&0) { Record::Text(text) } else { Record::Unreadable }
}
