//! The path sandbox of `fs-v1`.
//!
//! A request path is absolute, has no `.` or `..` component, and lies
//! lexically under one root. The resolver then walks it from the root's
//! descriptor one name at a time: `fstatat(AT_SYMLINK_NOFOLLOW)` to look,
//! `openat(O_DIRECTORY | O_NOFOLLOW)` to enter. The kernel never follows a
//! symlink. When the walk meets a symlink it reads the target and splices
//! its components into the walk itself: a stack of directory descriptors
//! gives `..` its meaning, and popping the root, or an absolute target
//! outside the same root, is `fs.permission_denied`. A directory that is
//! swapped for a symlink between the look and the open fails the open
//! (`ELOOP`/`ENOTDIR`), so there is no check-then-use window.

use std::collections::VecDeque;
use std::os::fd::{AsFd, BorrowedFd, OwnedFd};
use std::path::{Path, PathBuf};

use super::entry::{EntryKind, Meta};
use super::error::FsError;
use super::sys;

/// Symlinks one resolution may follow (Linux's `MAXSYMLINKS`).
const MAX_HOPS: usize = 40;
/// Longest request path.
const MAX_PATH_BYTES: usize = 4096;
const MAX_NAME_BYTES: usize = 255;

/// One allowed root: its canonical path, and the component spellings a
/// request may use for it (canonical and as configured).
#[derive(Clone, Debug)]
struct Root {
    canonical: PathBuf,
    spellings: Vec<Vec<String>>,
}

/// The roots `fs-v1` serves.
#[derive(Clone, Debug, Default)]
pub struct Roots {
    roots: Vec<Root>,
}

/// A resolved request: the directory that holds the target and the
/// target's name in it, or (`name: None`) the directory itself.
pub struct Resolved {
    pub dir: OwnedFd,
    pub name: Option<String>,
    /// True when `dir` is the root and `name` is `None`.
    pub is_root: bool,
}

impl Resolved {
    pub fn dir(&self) -> BorrowedFd<'_> {
        self.dir.as_fd()
    }
}

impl Roots {
    /// Roots from configured paths. A path that is not an existing
    /// directory is skipped.
    #[must_use]
    pub fn new(paths: impl IntoIterator<Item = PathBuf>) -> Self {
        let mut roots: Vec<Root> = Vec::new();
        for path in paths {
            let Ok(canonical) = std::fs::canonicalize(&path) else { continue };
            // The file system root is never served (a daemon with HOME=/).
            if !canonical.is_dir() || canonical.parent().is_none() {
                continue;
            }
            let mut spellings = Vec::new();
            for spelling in [&canonical, &path] {
                if let Some(components) = path_components(spelling)
                    && !spellings.contains(&components)
                {
                    spellings.push(components);
                }
            }
            if let Some(existing) = roots.iter_mut().find(|root| root.canonical == canonical) {
                for spelling in spellings {
                    if !existing.spellings.contains(&spelling) {
                        existing.spellings.push(spelling);
                    }
                }
                continue;
            }
            roots.push(Root { canonical, spellings });
        }
        Self { roots }
    }

    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.roots.is_empty()
    }

    /// Resolves the absolute request `path`. With `follow_last` a symlink
    /// as the last component is followed (inside the roots); without it the
    /// last component is returned as named.
    pub fn resolve(&self, path: &str, follow_last: bool) -> Result<Resolved, FsError> {
        let components = request_components(path)?;
        let (root, rest) = self.locate(&components)?;
        Walk::new(root)?.run(rest.into_iter().collect(), follow_last)
    }

    /// The root that holds `components` (the longest matching spelling)
    /// and the components below it.
    fn locate(&self, components: &[String]) -> Result<(&Root, Vec<String>), FsError> {
        let mut best: Option<(&Root, usize)> = None;
        for root in &self.roots {
            for spelling in &root.spellings {
                if components.starts_with(spelling)
                    && best.is_none_or(|(_, length)| spelling.len() > length)
                {
                    best = Some((root, spelling.len()));
                }
            }
        }
        let (root, length) = best.ok_or(FsError::PermissionDenied)?;
        Ok((root, components[length..].to_vec()))
    }

    /// The kind of what `path` names after following symlinks, when that is
    /// inside the roots.
    pub fn target_kind(&self, path: &str) -> Option<EntryKind> {
        let resolved = self.resolve(path, true).ok()?;
        let stat = match &resolved.name {
            Some(name) => sys::lstat_at(resolved.dir(), name).ok()?,
            None => sys::stat_fd(resolved.dir()).ok()?,
        };
        Some(Meta::of(&stat).kind)
    }
}

