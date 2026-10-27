//! Mountinfo alias checks, required before G2 enables Linux remote spawns.
//! All loops consume finite mountinfo text, entries, paths, or option lists.
//! A FUSE or network mount elsewhere exporting protected content at another
//! path remains out of scope, matching Seatbelt's path-based limitation.
use super::*;
use std::collections::BTreeSet;

struct MountEntry {
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
        let [_, _, device, root, point, ..] = fields.as_slice() else {
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
            device: (*device).into(),
            root,
            point,
            fs_type: (*fs_type).into(),
            super_options: (*super_options).into(),
        });
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

/// Refuse alternate mount views of protected paths. Overlay layers are also
/// checked because their lower/upper/work directories may be reachable under
/// another filesystem device.
pub(crate) fn mount_aliases(protected: &[PathBuf], mountinfo: &str) -> Vec<String> {
    let mounts = match parse_mountinfo(mountinfo) {
        Ok(mounts) => mounts,
        Err(error) => return vec![error],
    };
    let mut aliases = BTreeSet::new();
    for mount in mounts.iter().filter(|mount| mount.fs_type == "overlay") {
        let layers = match overlay_layers(&mount.super_options) {
            Ok(layers) => layers,
            Err(error) => return vec![error],
        };
        for layer in layers {
            for path in protected {
                if layer.starts_with(path) || path.starts_with(&layer) {
                    aliases.insert(format!(
                        "{} is also visible through overlay layer {}",
                        path.display(),
                        layer.display()
                    ));
                }
            }
        }
    }
    for path in protected {
        let Some((index, mount)) = mounts
            .iter()
            .enumerate()
            .filter(|(_, mount)| path.starts_with(&mount.point))
            .max_by_key(|(_, mount)| mount.point.components().count())
        else {
            aliases.insert(format!("no containing mount for {}", path.display()));
            continue;
        };
        let Ok(rest) = path.strip_prefix(&mount.point) else {
            aliases.insert(format!("invalid containing mount for {}", path.display()));
            continue;
        };
        let relative = mount.root.join(rest);
        if mount.fs_type == "overlay" {
            let layers = match overlay_layers(&mount.super_options) {
                Ok(layers) => layers,
                Err(error) => return vec![error],
            };
            for layer in layers {
                if layer_readable(&layer) {
                    aliases.insert(format!(
                        "{} lives on overlayfs whose layer {} is readable here",
                        path.display(),
                        layer.display()
                    ));
                }
            }
        }
        for (other_index, other) in mounts.iter().enumerate() {
            if other_index != index
                && other.device == mount.device
                && (other.root.starts_with(&relative) || relative.starts_with(&other.root))
            {
                aliases.insert(format!(
                    "{} is also visible at {}",
                    path.display(),
                    other.point.display()
                ));
            }
        }
    }
    aliases.into_iter().collect()
}

