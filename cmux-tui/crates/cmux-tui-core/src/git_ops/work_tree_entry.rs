//! One entry of a work tree, reached only through real folders.
//!
//! git lists a path by its name, and a recipe file has a name that is known
//! before the read. A folder above such a path can be a link that leads out
//! of the work tree: in a work tree that was made so, or put there between
//! the listing and the read. So no path is resolved by name: each folder is
//! opened through its parent's descriptor and refuses a link (`O_NOFOLLOW`),
//! and the entry is looked at and opened through its folder's descriptor.
//!
//! The top folder is reached the same way. git gives its path with real
//! folders only, so the walk starts at the root of the file system and takes
//! each folder of that path through its parent: a link at the top folder or
//! above it gives no work tree. The top folder is opened one time and held,
//! and each entry is of that held folder.
//!
//! A system that is not Unix has no call that reads a name through an open
//! folder. There the top folder is found by its path at each entry, and each
//! folder above the entry is looked at by its path, at each entry.

use std::ffi::OsStr;
use std::path::{Component, Path};

#[cfg(not(unix))]
pub(super) use by_path::{Entry, Stat, Tree, kind_in, stat_of};
#[cfg(unix)]
pub(super) use through_folders::{Entry, Stat, Tree, kind_in, stat_of};

/// Folders above one entry; a path with more has no entry.
const MAX_DEPTH: usize = 128;

/// What an entry is. A link is not followed.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Kind {
    File,
    Folder,
    Link,
    Other,
}

/// Why a path has no entry.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum NoEntry {
    /// A link stands where a folder above the entry must be.
    Link,
    /// A file, or another thing that is no folder and no link, stands where
    /// a folder above the entry must be.
    NotFolder,
    /// A folder above the entry is not there or cannot be opened, or the
    /// path is not a list of names.
    Nothing,
}

/// The names of the folders above the entry that `relative` names, outermost
/// first, and the entry's own name.
fn names(relative: &Path) -> Result<(Vec<&OsStr>, &OsStr), NoEntry> {
    let mut parts = Vec::new();
    for component in relative.components() {
        let Component::Normal(part) = component else { return Err(NoEntry::Nothing) };
        parts.push(part);
    }
    let name = parts.pop().ok_or(NoEntry::Nothing)?;
    if parts.len() > MAX_DEPTH {
        return Err(NoEntry::Nothing);
    }
    Ok((parts, name))
}

#[cfg(unix)]
mod through_folders {
    use std::ffi::{CStr, CString, OsStr, OsString};
    use std::fs::File;
    use std::io;
    use std::mem::MaybeUninit;
    use std::os::fd::{AsRawFd as _, FromRawFd as _, OwnedFd, RawFd};
    use std::os::unix::ffi::OsStrExt as _;
    use std::path::{Component, Path};

    use super::{Kind, NoEntry};

    /// `O_DIRECTORY` refuses a name that is no folder. No open waits for the
    /// other end of a FIFO that has the name (`O_NONBLOCK`).
    const FOLDER_FLAGS: libc::c_int =
        libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC;
    const FILE_FLAGS: libc::c_int =
        libc::O_RDONLY | libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC;
    /// A folder above the top folder is a step of the walk only. Where the
    /// system has a flag for it, the open asks for no read of that folder.
    #[cfg(any(target_os = "linux", target_os = "android"))]
    const ABOVE_TOP_FLAGS: libc::c_int =
        libc::O_PATH | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC;
    /// macOS: `O_SEARCH` has `O_DIRECTORY` in it and opens a folder for a
    /// search of its names only.
    #[cfg(target_os = "macos")]
    const ABOVE_TOP_FLAGS: libc::c_int =
        libc::O_SEARCH | libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC;
    #[cfg(not(any(target_os = "linux", target_os = "android", target_os = "macos")))]
    const ABOVE_TOP_FLAGS: libc::c_int = FOLDER_FLAGS;
    /// Bytes of a link's target text that count.
    const MAX_TARGET_BYTES: usize = 4096;

