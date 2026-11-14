//! Mountinfo alias checks, required before G2 enables Linux remote spawns.
//! All loops consume finite mountinfo text, entries, paths, or option lists.
//! Autofs is refused everywhere except /proc and /dev (replaced by bwrap);
//! systemd's binfmt_misc automount under /proc/sys remains supported.
//! Reachable overlays require resolvable canonical layer paths; inaccessible
//! layers refuse rather than guessing their relationship to guarded host paths.
//! A FUSE or network mount elsewhere exporting protected content at another
//! path remains out of scope, matching Seatbelt's path-based limitation.
//! A namespace file bind mount (nsfs: snapd's /run/snapd/ns/*.mnt, `ip netns`)
//! has a `<type>:[<inode>]` root that names no host path, so it aliases nothing.
use super::*;
use std::collections::BTreeSet;

struct MountEntry {
    id: u64,
    parent: u64,
    device: String,
    /// None only for an nsfs root, which holds no host file data.
    root: Option<PathBuf>,
    point: PathBuf,
    fs_type: String,
    super_options: String,
}

fn decode_mount_field(raw: &str) -> Result<String, String> {
    let bytes = raw.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut index = 0;
    let octal = |digit: u8| (b'0'..=b'7').contains(&digit);
    while let Some(&byte) = bytes.get(index) {
        if let (b'\\', Some(&[high, mid, low])) = (byte, bytes.get(index + 1..index + 4))
            && octal(high)
            && octal(mid)
            && octal(low)
        {
            let value =
                u16::from(high - b'0') * 64 + u16::from(mid - b'0') * 8 + u16::from(low - b'0');
            if value > u16::from(u8::MAX) {
                return Err("invalid mountinfo escape".into());
            }
            out.push(value as u8);
            index += 4;
        } else {
            out.push(byte);
            index += 1;
        }
    }
    String::from_utf8(out).map_err(|_| "mountinfo path is not UTF-8".into())
}

/// nsfs prints its root as `<namespace type>:[<inode>]` (nsfs_show_path), for
/// example `mnt:[4026533090]`. Other filesystems print a path, so this form is
/// accepted only with fs type nsfs; anything else malformed still refuses.
fn nsfs_root(fs_type: &str, root: &str) -> bool {
    let Some((kind, inode)) = root.strip_suffix(']').and_then(|r| r.split_once(":[")) else {
        return false;
    };
    fs_type == "nsfs"
        && !kind.is_empty()
        && kind.bytes().all(|b| b.is_ascii_lowercase() || b == b'_')
        && !inode.is_empty()
        && inode.bytes().all(|b| b.is_ascii_digit())
}

fn parse_mountinfo(mountinfo: &str) -> Result<Vec<MountEntry>, String> {
    let mut mounts = Vec::new();
    for line in mountinfo.lines() {
        let Some((left, right)) = line.split_once(" - ") else {
            return Err("invalid mountinfo".into());
        };
        let fields: Vec<_> = left.split_whitespace().collect();
        let [id, parent, device, root, point, ..] = fields.as_slice() else {
            return Err("invalid mountinfo".into());
        };
        let right: Vec<_> = right.split_whitespace().collect();
        let [fs_type, _, super_options, ..] = right.as_slice() else {
            return Err("invalid mountinfo".into());
        };
        let point = decode_mount_field(point).map(PathBuf::from)?;
        let root = if nsfs_root(fs_type, root) {
            None
        } else {
            Some(decode_mount_field(root).map(PathBuf::from)?)
        };
        if root.as_deref().is_some_and(|r| path_arg(r).is_err()) || path_arg(&point).is_err() {
            return Err("invalid mountinfo path".into());
        }
        mounts.push(MountEntry {
            id: id.parse().map_err(|_| "invalid mount ID")?,
            parent: parent.parse().map_err(|_| "invalid parent mount ID")?,
            device: (*device).into(),
            root,
            point,
            fs_type: (*fs_type).into(),
            super_options: (*super_options).into(),
        });
    }
    let ids: BTreeSet<_> = mounts.iter().map(|m| m.id).collect();
    if ids.len() != mounts.len() {
        return Err("duplicate mount ID".into());
    }
    Ok(mounts)
}

fn split_overlay_layers(value: &str) -> Vec<String> {
    let mut layers = Vec::new();
    let mut start = 0;
    let bytes = value.as_bytes();
    let mut index = 0;
    while let Some(&byte) = bytes.get(index) {
        if byte == b'\\' && index + 3 < bytes.len() {
            index += 4;
        } else if byte == b':' {
            if let Some(layer) = value.get(start..index).filter(|layer| !layer.is_empty()) {
                layers.push(layer.into());
            }
            index += 1;
            start = index;
        } else {
            index += 1;
        }
    }
    if let Some(layer) = value.get(start..).filter(|layer| !layer.is_empty()) {
        layers.push(layer.into());
    }
    layers
}

