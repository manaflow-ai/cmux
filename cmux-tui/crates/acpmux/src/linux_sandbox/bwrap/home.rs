//! HOME snapshots for the staged bubblewrap plan. Collection loops exhaust
//! supplied paths or directory entries; descriptor collection refuses over 512.
use super::*;
use crate::linux_sandbox::lookup;
use std::collections::{BTreeMap, BTreeSet};
use std::ffi::{OsStr, OsString};
use std::os::fd::AsFd;
use std::os::unix::ffi::{OsStrExt, OsStringExt};

const RESOLVE_BENEATH: u32 = 0x08;

fn child_name(name: &OsStr) -> Result<CString, String> {
    if name.is_empty() || name == "." || name == ".." || name.as_bytes().contains(&b'/') {
        return Err("HOME child must be a single component".into());
    }
    CString::new(name.as_bytes()).map_err(|_| "HOME child contains NUL".into())
}

/// Inspect the single enumerated name without following symlinks.
fn stat_child(parent: RawFd, name: &OsStr) -> Result<libc::stat, String> {
    let name = child_name(name)?;
    let mut meta = std::mem::MaybeUninit::<libc::stat>::uninit();
    // SAFETY: name is terminated, parent is live, and meta is writable.
    if unsafe { libc::fstatat(parent, name.as_ptr(), meta.as_mut_ptr(), libc::AT_SYMLINK_NOFOLLOW) }
        < 0
    {
        return Err(format!("cannot stat HOME child: {}", io::Error::last_os_error()));
    }
    // SAFETY: successful fstatat initialized meta.
    Ok(unsafe { meta.assume_init() })
}

/// Open only through the enumerated parent and reject replacement since fstatat.
fn open_child(parent: RawFd, name: &OsStr, expected: &libc::stat) -> Result<OwnedFd, String> {
    let name = child_name(name)?;
    let how = OpenHow {
        flags: (libc::O_PATH | libc::O_CLOEXEC | libc::O_NOFOLLOW) as _,
        mode: 0,
        resolve: (RESOLVE_NO_SYMLINKS | RESOLVE_NO_MAGICLINKS | RESOLVE_BENEATH) as _,
    };
    // SAFETY: parent is live and the name and open_how remain valid for the call.
    let raw = unsafe {
        libc::syscall(
            libc::SYS_openat2,
            parent,
            name.as_ptr(),
            &how,
            std::mem::size_of::<OpenHow>(),
        )
    } as RawFd;
    if raw < 0 {
        return Err(format!(
            "HOME child changed or cannot be opened: {}",
            io::Error::last_os_error()
        ));
    }
    // SAFETY: openat2 returned a newly owned descriptor.
    let file = unsafe { fs::File::from_raw_fd(raw) };
    let actual = file.metadata().map_err(|e| e.to_string())?;
    if actual.dev() != expected.st_dev || actual.ino() != expected.st_ino {
        return Err(format!("HOME child changed: {}", name.to_string_lossy()));
    }
    Ok(file.into())
}

/// Read a symlink through its already-open parent directory, avoiding a
/// pathname race between the directory snapshot and the emitted `--symlink`.
fn read_link_at(parent: RawFd, name: &OsStr) -> Result<OsString, String> {
    let c_name =
        CString::new(name.as_bytes()).map_err(|_| "symlink name contains NUL".to_owned())?;
    let mut bytes = vec![0_u8; libc::PATH_MAX as usize];
    // SAFETY: the fd and C string are valid; the output buffer is writable.
    let len = unsafe {
        libc::readlinkat(parent, c_name.as_ptr(), bytes.as_mut_ptr().cast(), bytes.len())
    };
    if len < 0 {
        return Err(format!(
            "cannot read symlink {}: {}",
            name.to_string_lossy(),
            io::Error::last_os_error()
        ));
    }
    if len as usize == bytes.len() {
        return Err("symlink target exceeds PATH_MAX".into());
    }
    bytes.truncate(len as usize);
    Ok(OsString::from_vec(bytes))
}

/// Resolve existing symlinks even when a final component is absent. The
/// loop stops at the first existing ancestor (at worst /); errors refuse.
pub(super) fn resolve_missing(path: &Path) -> Result<PathBuf, String> {
    let mut ancestor = path.to_owned();
    loop {
        match fs::canonicalize(&ancestor) {
            Ok(root) => {
                let rest = path.strip_prefix(&ancestor).map_err(|e| e.to_string())?;
                return Ok(if rest.as_os_str().is_empty() { root } else { root.join(rest) });
            }
            Err(e) if e.kind() == io::ErrorKind::NotFound => {
                if !ancestor.pop() {
                    return Err(format!("cannot resolve {}: {e}", path.display()));
                }
            }
            Err(e) => return Err(format!("cannot resolve {}: {e}", path.display())),
        }
    }
}