    /// What the system says of an entry or of an open file.
    pub(in crate::git_ops) type Stat = libc::stat;

    /// A work tree, as its open folders.
    pub(in crate::git_ops) struct Tree {
        root: OwnedFd,
        /// The folders above the last entry, outermost first. The entries of
        /// one folder follow each other in a listing, so they share them.
        above: Vec<(OsString, OwnedFd)>,
    }

    /// A name in an open folder of the work tree.
    pub(in crate::git_ops) struct Entry<'a> {
        folder: &'a OwnedFd,
        name: CString,
    }

    fn c_name(name: &OsStr) -> Result<CString, NoEntry> {
        CString::new(name.as_bytes()).map_err(|_| NoEntry::Nothing)
    }

    /// `name` in `folder`, opened with `flags`.
    fn open_at(folder: RawFd, name: &CStr, flags: libc::c_int) -> io::Result<OwnedFd> {
        // SAFETY: a live descriptor and a NUL-terminated name; the result is checked.
        let fd = unsafe { libc::openat(folder, name.as_ptr(), flags) };
        if fd < 0 {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: a descriptor the system just returned, owned by no one else.
        Ok(unsafe { OwnedFd::from_raw_fd(fd) })
    }

    /// What the system says of `name` in `folder`, with no link followed;
    /// `None` when nothing has that name.
    fn stat_at(folder: RawFd, name: &CStr) -> Option<Stat> {
        let mut stat = MaybeUninit::<Stat>::uninit();
        // SAFETY: a live descriptor, a NUL-terminated name and room for one `stat`.
        let result = unsafe {
            libc::fstatat(folder, name.as_ptr(), stat.as_mut_ptr(), libc::AT_SYMLINK_NOFOLLOW)
        };
        if result != 0 {
            return None;
        }
        // SAFETY: the call succeeded, so it filled the `stat`.
        Some(unsafe { stat.assume_init() })
    }

    /// What `stat` is of.
    pub(in crate::git_ops) fn kind_in(stat: &Stat) -> Kind {
        match stat.st_mode & libc::S_IFMT {
            libc::S_IFREG => Kind::File,
            libc::S_IFDIR => Kind::Folder,
            libc::S_IFLNK => Kind::Link,
            _ => Kind::Other,
        }
    }

    /// What `name` in `folder` is; `None` when nothing has that name.
    fn kind_at(folder: RawFd, name: &CStr) -> Option<Kind> {
        stat_at(folder, name).map(|stat| kind_in(&stat))
    }

    /// What the system says of an open file.
    pub(in crate::git_ops) fn stat_of(file: &File) -> Option<Stat> {
        let mut stat = MaybeUninit::<Stat>::uninit();
        // SAFETY: a live descriptor and room for one `stat`.
        let result = unsafe { libc::fstat(file.as_raw_fd(), stat.as_mut_ptr()) };
        if result != 0 {
            return None;
        }
        // SAFETY: the call succeeded, so it filled the `stat`.
        Some(unsafe { stat.assume_init() })
    }

    impl Tree {
        /// The work tree at `root`, the path of its top folder from the root
        /// of the file system, as git gives it: a list of names of real
        /// folders. Each folder of the path is opened through its parent and
        /// refuses a link, and the top folder stays open. A name that is no
        /// folder is no work tree, and no open waits for the other end of a
        /// FIFO that has the name.
        pub(in crate::git_ops) fn open(root: &Path) -> Option<Self> {
            let mut parts = root.components();
            if parts.next() != Some(Component::RootDir) {
                return None;
            }
            let mut names = Vec::new();
            for part in parts {
                let Component::Normal(name) = part else { return None };
                names.push(c_name(name).ok()?);
            }
            let Some((top, folders_above)) = names.split_last() else {
                // The root of the file system is the top folder.
                let root = open_at(libc::AT_FDCWD, c"/", FOLDER_FLAGS).ok()?;
                return Some(Self { root, above: Vec::new() });
            };
            let mut folder = open_at(libc::AT_FDCWD, c"/", ABOVE_TOP_FLAGS).ok()?;
            for name in folders_above {
                folder = open_at(folder.as_raw_fd(), name, ABOVE_TOP_FLAGS).ok()?;
            }
            let root = open_at(folder.as_raw_fd(), top, FOLDER_FLAGS).ok()?;
            Some(Self { root, above: Vec::new() })
        }

        /// The entry that `relative` names, a path under the top folder.
        pub(in crate::git_ops) fn entry(&mut self, relative: &Path) -> Result<Entry<'_>, NoEntry> {
            let (parts, name) = super::names(relative)?;
            let name = c_name(name)?;
            let shared = self
                .above
                .iter()
                .zip(&parts)
                .take_while(|((held, _), part)| held.as_os_str() == **part)
                .count();
            self.above.truncate(shared);
            for part in parts.into_iter().skip(shared) {
                let parent = self.above.last().map_or(&self.root, |(_, folder)| folder).as_raw_fd();
                let part_name = c_name(part)?;
                // The open is the check. After it failed, the look at the
                // name only says why, for the caller's words.
                let folder =
                    open_at(parent, &part_name, FOLDER_FLAGS).map_err(|_| {
                        match kind_at(parent, &part_name) {
                            Some(Kind::Link) => NoEntry::Link,
                            Some(Kind::File | Kind::Other) => NoEntry::NotFolder,
                            Some(Kind::Folder) | None => NoEntry::Nothing,
                        }
                    })?;
                self.above.push((part.to_os_string(), folder));
            }
            let folder = self.above.last().map_or(&self.root, |(_, folder)| folder);
            Ok(Entry { folder, name })
        }
    }

    impl Entry<'_> {
        /// What the entry is; `None` when nothing has its name.
        pub(in crate::git_ops) fn kind(&self) -> Option<Kind> {
            kind_at(self.folder.as_raw_fd(), &self.name)
        }

        /// What the system says of the entry itself: a link is not followed.
        pub(in crate::git_ops) fn stat(&self) -> Option<Stat> {
            stat_at(self.folder.as_raw_fd(), &self.name)
        }

        /// The target text of the entry, a link.
        pub(in crate::git_ops) fn link_target(&self) -> Option<Vec<u8>> {
            let mut target = vec![0_u8; MAX_TARGET_BYTES];
            // SAFETY: a live descriptor, a NUL-terminated name and a buffer of the length given.
            let length = unsafe {
                libc::readlinkat(
                    self.folder.as_raw_fd(),
                    self.name.as_ptr(),
                    target.as_mut_ptr().cast::<libc::c_char>(),
                    target.len(),
                )
            };
            target.truncate(usize::try_from(length).ok()?);
            Some(target)
        }

        /// The entry, a regular file, open for a read. The open follows no
        /// link and waits on no FIFO, and the open file is looked at, not
        /// its name.
        pub(in crate::git_ops) fn open_file(&self) -> io::Result<File> {
            let file = File::from(open_at(self.folder.as_raw_fd(), &self.name, FILE_FLAGS)?);
            if !file.metadata()?.is_file() {
                return Err(io::Error::other("not a regular file"));
            }
            Ok(file)
        }
    }
}