fn overlay_layers(options: &str) -> Result<Vec<PathBuf>, String> {
    let mut layers = Vec::new();
    for option in options.split(',') {
        let (key, value) = option.split_once('=').unwrap_or((option, ""));
        let parts = match key {
            "lowerdir" => split_overlay_layers(value),
            "lowerdir+" | "datadir+" | "upperdir" | "workdir" => vec![value.to_owned()],
            "redirect_dir"
            | "index"
            | "xino"
            | "metacopy"
            | "nfs_export"
            | "uuid"
            | "volatile"
            | "userxattr"
            | "verity"
            | "default_permissions"
            | "ro"
            | "rw" => {
                continue;
            }
            key if key.ends_with("dir") || key.ends_with("dir+") => {
                return Err(format!("unknown overlay layer option: {key}"));
            }
            _ => continue,
        };
        if parts.is_empty() {
            return Err(format!("empty overlay layer option: {key}"));
        }
        for part in parts {
            let path = PathBuf::from(decode_mount_field(&part)?);
            path_arg(&path)?;
            layers.push(path);
        }
    }
    Ok(layers)
}

/// Only EACCES proves this uid cannot reach the mount; other errors refuse.
fn mount_reachable(path: &Path) -> Result<bool, String> {
    let name = CString::new(path_arg(path)?).map_err(|e| e.to_string())?;
    // SAFETY: name is terminated; O_PATH does not open devices for I/O.
    let raw =
        unsafe { libc::open(name.as_ptr(), libc::O_PATH | libc::O_DIRECTORY | libc::O_CLOEXEC) };
    if raw >= 0 {
        // SAFETY: open returned a new descriptor; dropping it closes it.
        drop(unsafe { OwnedFd::from_raw_fd(raw) });
        return Ok(true);
    }
    let error = io::Error::last_os_error();
    if error.raw_os_error() == Some(libc::EACCES) {
        return Ok(false);
    }
    Err(format!("cannot inspect overlay mount {}: {error}", path.display()))
}

fn replaced_by_bwrap(path: &Path) -> bool {
    path.starts_with("/proc") || path.starts_with("/dev")
}

fn local_filesystem(fs_type: &str) -> bool {
    matches!(fs_type, "ext2" | "ext3" | "ext4" | "xfs" | "btrfs" | "tmpfs" | "f2fs" | "bcachefs")
}

fn join_path(base: &Path, suffix: &Path) -> PathBuf {
    if suffix.as_os_str().is_empty() { base.to_path_buf() } else { base.join(suffix) }
}

/// Runs in the keeper before spawning. Missing names use their nearest existing
/// ancestor's mount ID from fdinfo while the caller retains the guarded suffix.
/// The loop ends at an existing ancestor, an error, or the filesystem root.
pub(super) fn resolved_mount_id(path: &Path) -> Result<u64, String> {
    let mut ancestor = path;
    let fd = loop {
        let name = CString::new(path_arg(ancestor)?).map_err(|e| e.to_string())?;
        // SAFETY: name is NUL terminated; O_PATH opens no device or FIFO for I/O.
        let raw = unsafe { libc::open(name.as_ptr(), libc::O_PATH | libc::O_CLOEXEC) };
        if raw >= 0 {
            // SAFETY: open returned a new owned descriptor.
            break unsafe { OwnedFd::from_raw_fd(raw) };
        }
        let error = io::Error::last_os_error();
        if error.kind() != io::ErrorKind::NotFound {
            return Err(format!("cannot resolve mount for {}: {error}", path.display()));
        }
        ancestor = ancestor.parent().ok_or("no existing mount ancestor")?;
    };
    let info = fs::read_to_string(format!("/proc/self/fdinfo/{}", fd.as_raw_fd()))
        .map_err(|e| format!("cannot read mount ID for {}: {e}", path.display()))?;
    let value = info
        .lines()
        .find_map(|line| line.strip_prefix("mnt_id:"))
        .ok_or_else(|| format!("fdinfo has no mnt_id for {}", path.display()))?;
    value.trim().parse::<u64>().map_err(|e| format!("invalid mount ID for {}: {e}", path.display()))
}

/// Follow parent IDs, not path depth. A sibling mounted over an ancestor hides
/// the old subtree. The walk stops at anchor, a missing parent, or table length.
fn visible_below<'a>(
    mut child: &'a MountEntry,
    anchor: u64,
    mounts: &'a [MountEntry],
) -> Result<bool, String> {
    for _ in 0..mounts.len() {
        if child.id == anchor {
            return Ok(true);
        }
        for sibling in mounts.iter().filter(|m| m.parent == child.parent && m.id != child.id) {
            if sibling.point == child.point {
                return Err(format!("ambiguous stacked mounts at {}", child.point.display()));
            }
            if child.point.starts_with(&sibling.point) {
                return Ok(false);
            }
        }
        let Some(parent) = mounts.iter().find(|m| m.id == child.parent) else {
            return Ok(false);
        };
        child = parent;
    }
    Err("cyclic mount ancestry".into())
}

