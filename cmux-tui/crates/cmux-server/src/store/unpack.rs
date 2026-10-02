//! Safe unpacking of a package archive (tar, optionally gzip) into a new
//! directory.
//!
//! Refused: absolute paths, `..`, hard links, devices, FIFOs, a symlink
//! whose target leaves the package root, writing through any symlink
//! (every parent is checked without following links, and files are created
//! with `O_EXCL`), duplicate entries, more than `max_entries` entries or
//! more than `max_bytes` unpacked bytes.

use std::fs::{self, OpenOptions};
use std::io::{self, BufReader, Read};
use std::path::{Component, Path, PathBuf};

use tar::EntryType;

use crate::error::{Error, IoContext, Result};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Limits {
    pub max_bytes: u64,
    pub max_entries: u64,
}

impl Limits {
    /// 32 times the archive size (at least 256 MiB) and 200,000 entries.
    pub fn for_archive(archive_size: u64) -> Limits {
        Limits { max_bytes: archive_size.saturating_mul(32).max(256 << 20), max_entries: 200_000 }
    }
}

fn unsafe_entry(what: impl std::fmt::Display) -> Error {
    Error::verification(format!("unsafe package archive: {what}"))
}

/// The entry path as clean relative components, or `None` for the root
/// itself (`./`).
fn clean_relative(path: &Path) -> Result<Option<PathBuf>> {
    let mut out = PathBuf::new();
    for component in path.components() {
        match component {
            Component::Normal(part) => out.push(part),
            Component::CurDir => {}
            Component::ParentDir | Component::RootDir | Component::Prefix(_) => {
                return Err(unsafe_entry(format!("path {}", path.display())));
            }
        }
    }
    Ok((!out.as_os_str().is_empty()).then_some(out))
}

/// A symlink at `rel` (relative to the package root) with `target` must
/// stay inside the root when resolved lexically.
fn check_link_target(rel: &Path, target: &Path) -> Result<()> {
    let mut depth = rel.components().count() as i64 - 1;
    for component in target.components() {
        match component {
            Component::Normal(_) => depth += 1,
            Component::CurDir => {}
            Component::ParentDir => {
                depth -= 1;
                if depth < 0 {
                    return Err(unsafe_entry(format!(
                        "symlink {} -> {} leaves the package",
                        rel.display(),
                        target.display()
                    )));
                }
            }
            Component::RootDir | Component::Prefix(_) => {
                return Err(unsafe_entry(format!(
                    "absolute symlink {} -> {}",
                    rel.display(),
                    target.display()
                )));
            }
        }
    }
    if target.as_os_str().is_empty() {
        return Err(unsafe_entry(format!("empty symlink {}", rel.display())));
    }
    Ok(())
}

/// Creates every parent directory of `rel` under `root`, refusing a parent
/// that exists as anything but a real directory.
fn ensure_parents(root: &Path, rel: &Path) -> Result<()> {
    let mut dir = root.to_path_buf();
    let parents: Vec<_> = rel.parent().map(|p| p.components().collect()).unwrap_or_default();
    for component in parents {
        dir.push(component);
        match fs::symlink_metadata(&dir) {
            Ok(meta) if meta.is_dir() => {}
            Ok(_) => return Err(unsafe_entry(format!("{} is not a directory", dir.display()))),
            Err(e) if e.kind() == io::ErrorKind::NotFound => {
                fs::create_dir(&dir).ctx(dir.display())?;
            }
            Err(e) => return Err(Error::io(dir.display(), e)),
        }
    }
    Ok(())
}

fn open_reader(archive: &Path) -> Result<Box<dyn Read>> {
    let mut file = BufReader::new(fs::File::open(archive).ctx(archive.display())?);
    let mut magic = [0u8; 2];
    let n = file.read(&mut magic).ctx(archive.display())?;
    let head = io::Cursor::new(magic[..n].to_vec());
    let reader = head.chain(file);
    if n == 2 && magic == [0x1f, 0x8b] {
        Ok(Box::new(flate2::read::GzDecoder::new(reader)))
    } else {
        Ok(Box::new(reader))
    }
}

/// Unpacks `archive` into `dest`, which must not exist yet.
pub fn unpack(archive: &Path, dest: &Path, limits: Limits) -> Result<()> {
    fs::create_dir(dest).ctx(dest.display())?;
    let mut tar = tar::Archive::new(open_reader(archive)?);
    let mut entries_seen = 0u64;
    let mut bytes = 0u64;
    let corrupt = |e: io::Error| Error::verification(format!("corrupt package archive: {e}"));
    for entry in tar.entries().map_err(corrupt)? {
        let mut entry = entry.map_err(corrupt)?;
        entries_seen += 1;
        if entries_seen > limits.max_entries {
            return Err(unsafe_entry(format!("more than {} entries", limits.max_entries)));
        }
        let kind = entry.header().entry_type();
        if matches!(kind, EntryType::XGlobalHeader) {
            continue;
        }
        let raw = entry.path().map_err(corrupt)?.into_owned();
        let Some(rel) = clean_relative(&raw)? else { continue };
        ensure_parents(dest, &rel)?;
        let path = dest.join(&rel);
        match kind {
            EntryType::Directory => match fs::symlink_metadata(&path) {
                Ok(meta) if meta.is_dir() => {}
                Ok(_) => return Err(unsafe_entry(format!("duplicate entry {}", rel.display()))),
                Err(_) => fs::create_dir(&path).ctx(path.display())?,
            },
            EntryType::Regular | EntryType::Continuous => {
                let size = entry.header().size().map_err(corrupt)?;
                bytes = bytes.saturating_add(size);
                if bytes > limits.max_bytes {
                    return Err(unsafe_entry(format!("more than {} bytes", limits.max_bytes)));
                }
                let executable = entry.header().mode().map_err(corrupt)? & 0o111 != 0;
                write_file(&mut entry, &path, &rel, executable, size)?;
            }
            EntryType::Symlink => {
                let target = entry
                    .link_name()
                    .map_err(corrupt)?
                    .ok_or_else(|| {
                        unsafe_entry(format!("symlink {} has no target", rel.display()))
                    })?
                    .into_owned();
                check_link_target(&rel, &target)?;
                make_symlink(&target, &path, &rel)?;
            }
            other => {
                return Err(unsafe_entry(format!("{} has entry type {other:?}", rel.display())));
            }
        }
    }
    Ok(())
}

fn write_file(
    entry: &mut impl Read,
    path: &Path,
    rel: &Path,
    executable: bool,
    size: u64,
) -> Result<()> {
    let mut options = OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(if executable { 0o755 } else { 0o644 });
    }
    #[cfg(not(unix))]
    let _ = executable;
    let mut file = options
        .open(path)
        .map_err(|e| unsafe_entry(format!("cannot create {} ({e})", rel.display())))?;
    let copied = io::copy(&mut entry.take(size), &mut file).ctx(path.display())?;
    if copied != size {
        return Err(Error::verification(format!("truncated entry {}", rel.display())));
    }
    Ok(())
}

fn make_symlink(target: &Path, path: &Path, rel: &Path) -> Result<()> {
    #[cfg(unix)]
    {
        std::os::unix::fs::symlink(target, path)
            .map_err(|e| unsafe_entry(format!("cannot create symlink {} ({e})", rel.display())))
    }
    #[cfg(not(unix))]
    {
        let _ = (target, path);
        Err(unsafe_entry(format!("symlink {} needs a Unix platform", rel.display())))
    }
}
