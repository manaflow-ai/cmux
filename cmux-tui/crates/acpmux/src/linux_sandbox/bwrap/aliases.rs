//! Mountinfo alias checks, required before G2 enables Linux remote spawns.
//! All loops consume finite mountinfo text, entries, paths, or option lists.
//! Autofs is refused everywhere except /proc, /sys and /dev (replaced by bwrap);
//! systemd's binfmt_misc automount under /proc/sys remains supported.
//! A FUSE or network mount elsewhere exporting protected content at another
//! path remains out of scope, matching Seatbelt's path-based limitation.
use super::*;
use std::collections::BTreeSet;

struct MountEntry {
    id: u64,
    parent: u64,
    device: String,
    root: PathBuf,
    point: PathBuf,
    fs_type: String,
    super_options: String,
}

fn decode_mount_field(raw: &str) -> Result<String, String> {
    let bytes = raw.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] == b'\\'
            && index + 3 < bytes.len()
            && (b'0'..=b'7').contains(&bytes[index + 1])
            && (b'0'..=b'7').contains(&bytes[index + 2])
            && (b'0'..=b'7').contains(&bytes[index + 3])
        {
            let value = u16::from(bytes[index + 1] - b'0') * 64
                + u16::from(bytes[index + 2] - b'0') * 8
                + u16::from(bytes[index + 3] - b'0');
            if value > u16::from(u8::MAX) {
                return Err("invalid mountinfo escape".into());
            }
            out.push(value as u8);
            index += 4;
        } else {
            out.push(bytes[index]);
            index += 1;
        }
    }
    String::from_utf8(out).map_err(|_| "mountinfo path is not UTF-8".into())
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
        let root = decode_mount_field(root).map(PathBuf::from)?;
        let point = decode_mount_field(point).map(PathBuf::from)?;
        if path_arg(&root).is_err() || path_arg(&point).is_err() {
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
    while index < bytes.len() {
        if bytes[index] == b'\\' && index + 3 < bytes.len() {
            index += 4;
        } else if bytes[index] == b':' {
            if start < index {
                layers.push(value[start..index].into());
            }
            index += 1;
            start = index;
        } else {
            index += 1;
        }
    }
    if start < value.len() {
        layers.push(value[start..].into());
    }
    layers
}

fn overlay_layers(options: &str) -> Result<Vec<PathBuf>, String> {
    let mut layers = Vec::new();
    for option in options.split(',') {
        let Some(value) = option
            .strip_prefix("lowerdir=")
            .or_else(|| option.strip_prefix("upperdir="))
            .or_else(|| option.strip_prefix("workdir="))
        else {
            continue;
        };
        for part in split_overlay_layers(value) {
            let path = PathBuf::from(decode_mount_field(&part)?);
            path_arg(&path)?;
            layers.push(path);
        }
    }
    Ok(layers)
}

fn layer_readable(path: &Path) -> bool {
    let Ok(text) = path_arg(path) else {
        return false;
    };
    let Ok(c_path) = CString::new(text.as_bytes()) else {
        return false;
    };
    // SAFETY: c_path is a valid NUL-terminated path.
    unsafe { libc::access(c_path.as_ptr(), libc::X_OK) == 0 }
}

fn local_filesystem(fs_type: &str) -> bool {
    matches!(fs_type, "ext2" | "ext3" | "ext4" | "xfs" | "btrfs" | "tmpfs" | "f2fs" | "bcachefs")
}

fn join_path(base: &Path, suffix: &Path) -> PathBuf {
    if suffix.as_os_str().is_empty() { base.to_path_buf() } else { base.join(suffix) }
}

/// Runs in the keeper before spawning. Missing names use their nearest existing
/// ancestor's mount ID while the caller retains the entire guarded suffix.
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
    // SAFETY: zero is valid for statx; the descriptor is live and output writable.
    let mut stat: libc::statx = unsafe { std::mem::zeroed() };
    let result = unsafe {
        libc::statx(
            fd.as_raw_fd(),
            c"".as_ptr(),
            libc::AT_EMPTY_PATH,
            libc::STATX_MNT_ID,
            &mut stat,
        )
    };
    if result != 0 {
        return Err(format!(
            "cannot obtain mount ID for {}: {}",
            path.display(),
            io::Error::last_os_error()
        ));
    }
    if stat.stx_mask & libc::STATX_MNT_ID == 0 {
        return Err(format!("kernel did not report STATX_MNT_ID for {}", path.display()));
    }
    Ok(stat.stx_mnt_id)
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
    match check_trees(trees, mountinfo) {
        Ok(reasons) => reasons.into_iter().collect(),
        Err(error) => vec![error],
    }
}

