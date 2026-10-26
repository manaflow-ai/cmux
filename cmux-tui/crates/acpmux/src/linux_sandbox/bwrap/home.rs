//! HOME snapshots for the staged bubblewrap plan. Collection loops exhaust
//! supplied paths or directory entries; descriptor collection refuses over 512.
use super::*;
use std::collections::BTreeSet;
use std::ffi::{OsStr, OsString};
use std::os::unix::ffi::{OsStrExt, OsStringExt};

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
pub(super) fn denied_paths(
    home: &Path,
    read_denies: &[PathBuf],
) -> Result<(BTreeSet<PathBuf>, Vec<PathBuf>), String> {
    let mut inside = BTreeSet::new();
    let mut outside = BTreeSet::new();
    for path in read_denies.iter().cloned().chain(LINUX_READ_DENIES.iter().map(|p| home.join(p))) {
        path_arg(&path)?;
        let resolved = resolve_missing(&path)?;
        if path == home || resolved == home {
            return Err("read denial covers HOME itself".into());
        }
        if path.starts_with(home) {
            if !resolved.starts_with(home) {
                return Err(format!(
                    "denied path {} resolves outside HOME: {}",
                    path.display(),
                    resolved.display()
                ));
            }
            inside.insert(path);
            if resolved != home {
                inside.insert(resolved);
            }
            continue;
        }
        if resolved.starts_with(home) {
            inside.insert(resolved);
            continue;
        }
        // Share A's full ancestor check, including ownership (chmod) and
        // writable grandparents. outside_view also checks before masking.
        validate_outside(&path, outside_stat)?;
        outside.insert(path);
    }
    Ok((inside, outside.into_iter().collect()))
}

/// Rebuild denied ancestors; new host entries remain invisible (stricter than Seatbelt).
pub(super) fn home_view(home: &Path, denied: &BTreeSet<PathBuf>) -> Result<BwrapPlan, String> {
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
    for dir in &dirs {
        out.extend(["--tmpfs".into(), path_arg(dir)?]);
        let parent_fd = match open_bind_source(dir) {
            Ok(fd) => fd,
            Err(_) if matches!(fs::symlink_metadata(dir), Err(e) if e.kind() == io::ErrorKind::NotFound) =>
            {
                continue;
            }
            Err(error) => return Err(error),
        };
        let pinned = PathBuf::from(format!("/proc/self/fd/{}", parent_fd.as_raw_fd()));
        let children = match fs::read_dir(&pinned) {
            Ok(entries) => entries
                .map(|e| e.map(|e| dir.join(e.file_name())))
                .collect::<io::Result<BTreeSet<_>>>(),
            Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(BTreeSet::new()),
            Err(e) => Err(e),
        }
        .map_err(|e| format!("cannot snapshot {}: {e}", dir.display()))?;
        if children.len() > 512 {
            return Err(format!(
                "HOME rebuild directory {} has more than 512 entries",
                dir.display()
            ));
        }
        for child in children {
            if denied.iter().any(|d| child.starts_with(d)) || dirs.contains(&child) {
                continue;
            }
            let name = child.file_name().ok_or("HOME child has no filename")?;
            let meta = fs::symlink_metadata(pinned.join(name)).map_err(|e| e.to_string())?;
            if meta.is_symlink() {
                let target = read_link_at(parent_fd.as_raw_fd(), name)?;
                let target = target.to_str().ok_or("symlink target must be UTF-8")?;
                out.extend(["--symlink".into(), target.into(), path_arg(&child)?]);
            } else {
                let child_text = path_arg(&child)?;
                let fd = open_bind_source(&child)?;
                out.extend(["--ro-bind-fd".into(), fd.as_raw_fd().to_string(), child_text]);
                fds.push(fd);
                if fds.len() > 512 {
                    return Err("HOME rebuild requires more than 512 bind descriptors".into());
                }
            }
        }
    }
    // Seal only after every descendant mountpoint and symlink exists.
    for dir in dirs.iter().rev() {
        out.extend(["--remount-ro".into(), path_arg(dir)?]);
    }
    Ok((out, fds))
}