/// Both lexical and canonical HOME names stay denied. Existing paths outside
/// HOME use A's full ancestor validation before being returned for masking.
#[derive(Debug, Clone)]
pub(super) struct DeniedSnapshot {
    pub(super) inside: BTreeSet<PathBuf>,
    pub(super) outside: Vec<PathBuf>,
    resolutions: BTreeMap<PathBuf, PathBuf>,
    ancestors: BTreeMap<PathBuf, (u64, u64)>,
}

/// Collect denied names and the resolution snapshot used by reconstruction.
pub(super) fn denied_paths_pinned(
    home: &Path,
    read_denies: &[PathBuf],
) -> Result<DeniedSnapshot, String> {
    let mut snapshot = DeniedSnapshot {
        inside: BTreeSet::new(),
        outside: Vec::new(),
        resolutions: BTreeMap::new(),
        ancestors: BTreeMap::new(),
    };
    for path in read_denies.iter().cloned().chain(LINUX_READ_DENIES.iter().map(|p| home.join(p))) {
        path_arg(&path)?;
        if !path.starts_with(home) {
            // Outside HOME, reject lexical symlinks before any resolution.
            validate_outside(&path, outside_stat)?;
            snapshot.outside.push(path);
            continue;
        }
        let resolved = resolve_missing(&path)?;
        if path == home || resolved == home {
            return Err("read denial covers HOME itself".into());
        }
        if !resolved.starts_with(home) {
            return Err(format!(
                "denied path {} resolves outside HOME: {}",
                path.display(),
                resolved.display()
            ));
        }
        snapshot.resolutions.insert(path.clone(), resolved.clone());
        for ancestor in path.ancestors().filter(|p| p.starts_with(home)) {
            if let Ok(meta) = fs::symlink_metadata(ancestor) {
                snapshot.ancestors.insert(ancestor.to_owned(), (meta.dev(), meta.ino()));
            }
        }
        snapshot.inside.insert(path);
        if resolved != home {
            snapshot.inside.insert(resolved);
        }
    }
    Ok(snapshot)
}

/// Compatibility view for callers that only need the two deny lists.
pub(super) fn denied_paths(
    home: &Path,
    read_denies: &[PathBuf],
) -> Result<(BTreeSet<PathBuf>, Vec<PathBuf>), String> {
    let snapshot = denied_paths_pinned(home, read_denies)?;
    Ok((snapshot.inside, snapshot.outside))
}

/// Rebuild denied ancestors; new host entries remain invisible (stricter than Seatbelt).
pub(super) fn home_view(home: &Path, denied: &BTreeSet<PathBuf>) -> Result<BwrapPlan, String> {
    home_view_pinned(home, denied, None)
}

/// Rebuild HOME after checking the denial-resolution snapshot from collection.
pub(super) fn home_view_pinned(
    home: &Path,
    denied: &BTreeSet<PathBuf>,
    snapshot: Option<&DeniedSnapshot>,
) -> Result<BwrapPlan, String> {
    rebuild(
        home,
        denied,
        snapshot,
        #[cfg(test)]
        &mut |_, _| {},
    )
}