fn local_filesystem(fs_type: &str) -> bool {
    matches!(fs_type, "ext2" | "ext3" | "ext4" | "xfs" | "btrfs" | "tmpfs" | "f2fs" | "bcachefs")
}
/// Reject alternate views of writable roots and recursive bind aliases below them.
/// Only a whole filesystem with no overlapping same-device mount is exempt.
/// Loops end after the supplied roots and finite mount table.
pub(super) fn writable_mount_aliases(roots: &[&PathBuf], mountinfo: &str) -> Vec<String> {
    let mounts = match parse_mountinfo(mountinfo) {
        Ok(mounts) => mounts,
        Err(error) => return vec![error],
    };
    let mut aliases = BTreeSet::new();
    for root in roots {
        let Some((index, mount)) = mounts
            .iter()
            .enumerate()
            .filter(|(_, mount)| root.starts_with(&mount.point))
            .max_by_key(|(_, mount)| mount.point.components().count())
        else {
            aliases.insert(format!("no containing mount for writable folder {}", root.display()));
            continue;
        };
        if !local_filesystem(&mount.fs_type) {
            aliases.insert(format!(
                "{} is on non-local filesystem {}",
                root.display(),
                mount.fs_type
            ));
        }
        let Ok(rest) = root.strip_prefix(&mount.point) else {
            aliases.insert(format!("invalid containing mount for {}", root.display()));
            continue;
        };
        let underlying = mount.root.join(rest);
        for (other_index, other) in mounts.iter().enumerate() {
            if other_index == index || other.device != mount.device {
                continue;
            }
            let Ok(suffix) = underlying.strip_prefix(&other.root) else {
                continue;
            };
            let alternate = if suffix.as_os_str().is_empty() {
                other.point.clone()
            } else {
                other.point.join(suffix)
            };
            if alternate.as_path() != root.as_path() {
                aliases.insert(format!(
                    "{} is also visible at {}",
                    root.display(),
                    alternate.display()
                ));
            }
        }
    }
    for (index, mount) in mounts.iter().enumerate() {
        let whole_filesystem = mount.root == Path::new("/")
            && !mounts.iter().enumerate().any(|(other_index, other)| {
                other_index != index
                    && other.device == mount.device
                    && (other.root.starts_with(&mount.root) || mount.root.starts_with(&other.root))
            });
        for root in roots {
            if mount.point.starts_with(root) {
                if !local_filesystem(&mount.fs_type) {
                    aliases.insert(format!(
                        "{} is on non-local filesystem {} inside writable folder {}",
                        mount.point.display(),
                        mount.fs_type,
                        root.display()
                    ));
                } else if whole_filesystem {
                    continue;
                }
                aliases.insert(format!(
                    "{} is a bind mount inside the writable folder {}",
                    mount.point.display(),
                    root.display()
                ));
            }
        }
    }
    aliases.into_iter().collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn writable_roots_inside_aliased_mounts_are_refused() {
        for (root, info, alternate) in [
            (
                "/mnt/meta/hooks",
                "1 0 8:1 / / rw - ext4 root rw\n2 1 8:1 /home/u/repo/.git /mnt/meta rw - ext4 root rw\n",
                "/home/u/repo/.git/hooks",
            ),
            (
                "/mnt/h",
                "1 0 8:1 / / rw - ext4 root rw\n2 1 8:1 /home/u /mnt/h rw - ext4 root rw\n",
                "/home/u",
            ),
            (
                "/home/u/repo",
                "1 0 0:42 /@home /home rw - btrfs root rw\n2 0 0:42 / /mnt/top rw - btrfs root rw\n",
                "/mnt/top/@home/u/repo",
            ),
        ] {
            let reasons = writable_mount_aliases(&[&PathBuf::from(root)], info);
            assert!(
                reasons.contains(&format!("{root} is also visible at {alternate}")),
                "{root}: {reasons:?}"
            );
        }
    }

    #[test]
    fn writable_roots_without_alternate_views_are_allowed() {
        let root = PathBuf::from("/home/u/repo");
        for info in [
            "1 0 8:1 / / rw - ext4 root rw\n2 1 8:1 /home/u/repo/.git /mnt/meta rw - ext4 root rw\n",
            "1 0 0:42 /@home /home rw - btrfs root rw\n",
        ] {
            let reasons = writable_mount_aliases(&[&root], info);
            assert!(reasons.is_empty(), "{info}: {reasons:?}");
        }
    }

    #[test]
    fn writable_mounts_require_an_unaliased_whole_filesystem() {
        let root = PathBuf::from("/work");
        let base = "1 0 8:1 / / rw - ext4 root rw\n";
        for (entry, expected) in [
            ("2 1 8:1 /work/.git/hooks /work/cache rw - ext4 root rw\n", "/work/cache"),
            ("2 1 8:1 /elsewhere /work rw - ext4 root rw\n", "/work"),
            ("2 1 8:1 / /work/cache rw - ext4 root rw\n", "/work/cache"),
        ] {
            let reasons = writable_mount_aliases(&[&root], &format!("{base}{entry}"));
            assert!(
                reasons.contains(&format!(
                    "{expected} is a bind mount inside the writable folder /work"
                )),
                "{reasons:?}"
            );
        }
        for entry in [
            "2 1 0:42 / /work/cache rw - tmpfs tmpfs rw\n",
            "2 1 0:42 / /work rw - tmpfs tmpfs rw\n",
            "2 1 8:1 /work/.git/hooks /work-other/cache rw - ext4 root rw\n",
            "",
        ] {
            assert!(writable_mount_aliases(&[&root], &format!("{base}{entry}")).is_empty());
        }
    }

    #[test]
    fn overlay_layers_decode_multi_lower_and_escaped_paths() {
        assert_eq!(
            overlay_layers(r"rw,lowerdir=/first\072colon:/second\040space,upperdir=/upper\134slash,workdir=/work").unwrap(),
            vec![PathBuf::from("/first:colon"), PathBuf::from("/second space"), PathBuf::from(r"/upper\slash"), PathBuf::from("/work")]
        );
    }

    #[test]
    fn overlay_layers_skip_data_only_empty_parts() {
        assert_eq!(
            overlay_layers("lowerdir=/a::/b,upperdir=/upper,workdir=/work").unwrap(),
            vec![
                PathBuf::from("/a"),
                PathBuf::from("/b"),
                PathBuf::from("/upper"),
                PathBuf::from("/work")
            ]
        );
    }

    #[test]
    fn overlay_layers_anywhere_cannot_export_protected_content() {
        let protected = PathBuf::from("/home/u/.ssh");
        let outside_overlay = "1 2 8:1 / / rw - ext4 root rw\n2 3 0:55 / /elsewhere rw - overlay overlay rw,lowerdir=/home\n";
        assert!(!mount_aliases(std::slice::from_ref(&protected), outside_overlay).is_empty());
        let writable_overlay = "1 2 8:1 / / rw - ext4 root rw\n2 3 0:55 / /work rw - overlay overlay rw,lowerdir=/home\n";
        assert!(!writable_mount_aliases(&[&PathBuf::from("/work")], writable_overlay).is_empty());
    }

    #[test]
    fn nonlocal_writable_mounts_are_refused_at_and_below_root() {
        let root = PathBuf::from("/work");
        for fs_type in ["fuse.sshfs", "nfs4", "9p", "virtiofs", "autofs"] {
            for point in ["/work", "/work/mnt"] {
                let info = format!(
                    "1 2 8:1 / / rw - ext4 root rw\n2 3 0:55 / {point} rw - {fs_type} source rw\n"
                );
                assert!(!writable_mount_aliases(&[&root], &info).is_empty(), "{fs_type} {point}");
            }
        }
    }

    #[test]
    fn writable_root_contained_by_nonlocal_mount_is_refused() {
        let root = PathBuf::from("/work");
        let info = "1 2 8:1 / / rw - ext4 root rw\n2 3 0:55 / / rw - nfs4 source rw\n";
        assert!(!writable_mount_aliases(&[&root], info).is_empty());
    }
}
