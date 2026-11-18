//! A projected folder's listing (`cmux link start-chat project`) and the one way its serve loop
//! opens a listed file.
//!
//! The listing is the copy's own walk with the copy's own skip rules ([`super::local::list_into`]
//! by [`Rules::Copy`]), so a projection reaches exactly what a copy reaches. The one difference:
//! every file is looked at with `fstatat` through the folder that holds it and never opened,
//! read or hashed. Git's config files and reflogs, which the copy rewrites before they go (their
//! remote URLs lose any user info), are read and rewritten here as for the copy, and the
//! projection serves those rewritten bytes, never the file's own. An untracked file a secret rule
//! keeps on this Mac is listed as `withheld` with its real stat: the machine sees it exists and
//! never gets its bytes.

use std::collections::BTreeMap;
use std::fs::File;
use std::io;
use std::os::unix::fs::MetadataExt as _;
use std::path::Path;

use anyhow::Context as _;

use super::local::{LocalFile, LocalSet, Rules, Source, holdable, list_into, permissions_of};
use super::place;
use super::skips::{Skips, Why};

/// What a stat-only listing keeps beside the copy's own ([`LocalSet::stat_only`]).
#[derive(Debug, Default)]
pub(super) struct StatOnly {
    /// Each listed regular file's stat, by path.
    stats: BTreeMap<String, Times>,
    /// The files a secret rule kept on this Mac, by path.
    withheld: BTreeMap<String, Times>,
}

/// The part of a stat a projection's version and listing need.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(in crate::link) struct Times {
    /// Permission bits (the low 12 bits of the mode).
    pub mode: u32,
    pub size: u64,
    pub mtime_ns: i64,
    pub ctime_ns: i64,
}

/// What one listed path is.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(in crate::link) enum Kind {
    /// A regular file, served from this Mac's disk.
    File,
    /// A file whose bytes stay on this Mac.
    Withheld,
    /// A symlink the copy keeps, with the text it has on the machine.
    Link(String),
    /// Git's file as the copy rewrites it; served as these bytes.
    Rewritten(Vec<u8>),
}

/// One listed path.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(in crate::link) struct Listed {
    pub path: String,
    pub kind: Kind,
    pub times: Times,
}

/// A folder's stat-only listing: every path the copy would send, in path order, and how many
/// the skip rules left out.
#[derive(Debug)]
pub(in crate::link) struct Listing {
    pub entries: Vec<Listed>,
    pub skipped: u64,
}

/// The listing of `folder`.
pub(in crate::link) fn listing(folder: &Path) -> anyhow::Result<Listing> {
    let mut set = LocalSet::new(Skips::new(folder));
    set.stat_only = Some(Box::default());
    list_into(&mut set, folder, Rules::Copy)?;
    let only = set.stat_only.take().map(|only| *only).unwrap_or_default();
    let mut entries = Vec::with_capacity(set.files.len().saturating_add(set.links.len()));
    let mut unlisted: u64 = 0;
    for (path, file) in set.files {
        match file.source {
            Source::Bytes(bytes) => {
                let size = u64::try_from(bytes.len()).unwrap_or(u64::MAX);
                let times = Times { mode: file.permissions, size, mtime_ns: 0, ctime_ns: 0 };
                entries.push(Listed { path, kind: Kind::Rewritten(bytes), times });
            }
            Source::File(_) | Source::Checked(_) => match only.stats.get(&path) {
                Some(times) => entries.push(Listed { path, kind: Kind::File, times: *times }),
                None => unlisted = unlisted.saturating_add(1),
            },
        }
    }
    for (path, linked) in set.links {
        match std::fs::symlink_metadata(folder.join(&path)) {
            Ok(meta) => {
                let times = times_of(&meta);
                entries.push(Listed { path, kind: Kind::Link(linked.target), times });
            }
            Err(_) => unlisted = unlisted.saturating_add(1),
        }
    }
    let withheld = u64::try_from(only.withheld.len()).unwrap_or(u64::MAX);
    for (path, times) in only.withheld {
        entries.push(Listed { path, kind: Kind::Withheld, times });
    }
    entries.sort_by(|a, b| a.path.cmp(&b.path));
    let skipped = set
        .skips
        .total()
        .saturating_add(set.skipped)
        .saturating_add(unlisted)
        .saturating_sub(withheld);
    Ok(Listing { entries, skipped })
}

