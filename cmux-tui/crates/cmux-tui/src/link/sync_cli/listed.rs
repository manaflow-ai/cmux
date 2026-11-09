//! A plain copy's files and symlinks read through the descriptor of the folder holding them, and
//! each listed file read later as the file listed (local.rs walks the folder).

use std::path::Path;

use anyhow::{Context as _, bail};

use super::local::{LocalFile, LocalSet, Rules, Source, holdable, permissions_of, swapped};
use super::place;
use super::skips::{self, Why};

impl LocalFile {
    /// The regular file at `path`, as `meta` (its `symlink_metadata`) found it.
    pub(super) fn listed(path: &Path, meta: &std::fs::Metadata) -> Self {
        use std::os::unix::fs::{MetadataExt as _, PermissionsExt as _};
        Self {
            source: Source::File(path.to_path_buf()),
            permissions: permissions_of(meta.permissions().mode()),
            id: Some((meta.dev(), meta.ino())),
        }
    }
}

/// Opens the file at `path` without following a symlink or blocking on a FIFO
/// swapped in since it was listed; anything but a regular file is refused, and
/// so is a file other than the one listed as `id` (a folder above it swapped for
/// a symlink that leads out of the folder copied).
pub(super) fn open_listed(path: &Path, id: Option<(u64, u64)>) -> anyhow::Result<std::fs::File> {
    use std::os::unix::fs::{MetadataExt as _, OpenOptionsExt as _};
    let opened = std::fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(path)
        .with_context(|| format!("cannot read {}", path.display()))?;
    let meta = opened.metadata()?;
    if !meta.is_file() {
        bail!("{} is no longer a regular file", path.display());
    }
    if id.is_some_and(|id| id != (meta.dev(), meta.ino())) {
        bail!("{} is not the file listed there (a folder above it changed)", path.display());
    }
    Ok(opened)
}

/// The entry `name` (not a folder) of the folder `handle` holds open, as
/// `entry` found it, read only through that descriptor: a credential file is
/// left out, a regular file and a symlink go, anything else is named skipped.
pub(super) fn entry_in(
    set: &mut LocalSet,
    rules: Rules,
    relative: &str,
    path: &Path,
    handle: &place::Dir,
    name: &str,
    entry: place::Entry,
) -> anyhow::Result<()> {
    if let Some(why) = skips::secret(name)
        .or_else(|| skips::credential(relative, false))
        .filter(|_| rules == Rules::Copy)
    {
        set.skips.note(relative, why);
        return Ok(());
    }
    add_entry(set, relative.to_string(), path, handle, name, entry)
}

/// The entry `name` of the folder `dir` holds open, as `entry` found it, as
/// `relative` (at `path` here), read only through `dir`: a regular file goes
/// as the file opened there, a symlink as its text, anything else is named
/// skipped.
pub(super) fn add_entry(
    set: &mut LocalSet,
    relative: String,
    path: &Path,
    dir: &place::Dir,
    name: &str,
    entry: place::Entry,
) -> anyhow::Result<()> {
    match entry {
        place::Entry::File { mode } => add_in(set, relative, path, dir, name, mode),
        place::Entry::Link => link_in(set, &relative, path, dir, name),
        place::Entry::Other => {
            set.skips.note(&relative, Why::Special);
            Ok(())
        }
        place::Entry::Missing | place::Entry::Dir => Ok(()),
    }
}

/// Calls `visit(relative, folder, name, entry)` for every entry but a folder
/// below the folder `dir` holds open (`relative` under `prefix`). Each folder
/// is entered by descriptor without following a symlink, so a folder swapped
/// for one since it was listed lists nothing outside `dir`.
pub(super) fn walk_in(
    dir: &place::Dir,
    prefix: &str,
    visit: &mut dyn FnMut(&str, &place::Dir, &str, place::Entry) -> anyhow::Result<()>,
) -> anyhow::Result<()> {
    for name in dir.names()? {
        let Some(name) = name.to_str() else { continue };
        let relative =
            if prefix.is_empty() { name.to_string() } else { format!("{prefix}/{name}") };
        if relative == ".DS_Store" {
            continue;
        }
        match dir.entry(name)? {
            place::Entry::Dir => match dir.child(name) {
                Ok(Some(child)) => walk_in(&child, &relative, visit)?,
                Ok(None) => {}
                Err(error) if swapped(&error) => {}
                Err(error) => return Err(error.into()),
            },
            place::Entry::Missing => {}
            entry => visit(&relative, dir, name, entry)?,
        }
    }
    Ok(())
}