/// A tree is (canonical path, resolved containing mount ID, writable).
/// Every visible descendant filesystem is a separate piece. All comparisons
/// consume finite trees, pieces and mount entries. Unknown topology refuses.
pub(super) fn guarded_aliases(trees: &[(&Path, u64, bool)], mountinfo: &str) -> Vec<String> {
    guarded_aliases_with(
        trees,
        mountinfo,
        |p| fs::canonicalize(p).map_err(|e| e.to_string()),
        mount_reachable,
    )
}

fn guarded_aliases_with(
    trees: &[(&Path, u64, bool)],
    mountinfo: &str,
    resolve: impl FnMut(&Path) -> Result<PathBuf, String>,
    reachable: impl FnMut(&Path) -> Result<bool, String>,
) -> Vec<String> {
    match check_trees(trees, mountinfo, resolve, reachable) {
        Ok(reasons) => reasons.into_iter().collect(),
        Err(error) => vec![error],
    }
}

fn check_trees(
    trees: &[(&Path, u64, bool)],
    mountinfo: &str,
    mut resolve: impl FnMut(&Path) -> Result<PathBuf, String>,
    mut reachable: impl FnMut(&Path) -> Result<bool, String>,
) -> Result<BTreeSet<String>, String> {
    let mounts = parse_mountinfo(mountinfo)?;
    let mut reasons = BTreeSet::new();
    let mut layers = Vec::new();
    for mount in &mounts {
        if mount.fs_type == "autofs" && !replaced_by_bwrap(&mount.point) {
            reasons.insert(format!(
                "autofs mount at {} can propagate new aliases",
                mount.point.display()
            ));
        }
    }
    // Do not access overlay paths through an autofs trigger before refusing it.
    if !reasons.is_empty() {
        return Ok(reasons);
    }
    for mount in &mounts {
        if mount.fs_type != "overlay" || replaced_by_bwrap(&mount.point) {
            continue;
        }
        if !reachable(&mount.point)? {
            continue;
        }
        for layer in overlay_layers(&mount.super_options)? {
            let canonical = resolve(&layer)
                .map_err(|e| format!("cannot resolve overlay layer {}: {e}", layer.display()))?;
            path_arg(&canonical)?;
            layers.push((mount.id, canonical));
        }
    }
    for &(tree, id, writable) in trees {
        let containing = mounts
            .iter()
            .find(|m| m.id == id)
            .ok_or_else(|| format!("mount ID {id} for {} missing from snapshot", tree.display()))?;
        let suffix = tree.strip_prefix(&containing.point).map_err(|_| "mount ID path mismatch")?;
        let root = containing
            .root
            .as_ref()
            .ok_or_else(|| format!("{} is a namespace file mount", tree.display()))?;
        let mut pieces = vec![(containing, tree.to_path_buf(), Some(join_path(root, suffix)))];
        for mount in &mounts {
            if mount.id != id && mount.point.starts_with(tree) && visible_below(mount, id, &mounts)?
            {
                pieces.push((mount, mount.point.clone(), mount.root.clone()));
            }
        }
        for (mount, view, underlying) in pieces {
            if writable && !local_filesystem(&mount.fs_type) {
                reasons.insert(format!(
                    "{} is on non-local filesystem {}",
                    view.display(),
                    mount.fs_type
                ));
            }
            // Overlay layers are host paths, never device-relative roots.
            for (overlay_id, layer) in &layers {
                if *overlay_id == mount.id {
                    reasons.insert(format!(
                        "{} lives on overlayfs whose layer {} is reachable here",
                        view.display(),
                        layer.display()
                    ));
                }
                if [tree, view.as_path()]
                    .iter()
                    .any(|p| layer.starts_with(p) || p.starts_with(layer))
                {
                    reasons.insert(format!(
                        "{} is also visible through overlay layer {}",
                        view.display(),
                        layer.display()
                    ));
                }
            }
            for other in &mounts {
                // An nsfs root holds a namespace handle, not host file data.
                let (Some(underlying), Some(other_root)) = (&underlying, &other.root) else {
                    continue;
                };
                if mount.id == other.id || mount.device != other.device {
                    continue;
                }
                let (source, alternate) = if let Ok(suffix) = underlying.strip_prefix(other_root) {
                    (view.clone(), join_path(&other.point, suffix))
                } else if let Ok(suffix) = other_root.strip_prefix(underlying) {
                    (join_path(&view, suffix), other.point.clone())
                } else {
                    continue;
                };
                if source != alternate {
                    reasons.insert(format!(
                        "{} is also visible at {}",
                        source.display(),
                        alternate.display()
                    ));
                }
            }
        }
    }
    Ok(reasons)
}

#[cfg(test)]
mod tests;