/// The stat-only form of the copy's `add_in`: the regular file `name` of the folder `handle`
/// holds open is listed from its `fstatat`, never opened; a symlink there now goes as one.
pub(super) fn add_stat(
    set: &mut LocalSet,
    relative: String,
    path: &Path,
    handle: &place::Dir,
    name: &str,
) -> anyhow::Result<()> {
    let Some(stat) =
        handle.lstat(name).with_context(|| format!("cannot look at {}", path.display()))?
    else {
        return Ok(());
    };
    match stat.st_mode & libc::S_IFMT {
        libc::S_IFREG => {
            let times = times_of_stat(&stat);
            let id = (place::widen_u64(stat.st_dev), place::widen_u64(stat.st_ino));
            let source = Source::File(path.to_path_buf());
            let file = LocalFile { source, permissions: permissions_of(times.mode), id: Some(id) };
            if let Some(only) = set.stat_only.as_mut() {
                only.stats.insert(relative.clone(), times);
            }
            set.add(relative, file, times.size)
        }
        libc::S_IFLNK => super::listed::link_in(set, &relative, path, handle, name),
        _ => {
            set.skips.note(&relative, Why::Special);
            Ok(())
        }
    }
}

/// A stat-only listing records the regular file `name` (of the folder `handle` holds open) that
/// a secret rule keeps on this Mac as withheld, with its real stat. Any other listing: nothing.
pub(super) fn withhold(
    set: &mut LocalSet,
    relative: &str,
    handle: &place::Dir,
    name: &str,
) -> anyhow::Result<()> {
    if set.stat_only.is_none() || !holdable(relative) {
        return Ok(());
    }
    let stat = handle.lstat(name).with_context(|| format!("cannot look at {relative}"))?;
    if let (Some(stat), Some(only)) = (stat, set.stat_only.as_mut())
        && stat.st_mode & libc::S_IFMT == libc::S_IFREG
    {
        only.withheld.insert(relative.to_owned(), times_of_stat(&stat));
    }
    Ok(())
}

/// A git working file `path` (below the folder `top` holds open) a secret rule keeps on this
/// Mac: noted as the copy notes it, and withheld in a stat-only listing.
pub(super) fn secret_skipped(
    set: &mut LocalSet,
    top: &place::Dir,
    path: &str,
    why: Why,
) -> anyhow::Result<()> {
    if set.stat_only.is_some()
        && let Ok(Some((dir, name))) = place::parent_of(top, path)
    {
        withhold(set, path, &dir, &name)?;
    }
    set.skips.note(path, why);
    Ok(())
}

/// The times of a `std` metadata (an `fstat` or `lstat`).
pub(in crate::link) fn times_of(meta: &std::fs::Metadata) -> Times {
    Times {
        mode: meta.mode() & 0o7777,
        size: meta.size(),
        mtime_ns: nanos(meta.mtime(), meta.mtime_nsec()),
        ctime_ns: nanos(meta.ctime(), meta.ctime_nsec()),
    }
}

fn times_of_stat(stat: &libc::stat) -> Times {
    Times {
        mode: place::widen(stat.st_mode & 0o7777),
        size: u64::try_from(stat.st_size).unwrap_or(0),
        mtime_ns: nanos(stat.st_mtime, stat.st_mtime_nsec),
        ctime_ns: nanos(stat.st_ctime, stat.st_ctime_nsec),
    }
}

fn nanos(seconds: i64, nanos: i64) -> i64 {
    seconds.saturating_mul(1_000_000_000).saturating_add(nanos)
}

/// What [`open_beneath`] found at a listed path.
#[derive(Debug)]
pub(in crate::link) enum Opened {
    /// The regular file there, opened.
    File(File),
    /// Nothing that is a regular file: missing, a folder, a symlink, a special file, or a
    /// folder on the way that is missing or is not a real folder.
    Gone,
}

/// Opens the regular file `relative` below `root` one name at a time: every folder on the way
/// with `O_DIRECTORY | O_NOFOLLOW`, the file with `O_NOFOLLOW | O_NONBLOCK`, so no symlink is
/// ever crossed and nothing outside `root` is reached, also when one is swapped in meanwhile.
pub(in crate::link) fn open_beneath(root: &Path, relative: &str) -> io::Result<Opened> {
    let top = place::Dir::open(root).map_err(io::Error::other)?;
    let (dir, name) = match place::parent_of(&top, relative) {
        Ok(Some(found)) => found,
        Ok(None) => return Ok(Opened::Gone),
        Err(error) if super::local::swapped(&error) => return Ok(Opened::Gone),
        Err(error) => return Err(error),
    };
    if !matches!(dir.entry(&name)?, place::Entry::File { .. }) {
        return Ok(Opened::Gone);
    }
    match dir.open_file(&name) {
        Ok(file) => Ok(Opened::File(file)),
        Err(error) if super::local::swapped(&error) || error.kind() == io::ErrorKind::NotFound => {
            Ok(Opened::Gone)
        }
        Err(error) => Err(error),
    }
}

#[cfg(test)]
#[path = "stat_walk_tests.rs"]
mod tests;
