//! Mountinfo alias checks, required before G2 enables Linux remote spawns.
//! All loops consume finite mountinfo text, entries, paths, or option lists.
//! Autofs is refused everywhere except /proc and /dev (replaced by bwrap);
//! systemd's binfmt_misc automount under /proc/sys remains supported.
//! Reachable overlays require resolvable canonical layer paths; inaccessible
//! layers refuse rather than guessing their relationship to guarded host paths.
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

    fn guarded_aliases(trees: &[(&Path, u64, bool)], info: &str) -> Vec<String> {
        guarded_aliases_with(trees, info, |p| Ok(p.to_path_buf()), |_| Ok(true))
    }

    fn overlay_info(options: &str) -> String {
        format!("{ROOT}2 1 0:42 / /mnt/leak rw - overlay overlay {options}\n")
    }

    #[test]
    fn regression_sys_autofs_is_refused() {
        let info = format!("{ROOT}2 1 0:42 / /sys/kernel/debug rw - autofs map rw\n");
        let reasons = guarded_aliases(&[], &info);
        assert!(reasons.iter().any(|r| r.contains("autofs")), "{reasons:?}");
    }

    #[test]
    fn regression_overlay_plus_options_are_layers() {
        for key in ["lowerdir+", "datadir+"] {
            let info = overlay_info(&format!("{key}=/home/u/.ssh"));
            let reasons = guarded_aliases_with(
                &[(Path::new("/home/u/.ssh"), 1, false)],
                &info,
                |p| Ok(p.to_path_buf()),
                |_| Ok(true),
            );
            assert!(reasons.iter().any(|r| r.contains("overlay layer")), "{key}: {reasons:?}");
        }
        assert_eq!(
            overlay_layers("lowerdir+=/a:b,datadir+=/c:d").unwrap(),
            [PathBuf::from("/a:b"), PathBuf::from("/c:d")]
        );
    }

    #[test]
    fn regression_unknown_overlay_layer_syntax_is_refused() {
        for option in ["fooodir=/secret", "fooodir+=/secret"] {
            let reasons = guarded_aliases_with(
                &[],
                &overlay_info(option),
                |p| Ok(p.to_path_buf()),
                |_| Ok(true),
            );
            assert!(reasons.iter().any(|r| r.contains("unknown overlay")), "{reasons:?}");
        }
    }

    #[test]
    fn reachable_overlay_non_layer_options_are_accepted() {
        let info =
            overlay_info("lowerdir=/var/lib/x,redirect_dir=on,index=on,metacopy=on,xino=auto");
        let reasons = guarded_aliases_with(
            &[(Path::new("/home/u/.ssh"), 1, false)],
            &info,
            |p| Ok(p.to_path_buf()),
            |_| Ok(true),
        );
        assert!(reasons.is_empty(), "{reasons:?}");
    }

    #[test]
    fn regression_overlay_layer_symlink_is_resolved() {
        let reasons = guarded_aliases_with(
            &[(Path::new("/home/u/.ssh"), 1, false)],
            &overlay_info("lowerdir=/srv/ssh-layer"),
            |p| {
                assert_eq!(p, Path::new("/srv/ssh-layer"));
                Ok(PathBuf::from("/home/u/.ssh"))
            },
            |_| Ok(true),
        );
        assert!(reasons.iter().any(|r| r.contains("overlay layer /home/u/.ssh")), "{reasons:?}");
    }

    #[test]
    fn regression_unreachable_overlay_is_skipped() {
        let reasons = guarded_aliases_with(
            &[(Path::new("/home/u/.ssh"), 1, false)],
            &overlay_info("lowerdir=/home/u/.ssh"),
            |_| panic!("unreachable overlay layers must not be resolved"),
            |p| {
                assert_eq!(p, Path::new("/mnt/leak"));
                Ok(false)
            },
        );
        assert!(reasons.is_empty(), "{reasons:?}");
    }

    #[test]
    fn regression_tmpfs_does_not_overlap_unrelated_host_layer() {
        let info =
            format!("{}3 1 0:43 / /tmp rw - tmpfs tmpfs rw\n", overlay_info("lowerdir=/var/lib/x"));
        let reasons = guarded_aliases_with(
            &[(Path::new("/tmp"), 3, true)],
            &info,
            |p| Ok(p.to_path_buf()),
            |_| Ok(true),
        );
        assert!(reasons.is_empty(), "{reasons:?}");
    }

    #[test]
    fn real_overlay_layer_symlink_is_canonicalized() {
        let root = std::env::temp_dir().join(format!("acpmux-layer-{}", uuid::Uuid::now_v7()));
        fs::create_dir(&root).unwrap();
        let root = fs::canonicalize(root).unwrap();
        let secret = root.join("secret");
        fs::create_dir(&secret).unwrap();
        let link = root.join("layer");
        std::os::unix::fs::symlink(&secret, &link).unwrap();
        let point = root.join("mount");
        fs::create_dir(&point).unwrap();
        let info = overlay_info(&format!("lowerdir={}", link.display()))
            .replace("/mnt/leak", point.to_str().unwrap());
        let reasons = super::guarded_aliases(&[(&secret, 1, false)], &info);
        fs::remove_dir_all(root).unwrap();
        assert!(
            reasons.iter().any(|r| r.contains(&format!("overlay layer {}", secret.display()))),
            "{reasons:?}"
        );
        eprintln!("passed: overlay layer symlink resolved through the kernel");
    }

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
    fn real_fdinfo_resolves_root_mount_id() {
        let id = resolved_mount_id(Path::new("/")).unwrap();
        let info = fs::read_to_string("/proc/self/mountinfo").unwrap();
        let mounts = parse_mountinfo(&info).unwrap();
        assert!(mounts.iter().any(|m| m.id == id && m.point == Path::new("/")));
        eprintln!("passed: fdinfo resolved / to mount ID {id}");
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
        let info = overlay_info("lowerdir=/missing/layer");
        let reasons = guarded_aliases_with(&[], &info, |_| Err("missing".into()), |_| Ok(true));
        assert!(
            reasons.iter().any(|r| r.contains("cannot resolve overlay layer /missing/layer")),
            "{reasons:?}"
        );
        let info = format!("{ROOT}2 1 0:42 / /home rw - overlay overlay lowerdir=/tmp\n");
        let reasons = guarded_aliases(&[(Path::new("/home/u/.ssh"), 2, false)], &info);
        assert!(reasons.iter().any(|r| r.contains("lives on overlayfs")), "{reasons:?}");
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
                assert!(
                    reasons.iter().any(|r| r.contains("non-local") || r.contains("autofs")),
                    "{info}: {reasons:?}"
                );
            }
        }
    }

    #[test]
    fn overlay_layers_decode_data_only_and_escaped_paths() {
        assert_eq!(overlay_layers(r"lowerdir=/first\072colon::/second\040space:,upperdir=/upper\134slash,workdir=/work").unwrap(),
            ["/first:colon", "/second space", r"/upper\slash", "/work"].map(PathBuf::from));
    }
}
