//! Which paths of the machine's change list may reach this Mac's folder ([`super`]). The machine
//! is the peer: its paths are checked as text first, then by the Mac walker's own skip rules, so
//! the way back never writes (or deletes) a path the way out would not have listed.

use std::collections::BTreeSet;
use std::io::Write as _;
use std::path::Path;
use std::process::{Command, Stdio};

use crate::link::sync_cli::{links, local, merge, names, skips};

/// A plain relative path: not empty, not absolute, no NUL, no empty, `.` or `..` part.
pub(super) fn plain(path: &str) -> bool {
    !path.is_empty()
        && !path.starts_with('/')
        && !path.contains('\0')
        && path.split('/').all(|part| !matches!(part, "" | "." | ".."))
}

/// Whether `path` is in, or is, a repository folder (`.git` under any spelling a Mac resolves
/// to it): git's own files never come back as files.
pub(super) fn in_dotgit(path: &str) -> bool {
    path.split('/').any(names::is_dotgit)
}

/// What a path would be on this Mac.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Shape {
    File,
    Link,
    Dir,
}

/// Why this Mac's walker would not have listed `path` (a `shape`), so nothing is written or
/// deleted there: a name the machine cannot hold, the sync's own names, a secret or credential,
/// or a dependency or build folder on the way. `has_file` says whether a file is at a path
/// (relative to the folder) on either side, for the build folders that need one beside them.
pub(super) fn kept_home(
    root: &Path,
    path: &str,
    shape: Shape,
    has_file: &dyn Fn(&str) -> bool,
) -> Option<&'static str> {
    if !local::holdable(path) {
        return Some("unholdable");
    }
    let parts: Vec<&str> = path.split('/').collect();
    let reserved = |name: &&str| {
        let lower = name.to_ascii_lowercase();
        lower.starts_with(".cmux-sync") || lower.starts_with(".cmux-pull")
    };
    if parts.iter().any(reserved) || merge::is_conflict_file(path) {
        return Some("reserved");
    }
    let dir = shape == Shape::Dir;
    if skips::credential(path, dir).is_some() || (!dir && skips::secret_at(root, path).is_some()) {
        return Some("secret");
    }
    let folders = if dir { parts.len() } else { parts.len().saturating_sub(1) };
    for (end, name) in parts.iter().enumerate().take(folders) {
        let parent = parts.get(..end).map(|above| above.join("/")).unwrap_or_default();
        let beside = |file: &str| has_file(&join(&parent, file));
        if skips::heavy_by(name, beside) {
            return Some("heavy");
        }
    }
    None
}

/// `parent/name`, or `name` at the top.
pub(super) fn join(parent: &str, name: &str) -> String {
    if parent.is_empty() { name.to_owned() } else { format!("{parent}/{name}") }
}

/// The folder holding `path` (`""` at the top).
pub(super) fn parent(path: &str) -> &str {
    path.rsplit_once('/').map_or("", |(parent, _)| parent)
}

/// The folders above `path`, top first.
pub(super) fn ancestors(path: &str) -> impl Iterator<Item = &str> {
    path.match_indices('/').filter_map(move |(at, _)| path.get(..at))
}

/// Whether the symlink text `text` at `path` stays inside the folder by its words alone (never
/// resolved on disk) and names no repository folder: the walker keeps only such links.
pub(super) fn link_stays_inside(path: &str, text: &str) -> bool {
    !text.split('/').any(names::is_dotgit)
        && links::resolve(links::parent_of(path), text).is_some_and(|target| !in_dotgit(&target))
}

/// Which of `paths` (each with whether it is a folder) the working copy at `root` ignores, as
/// its walker leaves them out. Asked of `git check-ignore` once; a git that cannot answer
/// ignores nothing.
pub(super) fn ignored(root: &Path, paths: &[(String, bool)]) -> BTreeSet<String> {
    if paths.is_empty() {
        return BTreeSet::new();
    }
    let child = Command::new("git")
        .arg("-C")
        .arg(root)
        .args(["check-ignore", "--stdin", "-z"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn();
    let Ok(mut child) = child else { return BTreeSet::new() };
    let mut input = Vec::new();
    for (path, folder) in paths {
        input.extend_from_slice(path.as_bytes());
        if *folder {
            input.push(b'/');
        }
        input.push(0);
    }
    let writer = child.stdin.take().map(|mut stdin| {
        std::thread::spawn(move || {
            let _ = stdin.write_all(&input);
        })
    });
    let output = child.wait_with_output();
    if let Some(writer) = writer {
        let _ = writer.join();
    }
    let Ok(output) = output else { return BTreeSet::new() };
    // 0: some are ignored; 1: none is.
    if !matches!(output.status.code(), Some(0 | 1)) {
        return BTreeSet::new();
    }
    output
        .stdout
        .split(|byte| *byte == 0)
        .filter(|path| !path.is_empty())
        .map(|path| String::from_utf8_lossy(path).trim_end_matches('/').to_owned())
        .collect()
}
