//! Safe unpacking of a package archive into a new directory. Packages are
//! tar.gz only (decision SV-R3); another format is refused (exit 4) before
//! anything is written, and a gzip stream that holds no tar entries is
//! refused too.
//!
//! Refused: absolute paths, `..`, hard links, devices, FIFOs, a symlink
//! whose target leaves the package root, writing through any symlink
//! (every parent is checked without following links, and files are created
//! with `O_EXCL`), duplicate entries, more than `max_entries` entries or
//! more than `max_bytes` unpacked bytes. After unpack every symlink is
//! resolved and must stay inside the canonical package root (a chain of
//! links can pass each lexical check and still escape), and every file and
//! directory is fsynced.

use std::fs::{self, OpenOptions};
use std::io::{self, BufReader, Read};
use std::path::{Component, Path, PathBuf};

use cmux_server_core::manifest::{FORMAT_SNIFF_LEN, PackageFormat};
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

/// A symlink at `rel` (relative to the package root `root`) with `target`
/// must stay inside the root when resolved lexically, and may not use `..`
/// after a component that is already a symlink on disk (`a/b/up/..`
/// resolves through the link, not lexically). [`check_tree`] then
/// resolves every link for real, which also catches links created later.
fn check_link_target(root: &Path, rel: &Path, target: &Path) -> Result<()> {
    let mut depth = rel.components().count() as i64 - 1;
    let mut at = rel.parent().map(|p| root.join(p)).unwrap_or_else(|| root.to_path_buf());
    let mut through_link = false;
    for component in target.components() {
        match component {
            Component::Normal(part) => {
                depth += 1;
                at.push(part);
                through_link |= fs::symlink_metadata(&at).is_ok_and(|m| m.file_type().is_symlink());
            }
            Component::CurDir => {}
            Component::ParentDir => {
                if through_link {
                    return Err(unsafe_entry(format!(
                        "symlink {} -> {} uses .. after a symlink",
                        rel.display(),
                        target.display()
                    )));
                }
                at.pop();
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

/// Opens a gzip-compressed tar (decision SV-R3: the only package format).
/// Any other format is refused by name before anything is unpacked.
fn open_reader(archive: &Path) -> Result<Box<dyn Read>> {
    let mut file = BufReader::new(fs::File::open(archive).ctx(archive.display())?);
    let mut head = Vec::with_capacity(FORMAT_SNIFF_LEN);
    (&mut file).take(FORMAT_SNIFF_LEN as u64).read_to_end(&mut head).ctx(archive.display())?;
    PackageFormat::sniff(&head).require_tar_gz().map_err(Error::rejected)?;
    let reader = io::Cursor::new(head).chain(file);
    Ok(Box::new(flate2::read::GzDecoder::new(reader)))
}

/// Unpacks `archive` into `dest`, which must not exist yet.
pub fn unpack(archive: &Path, dest: &Path, limits: Limits) -> Result<()> {
    let corrupt = |e: io::Error| Error::verification(format!("corrupt package archive: {e}"));
    let mut gz = open_reader(archive)?;
    // The first tar header, checked by hand: a header checksum that does
    // not match means a compressed bare binary, not a package. A gzip
    // stream error stays "corrupt".
    let mut first = Vec::with_capacity(512);
    (&mut gz).take(512).read_to_end(&mut first).map_err(corrupt)?;
    if first.len() == 512 && !first.iter().all(|b| *b == 0) && !tar_checksum_ok(&first) {
        return Err(Error::rejected(
            "package is gzip but not tar (the first tar header checksum does not match); \
             store packages are tar.gz only",
        ));
    }
    let mut tar = tar::Archive::new(io::Cursor::new(first).chain(gz));
    fs::create_dir(dest).ctx(dest.display())?;
    let mut entries_seen = 0u64;
    let mut bytes = 0u64;
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
                let size = entry.size();
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
                check_link_target(dest, &rel, &target)?;
                make_symlink(&target, &path, &rel)?;
            }
            other => {
                return Err(unsafe_entry(format!("{} has entry type {other:?}", rel.display())));
            }
        }
    }
    if entries_seen == 0 {
        return Err(Error::rejected(
            "package archive holds no tar entries; store packages are tar.gz only",
        ));
    }
    let root = fs::canonicalize(dest).ctx(dest.display())?;
    check_tree(&root, dest)
}

/// The tar header checksum rule: the octal field at 148..156 equals the sum
/// of all 512 bytes with that field read as spaces.
fn tar_checksum_ok(block: &[u8]) -> bool {
    let field = &block[148..156];
    let text: String = field
        .iter()
        .map(|b| *b as char)
        .take_while(|c| *c != '\0')
        .filter(|c| !c.is_ascii_whitespace())
        .collect();
    let Ok(want) = u32::from_str_radix(&text, 8) else { return false };
    let sum: u32 = block
        .iter()
        .enumerate()
        .map(|(i, b)| if (148..156).contains(&i) { u32::from(b' ') } else { u32::from(*b) })
        .sum();
    sum == want
}

/// Resolves every symlink under `dir` and refuses one that is dangling or
/// leaves the canonical package `root` (chains of links that each pass the
/// lexical check). Fsyncs every directory, so the entries are durable
/// before the package directory is renamed into the store.
fn check_tree(root: &Path, dir: &Path) -> Result<()> {
    for entry in fs::read_dir(dir).ctx(dir.display())? {
        let path = entry.ctx(dir.display())?.path();
        let meta = fs::symlink_metadata(&path).ctx(path.display())?;
        if meta.file_type().is_symlink() {
            let shown = path.strip_prefix(dir).unwrap_or(&path).display().to_string();
            match fs::canonicalize(&path) {
                Ok(real) if real.starts_with(root) => {}
                Ok(_) => {
                    return Err(unsafe_entry(format!(
                        "symlink {shown} resolves outside the package"
                    )));
                }
                Err(_) => {
                    return Err(unsafe_entry(format!("symlink {shown} is dangling or loops")));
                }
            }
        } else if meta.is_dir() {
            check_tree(root, &path)?;
        }
    }
    crate::sys::fsync_dir(dir).ctx(dir.display())
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
    let copied = io::copy(&mut entry.take(size), &mut file).map_err(|e| match e.kind() {
        // The gzip or tar stream broke while reading this entry.
        io::ErrorKind::UnexpectedEof | io::ErrorKind::InvalidInput | io::ErrorKind::InvalidData => {
            Error::verification(format!("corrupt package archive at {}: {e}", rel.display()))
        }
        _ => Error::io(path.display(), e),
    })?;
    if copied != size {
        return Err(Error::verification(format!("truncated entry {}", rel.display())));
    }
    file.sync_all().ctx(path.display())
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