/// Enumeration and mount loops end after the finite HOME snapshot.
pub(super) fn rebuild(
    home: &Path,
    denied: &BTreeSet<PathBuf>,
    snapshot: Option<&DeniedSnapshot>,
    #[cfg(test)] hook: &mut dyn FnMut(&Path, bool),
) -> Result<BwrapPlan, String> {
    if let Some(snapshot) = snapshot {
        verify_snapshot(snapshot)?;
    }
    // Keep the built-in Linux deny set local to this rebuild as a second
    // boundary: callers cannot accidentally omit Claude's credential.
    let mut denied_owned = denied.clone();
    for path in LINUX_READ_DENIES.iter().map(|p| home.join(p)) {
        denied_owned.insert(path.clone());
        denied_owned.insert(resolve_missing(&path)?);
    }
    let denied = &denied_owned;
    let mut dirs = BTreeSet::from([home.to_owned()]);
    // Include every denied name: an ancestor is rebuilt even when another
    // denial makes its leaf redundant, so Linux additions (including Claude's
    // credential) can never be forgotten by the caller.
    for path in denied {
        for parent in path.ancestors().skip(1).take_while(|p| p.starts_with(home)) {
            let parent = resolve_missing(parent)?;
            if !parent.starts_with(home) {
                return Err(format!("ancestor outside HOME: {}", parent.display()));
            }
            if !denied.iter().any(|d| parent.starts_with(d)) {
                dirs.insert(parent);
            }
        }
    }
    let mut out = Vec::new();
    let mut fds = Vec::new();
    // HOME is the sole pathname bind-source open. Every descendant fd is
    // obtained from its enumerated parent and retained until final validation.
    let mut parents = BTreeMap::from([(home.to_owned(), open_bind_source(home)?)]);
    for dir in &dirs {
        out.extend(["--tmpfs".into(), path_arg(dir)?]);
        let Some(parent) = parents.get(dir) else {
            continue; // An absent ancestor contributes only an empty tmpfs.
        };
        // Verify HOME and every rebuilt directory before bytewise exclusion.
        lookup::verify_dir(parent.as_fd())
            .map_err(|e| format!("HOME lookup refused at {}: {e}", dir.display()))?;
        let parent_fd = parent.as_raw_fd();
        let pinned = PathBuf::from(format!("/proc/self/fd/{parent_fd}"));
        let mut children = match fs::read_dir(&pinned) {
            Ok(entries) => entries
                .map(|entry| {
                    let entry = entry?;
                    let name = entry.file_name();
                    let meta = stat_child(parent_fd, &name)
                        .map_err(|e| io::Error::other(e.to_string()))?;
                    Ok((dir.join(name), meta))
                })
                .collect::<io::Result<Vec<_>>>(),
            Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(Vec::new()),
            Err(e) => Err(e),
        }
        .map_err(|e| format!("cannot snapshot {}: {e}", dir.display()))?;
        children.sort_by(|(left, _), (right, _)| {
            left.as_os_str().as_bytes().cmp(right.as_os_str().as_bytes())
        });
        #[cfg(test)]
        hook(dir, false);
        if children.len() > 512 {
            return Err(format!(
                "HOME rebuild directory {} has more than 512 entries",
                dir.display()
            ));
        }
        for (child, meta) in children {
            if denied.iter().any(|d| child.starts_with(d)) {
                continue;
            }
            let name = child.file_name().ok_or("HOME child has no filename")?;
            if meta.st_mode & libc::S_IFMT == libc::S_IFLNK {
                if dirs.contains(&child) {
                    return Err(format!("HOME ancestor changed to a symlink: {}", child.display()));
                }
                let target = read_link_at(parent_fd, name)?;
                let target = target.to_str().ok_or("symlink target must be UTF-8")?;
                out.extend(["--symlink".into(), target.into(), path_arg(&child)?]);
            } else {
                let child_text = path_arg(&child)?;
                #[cfg(test)]
                hook(&child, true);
                let opened = open_child(parent_fd, name, &meta);
                #[cfg(test)]
                hook(&child, false);
                let fd = opened?;
                if dirs.contains(&child) {
                    if meta.st_mode & libc::S_IFMT != libc::S_IFDIR {
                        return Err(format!("HOME ancestor is not a directory: {child_text}"));
                    }
                    parents.insert(child, fd);
                } else {
                    out.extend(["--ro-bind-fd".into(), fd.as_raw_fd().to_string(), child_text]);
                    fds.push(fd);
                }
                if fds.len() + parents.len() > 512 {
                    return Err("HOME rebuild requires more than 512 descriptors".into());
                }
            }
        }
    }
    // Seal only after every descendant mountpoint and symlink exists.
    for dir in dirs.iter().rev() {
        out.extend(["--remount-ro".into(), path_arg(dir)?]);
    }
    if let Some(snapshot) = snapshot {
        verify_snapshot(snapshot)?;
    }
    for (path, fd) in &parents {
        // Fresh lstat is validation only; no mount source is reopened by name.
        let fresh = fs::symlink_metadata(path).map_err(|e| e.to_string())?;
        let mut pinned = std::mem::MaybeUninit::<libc::stat>::uninit();
        // SAFETY: fd is live and pinned is writable.
        if unsafe { libc::fstat(fd.as_raw_fd(), pinned.as_mut_ptr()) } < 0 {
            return Err(io::Error::last_os_error().to_string());
        }
        // SAFETY: fstat initialized pinned on success.
        let pinned = unsafe { pinned.assume_init() };
        if fresh.dev() != pinned.st_dev
            || fresh.ino() != pinned.st_ino
            || snapshot
                .and_then(|s| s.ancestors.get(path))
                .is_some_and(|id| *id != (fresh.dev(), fresh.ino()))
        {
            return Err(format!("HOME ancestor changed: {}", path.display()));
        }
    }
    Ok((out, fds))
}

/// Check that denied paths and their existing HOME ancestors still identify
/// the objects captured during collection. The finite maps are the stop condition.
fn verify_snapshot(snapshot: &DeniedSnapshot) -> Result<(), String> {
    for (path, expected) in &snapshot.resolutions {
        let actual = resolve_missing(path)?;
        if &actual != expected {
            return Err(format!(
                "denied path resolution changed: {} was {}, now {}",
                path.display(),
                expected.display(),
                actual.display()
            ));
        }
    }
    for (path, (dev, ino)) in &snapshot.ancestors {
        let meta = fs::symlink_metadata(path)
            .map_err(|e| format!("HOME ancestor changed: {}: {e}", path.display()))?;
        if meta.dev() != *dev || meta.ino() != *ino {
            return Err(format!("HOME ancestor changed: {}", path.display()));
        }
    }
    Ok(())
}