/// Components of an absolute request path. `.` and `..` are refused
/// (`fs.permission_denied`): a request never climbs.
pub fn request_components(path: &str) -> Result<Vec<String>, FsError> {
    if !path.starts_with('/') {
        return Err(FsError::ParamsInvalid("path must be absolute".into()));
    }
    if path.len() > MAX_PATH_BYTES || path.contains('\0') {
        return Err(FsError::ParamsInvalid("invalid path".into()));
    }
    let mut components = Vec::new();
    for part in path.split('/').filter(|part| !part.is_empty()) {
        if part == "." || part == ".." {
            return Err(FsError::PermissionDenied);
        }
        if part.len() > MAX_NAME_BYTES {
            return Err(FsError::ParamsInvalid("name too long".into()));
        }
        if part.chars().any(char::is_control) {
            return Err(FsError::ParamsInvalid("invalid file name".into()));
        }
        components.push(part.to_owned());
    }
    Ok(components)
}

fn path_components(path: &Path) -> Option<Vec<String>> {
    let text = path.to_str()?;
    let components = request_components(text).ok()?;
    Some(components)
}

/// One resolution in progress.
struct Walk<'a> {
    root: &'a Root,
    /// Directories from the root down; never empty.
    stack: Vec<OwnedFd>,
    hops: usize,
}

impl<'a> Walk<'a> {
    fn new(root: &'a Root) -> Result<Self, FsError> {
        let fd = sys::open_root(&root.canonical)?;
        Ok(Self { root, stack: vec![fd], hops: 0 })
    }

    fn top(&self) -> Result<BorrowedFd<'_>, FsError> {
        self.stack.last().map(AsFd::as_fd).ok_or(FsError::PermissionDenied)
    }

    fn finish(mut self, name: Option<String>) -> Result<Resolved, FsError> {
        let is_root = name.is_none() && self.stack.len() == 1;
        let dir = self.stack.pop().ok_or(FsError::PermissionDenied)?;
        Ok(Resolved { dir, name, is_root })
    }

    fn run(
        mut self,
        mut pending: VecDeque<String>,
        follow_last: bool,
    ) -> Result<Resolved, FsError> {
        while let Some(part) = pending.pop_front() {
            match part.as_str() {
                "" | "." => continue,
                ".." => {
                    if self.stack.len() == 1 {
                        return Err(FsError::PermissionDenied);
                    }
                    self.stack.pop();
                    continue;
                }
                _ => {}
            }
            let last = pending.is_empty();
            if last && !follow_last {
                return self.finish(Some(part));
            }
            let meta = match sys::lstat_at(self.top()?, &part) {
                Ok(stat) => Meta::of(&stat),
                Err(error) if last && error.kind() == std::io::ErrorKind::NotFound => {
                    return self.finish(Some(part));
                }
                Err(error) => return Err(error.into()),
            };
            match meta.kind {
                EntryKind::Symlink => self.splice(&part, &mut pending)?,
                EntryKind::Dir if !last => {
                    let fd = sys::open_dir_at(self.top()?, &part)?;
                    self.stack.push(fd);
                }
                _ if !last => return Err(FsError::NotADirectory),
                _ => return self.finish(Some(part)),
            }
        }
        self.finish(None)
    }

    /// Replaces the symlink `name` (in the top directory) by its target's
    /// components at the front of `pending`.
    fn splice(&mut self, name: &str, pending: &mut VecDeque<String>) -> Result<(), FsError> {
        self.hops += 1;
        if self.hops > MAX_HOPS {
            return Err(FsError::PermissionDenied);
        }
        let target = sys::read_link_at(self.top()?, name)?;
        let target = String::from_utf8(target).map_err(|_| FsError::PermissionDenied)?;
        if target.contains('\0') || target.is_empty() {
            return Err(FsError::PermissionDenied);
        }
        let parts: Vec<String> =
            target.split('/').filter(|part| !part.is_empty()).map(str::to_owned).collect();
        let parts = if target.starts_with('/') {
            // An absolute target restarts at its root, which must be this
            // walk's root (lexically, before any `..`).
            let below = self.below_root(&parts).ok_or(FsError::PermissionDenied)?;
            self.stack.truncate(1);
            below
        } else {
            parts
        };
        for part in parts.into_iter().rev() {
            pending.push_front(part);
        }
        Ok(())
    }

    /// The components of an absolute symlink target below this walk's
    /// root, or `None` when the target is not lexically under it.
    fn below_root(&self, parts: &[String]) -> Option<Vec<String>> {
        self.root
            .spellings
            .iter()
            .filter(|spelling| parts.starts_with(spelling))
            .max_by_key(|spelling| spelling.len())
            .map(|spelling| parts[spelling.len()..].to_vec())
    }
}