#[cfg(not(unix))]
mod by_path {
    use std::fs::{File, Metadata};
    use std::io;
    use std::marker::PhantomData;
    use std::path::{Path, PathBuf};

    use super::{Kind, NoEntry};

    /// What the system says of an entry or of an open file.
    pub(in crate::git_ops) type Stat = Metadata;

    /// A work tree, as its top folder.
    pub(in crate::git_ops) struct Tree {
        root: PathBuf,
    }

    /// A path under the work tree's top folder.
    pub(in crate::git_ops) struct Entry<'a> {
        path: PathBuf,
        tree: PhantomData<&'a Tree>,
    }

    /// What `stat` is of.
    pub(in crate::git_ops) fn kind_in(stat: &Stat) -> Kind {
        let kind = stat.file_type();
        if kind.is_symlink() {
            Kind::Link
        } else if kind.is_dir() {
            Kind::Folder
        } else if kind.is_file() {
            Kind::File
        } else {
            Kind::Other
        }
    }

    /// What `path` is; `None` when nothing is there.
    fn kind_of(path: &Path) -> Option<Kind> {
        std::fs::symlink_metadata(path).ok().map(|stat| kind_in(&stat))
    }

    /// What the system says of an open file.
    pub(in crate::git_ops) fn stat_of(file: &File) -> Option<Stat> {
        file.metadata().ok()
    }

    impl Tree {
        /// The work tree at `root`, the folder that the caller names.
        pub(in crate::git_ops) fn open(root: &Path) -> Option<Self> {
            root.is_dir().then(|| Self { root: root.to_path_buf() })
        }

        /// The entry that `relative` names, a path under the top folder.
        pub(in crate::git_ops) fn entry(&mut self, relative: &Path) -> Result<Entry<'_>, NoEntry> {
            let (parts, name) = super::names(relative)?;
            let mut path = self.root.clone();
            for part in parts {
                path.push(part);
                match kind_of(&path) {
                    Some(Kind::Folder) => {}
                    Some(Kind::Link) => return Err(NoEntry::Link),
                    Some(Kind::File | Kind::Other) => return Err(NoEntry::NotFolder),
                    None => return Err(NoEntry::Nothing),
                }
            }
            path.push(name);
            Ok(Entry { path, tree: PhantomData })
        }
    }

    impl Entry<'_> {
        /// What the entry is; `None` when nothing has its name.
        pub(in crate::git_ops) fn kind(&self) -> Option<Kind> {
            kind_of(&self.path)
        }

        /// What the system says of the entry itself: a link is not followed.
        pub(in crate::git_ops) fn stat(&self) -> Option<Stat> {
            std::fs::symlink_metadata(&self.path).ok()
        }

        /// The target text of the entry, a link.
        pub(in crate::git_ops) fn link_target(&self) -> Option<Vec<u8>> {
            let target = std::fs::read_link(&self.path).ok()?;
            Some(target.as_os_str().as_encoded_bytes().to_vec())
        }

        /// The entry, a regular file, open for a read.
        pub(in crate::git_ops) fn open_file(&self) -> io::Result<File> {
            if kind_of(&self.path) != Some(Kind::File) {
                return Err(io::Error::other("not a regular file"));
            }
            let file = File::open(&self.path)?;
            if !file.metadata()?.is_file() {
                return Err(io::Error::other("not a regular file"));
            }
            Ok(file)
        }
    }
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;

    /// A new folder, by its real path.
    fn fresh_folder() -> std::path::PathBuf {
        let mut bytes = [0_u8; 6];
        getrandom::fill(&mut bytes).unwrap();
        let hex: String = bytes.iter().map(|byte| format!("{byte:02x}")).collect();
        let folder = std::env::temp_dir().join(format!("cmux-work-tree-entry-{hex}"));
        std::fs::create_dir_all(&folder).unwrap();
        std::fs::canonicalize(folder).unwrap()
    }

    fn kind(tree: &mut Tree, path: &str) -> Result<Option<Kind>, NoEntry> {
        tree.entry(Path::new(path)).map(|entry| entry.kind())
    }

    fn text(tree: &mut Tree, path: &str) -> Option<String> {
        let mut file = tree.entry(Path::new(path)).ok()?.open_file().ok()?;
        let mut text = String::new();
        std::io::Read::read_to_string(&mut file, &mut text).ok()?;
        Some(text)
    }

    #[test]
    fn work_tree_entry_reaches_a_name_through_real_folders_only() {
        let top = fresh_folder();
        let root = top.join("root");
        let outside = top.join("outside");
        std::fs::create_dir_all(root.join("real/deep")).unwrap();
        std::fs::create_dir_all(&outside).unwrap();
        std::fs::write(root.join("real/deep/file"), "inside").unwrap();
        std::fs::write(outside.join("file"), "outside").unwrap();
        std::os::unix::fs::symlink(&outside, root.join("link")).unwrap();
        std::os::unix::fs::symlink(outside.join("file"), root.join("real/file-link")).unwrap();
        let mut tree = Tree::open(&root).unwrap();

        assert_eq!(kind(&mut tree, "real/deep/file"), Ok(Some(Kind::File)));
        assert_eq!(kind(&mut tree, "real/deep"), Ok(Some(Kind::Folder)));
        assert_eq!(kind(&mut tree, "real/none"), Ok(None));
        assert_eq!(kind(&mut tree, "link"), Ok(Some(Kind::Link)));
        assert_eq!(kind(&mut tree, "real/file-link"), Ok(Some(Kind::Link)));
        // No entry below a link, below nothing or below a file, and the result says which.
        assert_eq!(kind(&mut tree, "link/file"), Err(NoEntry::Link));
        assert_eq!(kind(&mut tree, "none/file"), Err(NoEntry::Nothing));
        assert_eq!(kind(&mut tree, "real/deep/file/below"), Err(NoEntry::NotFolder));
        // A path is a list of names: no `..`, no path from the root, no empty path.
        assert_eq!(kind(&mut tree, "real/../link"), Err(NoEntry::Nothing));
        assert_eq!(kind(&mut tree, &outside.join("file").to_string_lossy()), Err(NoEntry::Nothing));
        assert_eq!(kind(&mut tree, ""), Err(NoEntry::Nothing));

        assert_eq!(text(&mut tree, "real/deep/file").as_deref(), Some("inside"));
        assert_eq!(text(&mut tree, "real/file-link"), None, "a link is not opened");
        assert_eq!(text(&mut tree, "real/deep"), None, "a folder is no file");
        assert_eq!(text(&mut tree, "link/file"), None, "no file below a link");

        // `real` becomes a link to a folder with a `deep/file` of its own. The tree holds
        // the folder that it opened, so it reads the old file; a new tree refuses the link.
        std::fs::create_dir_all(outside.join("deep")).unwrap();
        std::fs::write(outside.join("deep/file"), "outside").unwrap();
        assert_eq!(kind(&mut tree, "real/deep/file"), Ok(Some(Kind::File)));
        std::fs::rename(root.join("real"), top.join("real-away")).unwrap();
        std::os::unix::fs::symlink(&outside, root.join("real")).unwrap();
        assert_eq!(text(&mut tree, "real/deep/file").as_deref(), Some("inside"));
        let mut again = Tree::open(&root).unwrap();
        assert_eq!(kind(&mut again, "real/deep/file"), Err(NoEntry::Link));
        assert_eq!(text(&mut again, "real/deep/file"), None);

        std::fs::remove_dir_all(top).unwrap();
    }

    #[test]
    fn work_tree_entry_takes_its_top_folder_through_real_folders_only() {
        let top = fresh_folder();
        let root = top.join("real/root");
        std::fs::create_dir_all(&root).unwrap();
        std::fs::write(root.join("file"), "inside").unwrap();
        std::os::unix::fs::symlink("real", top.join("link")).unwrap();
        std::os::unix::fs::symlink("real/root", top.join("root-link")).unwrap();

        // The path of a top folder, as git gives it, has real folders only.
        let mut tree = Tree::open(&root).unwrap();
        assert_eq!(text(&mut tree, "file").as_deref(), Some("inside"));
        // A link is no folder of that path, at the top folder and above it.
        assert!(Tree::open(&top.join("root-link")).is_none(), "the top folder is a link");
        assert!(Tree::open(&top.join("link/root")).is_none(), "a folder above is a link");
        // The path is a list of names from the root of the file system.
        assert!(Tree::open(&top.join("real/../real/root")).is_none(), "a path with `..`");
        assert!(Tree::open(Path::new("real/root")).is_none(), "a path from no root");

        std::fs::remove_dir_all(top).unwrap();
    }

    #[test]
    fn work_tree_entry_takes_a_top_folder_below_a_folder_that_can_be_passed_and_not_listed() {
        use std::os::unix::fs::PermissionsExt as _;
        let top = fresh_folder();
        let above = top.join("above");
        let root = above.join("root");
        std::fs::create_dir_all(&root).unwrap();
        std::fs::write(root.join("file"), "inside").unwrap();
        // The search right only: a name in `above` is reached, and its names are not listed.
        // A user that has each right (root) passes it with and without the right to list.
        std::fs::set_permissions(&above, std::fs::Permissions::from_mode(0o111)).unwrap();
        let read = Tree::open(&root).and_then(|mut tree| text(&mut tree, "file"));
        // The old rights, before the result is looked at: the folder can be removed.
        std::fs::set_permissions(&above, std::fs::Permissions::from_mode(0o755)).unwrap();
        assert_eq!(read.as_deref(), Some("inside"), "the folder above is passed");

        std::fs::remove_dir_all(top).unwrap();
    }

    #[test]
    fn work_tree_entry_gives_a_link_by_its_target_text_and_a_file_by_one_stat_entry() {
        let top = fresh_folder();
        let root = top.join("root");
        std::fs::create_dir_all(&root).unwrap();
        std::fs::write(root.join("file"), "inside").unwrap();
        std::os::unix::fs::symlink("to/a/place", root.join("link")).unwrap();
        let mut tree = Tree::open(&root).unwrap();

        let link = tree.entry(Path::new("link")).unwrap();
        assert_eq!(link.stat().map(|stat| kind_in(&stat)), Some(Kind::Link));
        assert_eq!(link.link_target().as_deref(), Some(b"to/a/place".as_slice()));
        // The entry of a name and the entry of the open file are of one file.
        let file = tree.entry(Path::new("file")).unwrap();
        let (named, open) = (file.stat().unwrap(), stat_of(&file.open_file().unwrap()).unwrap());
        assert_eq!(kind_in(&named), Kind::File);
        assert_eq!(kind_in(&open), Kind::File);
        assert_eq!((named.st_ino, named.st_dev, named.st_size), (open.st_ino, open.st_dev, 6));
        assert!(tree.entry(Path::new("none")).unwrap().stat().is_none());

        std::fs::remove_dir_all(top).unwrap();
    }

    #[test]
    fn work_tree_entry_waits_for_no_writer_of_a_named_pipe_in_the_place_of_a_folder() {
        let top = fresh_folder();
        let root = top.join("root");
        std::fs::create_dir_all(&root).unwrap();
        for pipe in [top.join("pipe"), root.join("pipe")] {
            use std::os::unix::ffi::OsStrExt as _;
            let name = std::ffi::CString::new(pipe.as_os_str().as_bytes()).unwrap();
            // SAFETY: a NUL-terminated path; the result is checked.
            let made = unsafe { libc::mkfifo(name.as_ptr(), 0o600) };
            assert_eq!(made, 0, "mkfifo {}", pipe.display());
        }
        // Nothing has a pipe open for a write: an open that waits for a writer does not end.
        assert!(Tree::open(&top.join("pipe")).is_none(), "a named pipe is no work tree");
        let mut tree = Tree::open(&root).unwrap();
        assert_eq!(kind(&mut tree, "pipe"), Ok(Some(Kind::Other)));
        assert_eq!(kind(&mut tree, "pipe/below"), Err(NoEntry::NotFolder));
        assert_eq!(text(&mut tree, "pipe"), None, "a named pipe is no file");

        std::fs::remove_dir_all(top).unwrap();
    }
}
