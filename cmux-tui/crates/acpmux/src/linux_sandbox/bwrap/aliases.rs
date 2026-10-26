//! Mountinfo alias checks, required before G2 enables Linux remote spawns.
//! All loops consume finite mountinfo text, entries, paths, or option lists.
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
            layers.push(value[start..index].into());
            index += 1;
            start = index;
        } else {
            index += 1;
        }
    }
    layers.push(value[start..].into());
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
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn overlay_layers_decode_multi_lower_and_escaped_paths() {
        assert_eq!(
            overlay_layers(r"rw,lowerdir=/first\072colon:/second\040space,upperdir=/upper\134slash,workdir=/work").unwrap(),
            vec![PathBuf::from("/first:colon"), PathBuf::from("/second space"), PathBuf::from(r"/upper\slash"), PathBuf::from("/work")]
        );
    }
}