fn check_trees(trees: &[(&Path, u64, bool)], mountinfo: &str) -> Result<BTreeSet<String>, String> {
    let mounts = parse_mountinfo(mountinfo)?;
    let mut reasons = BTreeSet::new();
    let mut layers = Vec::new();
    for mount in &mounts {
        if mount.fs_type == "autofs"
            && !["/proc", "/sys", "/dev"].iter().any(|p| mount.point.starts_with(p))
        {
            reasons.insert(format!(
                "autofs mount at {} can propagate new aliases",
                mount.point.display()
            ));
        }
        if mount.fs_type == "overlay" {
            layers.extend(overlay_layers(&mount.super_options)?);
        }
    }
    for &(tree, id, writable) in trees {
        let containing = mounts
            .iter()
            .find(|m| m.id == id)
            .ok_or_else(|| format!("mount ID {id} for {} missing from snapshot", tree.display()))?;
        let suffix = tree.strip_prefix(&containing.point).map_err(|_| "mount ID path mismatch")?;
        let mut pieces =
            vec![(containing, tree.to_path_buf(), join_path(&containing.root, suffix))];
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
            if mount.fs_type == "overlay" {
                for layer in overlay_layers(&mount.super_options)? {
                    if layer_readable(&layer) {
                        reasons.insert(format!(
                            "{} lives on overlayfs whose layer {} is readable here",
                            view.display(),
                            layer.display()
                        ));
                    }
                }
            }
            for layer in &layers {
                if [tree, view.as_path(), underlying.as_path()]
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
                if mount.id == other.id || mount.device != other.device {
                    continue;
                }
                let (source, alternate) = if let Ok(suffix) = underlying.strip_prefix(&other.root) {
                    (view.clone(), join_path(&other.point, suffix))
                } else if let Ok(suffix) = other.root.strip_prefix(&underlying) {
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
mod tests {
    use super::*;

    const ROOT: &str = "1 0 8:1 / / rw - ext4 root rw\n";

    #[test]
    fn regression_hidden_mount_cannot_disguise_containing_mount() {
        let info = format!(
            "{ROOT}2 1 0:42 / /mnt/meta/hooks rw - tmpfs tmpfs rw\n3 1 8:1 /home/u/repo/.git /mnt/meta rw - ext4 root rw\n"
        );
        let reasons = guarded_aliases(&[(Path::new("/mnt/meta/hooks"), 3, true)], &info);
        assert!(reasons.iter().any(|r| r.contains("/home/u/repo/.git/hooks")), "{reasons:?}");
    }

    #[test]
    fn regression_overlay_exports_writable_subtree() {
        let info = format!(
            "{ROOT}2 1 0:42 / /home/u/victim/.git/hooks rw - overlay overlay upperdir=/home/u/work/cache\n"
        );
        let reasons = guarded_aliases(&[(Path::new("/home/u/work"), 1, true)], &info);
        assert!(reasons.iter().any(|r| r.contains("overlay layer")), "{reasons:?}");
    }

    #[test]
    fn regression_protected_descendant_filesystem_is_guarded() {
        let info = format!(
            "{ROOT}2 1 0:42 / /home/u/.ssh/keys rw - tmpfs tmpfs rw\n3 1 0:42 / /mnt/leak rw - tmpfs tmpfs rw\n"
        );
        let reasons = guarded_aliases(&[(Path::new("/home/u/.ssh"), 1, false)], &info);
        assert!(reasons.iter().any(|r| r.contains("/mnt/leak")), "{reasons:?}");
    }

    #[test]
    fn regression_outside_autofs_is_refused() {
        let info = format!("{ROOT}2 1 0:42 / /home/u/victim/.git rw - autofs map rw\n");
        let reasons = guarded_aliases(&[(Path::new("/home/u/work"), 1, true)], &info);
        assert!(reasons.iter().any(|r| r.contains("autofs")), "{reasons:?}");
    }

    #[test]
    fn real_statx_resolves_root_mount_id() {
        let id = resolved_mount_id(Path::new("/")).unwrap();
        let info = fs::read_to_string("/proc/self/mountinfo").unwrap();
        let mounts = parse_mountinfo(&info).unwrap();
        assert!(mounts.iter().any(|m| m.id == id && m.point == Path::new("/")));
        eprintln!("passed: statx resolved / to mount ID {id}");
    }

    #[test]
    fn guarded_views_acceptance_matrix() {
        for (tree, id, info) in [
            ("/home/u/repo", 1, ROOT.to_owned()),
            ("/home/u/repo", 1, "1 0 0:42 /@home /home rw - btrfs root rw\n".into()),
            ("/home/u/repo", 1, "1 0 0:42 /@home /home rw - btrfs root rw\n2 0 0:42 /@other /other rw - btrfs root rw\n".into()),
            ("/home/u/work", 1, format!("{ROOT}2 1 8:1 /home/u/other /mnt/o rw - ext4 root rw\n")),
            (
                "/home/u/work",
                1,
                format!("{ROOT}2 1 8:1 /home/u/work/sub /home/u/work/sub rw - ext4 root rw\n"),
            ),
            ("/tmp", 2, format!("{ROOT}2 1 0:42 / /tmp rw - tmpfs tmpfs rw\n")),
            ("/work", 1, format!("{ROOT}2 1 0:42 / /work/cache rw - tmpfs tmpfs rw\n")),
            ("/work", 1, format!("{ROOT}2 1 0:42 / /proc/sys/fs/binfmt_misc rw - autofs map rw\n")),
            (
                "/work",
                1,
                format!("{ROOT}2 1 0:42 / /elsewhere rw - overlay overlay lowerdir=/a::/b\n"),
            ),
        ] {
            let reasons = guarded_aliases(&[(Path::new(tree), id, true)], &info);
            assert!(reasons.is_empty(), "{info}: {reasons:?}");
        }
    }

    #[test]
    fn hidden_descendants_are_dropped_but_visible_children_remain() {
        let info = format!(
            "{ROOT}2 1 0:42 / /guard/a/keys rw - tmpfs tmpfs rw\n3 1 0:43 / /guard/a rw - tmpfs tmpfs rw\n4 1 0:42 / /mnt/leak rw - tmpfs tmpfs rw\n"
        );
        let trees = [(Path::new("/guard"), 1, false)];
        assert!(guarded_aliases(&trees, &info).is_empty());
        // Reparenting keys into the overmount makes the previously hidden
        // filesystem reachable, so its external alias must now refuse.
        let visible = info.replace("2 1 0:42", "2 3 0:42");
        let reasons = guarded_aliases(&trees, &visible);
        assert!(reasons.iter().any(|r| r.contains("/mnt/leak")), "{reasons:?}");
    }

    #[test]
    fn missing_mount_ids_and_overlay_layer_access_fail_closed() {
        assert!(!guarded_aliases(&[(Path::new("/work"), 999, true)], ROOT).is_empty());
        for (layer, refused) in [("/tmp", true), ("/acpmux-absent-layer/a", false)] {
            let info = format!("{ROOT}2 1 0:42 / /home rw - overlay overlay lowerdir={layer}\n");
            let reasons = guarded_aliases(&[(Path::new("/home/u/.ssh"), 2, false)], &info);
            assert_eq!(!reasons.is_empty(), refused, "{reasons:?}");
        }
    }

    #[test]
    fn guarded_overlap_matrix() {
        for (tree, id, info, expected) in [
            ("/mnt/h", 2, format!("{ROOT}2 1 8:1 /home/u /mnt/h rw - ext4 root rw\n"), "/mnt/h is also visible at /home/u"),
            ("/home/u/work", 1, format!("{ROOT}2 1 8:1 /home/u/work/cache /victim/.git/hooks rw - ext4 root rw\n"), "/home/u/work/cache is also visible at /victim/.git/hooks"),
            ("/home/u/work", 1, format!("{ROOT}2 1 8:1 /home/u/work /mnt/other rw - ext4 root rw\n"), "/home/u/work is also visible at /mnt/other"),
            ("/home/u/work", 1, format!("{ROOT}2 1 8:1 /home/u/work/a/b /mnt/x rw - ext4 root rw\n"), "/home/u/work/a/b is also visible at /mnt/x"),
            ("/home/u/repo", 1, "1 0 0:42 /@home /home rw - btrfs root rw\n2 0 0:42 / /mnt/top rw - btrfs root rw\n".into(), "/home/u/repo is also visible at /mnt/top/@home/u/repo"),
            ("/home/u/.ssh", 1, format!("{ROOT}2 1 8:1 /home /mnt/home rw - ext4 root rw\n"), "/home/u/.ssh is also visible at /mnt/home/u/.ssh"),
        ] {
            for writable in [false, true] {
                let reasons = guarded_aliases(&[(Path::new(tree), id, writable)], &info);
                assert!(reasons.contains(&expected.to_owned()), "{info}: {reasons:?}");
            }
        }
    }

    #[test]
    fn writable_nonlocal_filesystems_are_refused() {
        for fs_type in ["overlay", "fuse.sshfs", "nfs4", "9p", "virtiofs", "autofs"] {
            for point in ["/", "/work", "/work/mnt"] {
                let info = format!("{ROOT}2 1 0:42 / {point} rw - {fs_type} source rw\n");
                let id = if point == "/work/mnt" { 1 } else { 2 };
                let reasons = guarded_aliases(&[(Path::new("/work"), id, true)], &info);
                assert!(reasons.iter().any(|r| r.contains("non-local")), "{info}: {reasons:?}");
            }
        }
    }

    #[test]
    fn overlay_layers_decode_data_only_and_escaped_paths() {
        assert_eq!(overlay_layers(r"lowerdir=/first\072colon::/second\040space:,upperdir=/upper\134slash,workdir=/work").unwrap(),
            ["/first:colon", "/second space", r"/upper\slash", "/work"].map(PathBuf::from));
    }
}