/// The symlink `name` of the folder `handle` holds open, its text read
/// through that descriptor (a link goes as its text, never its target's bytes).
fn link_in(
    set: &mut LocalSet,
    relative: &str,
    path: &Path,
    handle: &place::Dir,
    name: &str,
) -> anyhow::Result<()> {
    if !holdable(relative) {
        set.skips.note(relative, skips::unholdable(relative));
        return Ok(());
    }
    let text = match handle.read_link(name) {
        Ok(text) => text,
        Err(error) if error.kind() == std::io::ErrorKind::InvalidData => {
            set.skips.note(relative, Why::NameNotUtf8);
            return Ok(());
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        // Not a symlink there any more: left out, never read through `path`.
        Err(error) if error.raw_os_error() == Some(libc::EINVAL) => return Ok(()),
        Err(error) => return Err(error).with_context(|| format!("cannot read {}", path.display())),
    };
    match super::links::local_with(set.skips.top(), relative, path, &text)
        .with_context(|| format!("cannot read {}", path.display()))?
    {
        super::links::Local::Keep(kept) => {
            set.links.insert(relative.to_string(), kept);
        }
        super::links::Local::Skip(why) => set.skips.note(relative, why),
    }
    Ok(())
}

/// [`add`] for the regular file `name` (listed with `mode`) of the folder
/// `handle` holds open: its identity comes from a descriptor opened there, never
/// through `path`, so a folder above it swapped since the walk opened it lends
/// no other file's. One this user cannot read takes its identity from the entry
/// instead: a sharing rule may leave it out, and a copy fails when it reads it.
fn add_in(
    set: &mut LocalSet,
    relative: String,
    path: &Path,
    handle: &place::Dir,
    name: &str,
    mode: u32,
) -> anyhow::Result<()> {
    if !holdable(&relative) {
        set.skips.note(&relative, skips::unholdable(&relative));
        return Ok(());
    }
    match handle.open_file(name) {
        Ok(file) => {
            let meta = file.metadata()?;
            if meta.is_file() {
                set.files.insert(relative, LocalFile::listed(path, &meta));
            } else {
                set.skips.note_entry(&relative, path, &meta);
            }
        }
        // A symlink there since it was listed: as one, read through `handle`.
        Err(error) if swapped(&error) => link_in(set, &relative, path, handle, name)?,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(error) if error.kind() == std::io::ErrorKind::PermissionDenied => {
            if let Some(id) = handle.inode(name)? {
                let source = Source::File(path.to_path_buf());
                let file = LocalFile { source, permissions: permissions_of(mode), id: Some(id) };
                set.files.insert(relative, file);
            }
        }
        Err(error) => return Err(error).with_context(|| format!("cannot read {}", path.display())),
    }
    Ok(())
}

/// The bytes of the git file `name` (at `path`) that a copy rewrites before
/// it goes (config, a reflog): a regular file read through `dir`, or the file
/// a symlink there names, through every link of its chain wherever it leads,
/// as a plain read would. Gone since it was listed: `None`, so the file is
/// left out and the machine's copy stays. Any other failure fails the sync:
/// empty bytes in its place would overwrite the machine's config.
pub(super) fn git_text(
    dir: &place::Dir,
    name: &str,
    entry: &place::Entry,
    path: &Path,
) -> anyhow::Result<Option<Vec<u8>>> {
    use std::io::Read as _;
    let read = match entry {
        place::Entry::File { .. } => dir.open_file(name).and_then(|mut file| {
            if !file.metadata()?.is_file() {
                return Err(std::io::Error::other("not a regular file"));
            }
            let mut bytes = Vec::new();
            file.read_to_end(&mut bytes).map(|_| bytes)
        }),
        place::Entry::Link => std::fs::read(path),
        _ => Err(std::io::Error::other("not a file or a symlink")),
    };
    match read {
        Ok(bytes) => Ok(Some(bytes)),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(error).with_context(|| format!("cannot read {}", path.display())),
    }
}

#[cfg(test)]
mod tests {
    use std::os::unix::fs::PermissionsExt as _;

    use super::super::local::{Rules, collect};

    /// A file this user cannot read is listed by its entry, not opened, so a
    /// sharing rule can leave it out before anything reads it.
    #[test]
    fn an_unreadable_file_is_listed_without_being_read() {
        let root = tempfile::tempdir().unwrap();
        let top = std::fs::canonicalize(root.path()).unwrap();
        std::fs::write(top.join("a.txt"), "a\n").unwrap();
        std::fs::write(top.join(".env"), "TOKEN=x\n").unwrap();
        std::fs::set_permissions(top.join(".env"), std::fs::Permissions::from_mode(0o000)).unwrap();
        let set = collect(&top, Rules::Share).unwrap();
        let env = set.files.get(".env").expect("listed");
        assert_eq!(env.permissions, 0o600);
        assert!(env.id.is_some() && set.files.contains_key("a.txt"));
    }
}
