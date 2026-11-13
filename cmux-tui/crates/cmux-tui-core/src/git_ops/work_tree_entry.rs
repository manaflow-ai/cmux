//! One entry of a work tree, reached only through real folders.
//!
//! git lists a path by its name, and a recipe file has a name that is known
//! before the read. A folder above such a path can be a link that leads out
//! of the work tree: in a work tree that was made so, or put there between
//! the listing and the read. So no path is resolved by name: each folder is
//! opened through its parent's descriptor and refuses a link (`O_NOFOLLOW`),
//! and the entry is looked at and opened through its folder's descriptor.
//!
//! A system that is not Unix has no call that reads a name through an open
//! folder. There each folder above the entry is looked at by its path, at
//! each entry; a folder that becomes a link between that look and the read
//! is not seen.

use std::ffi::OsStr;
use std::path::{Component, Path};

#[cfg(not(unix))]
pub(super) use by_path::Tree;
#[cfg(unix)]
pub(super) use through_folders::Tree;

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
    /// A folder above the entry is not there or is not a folder, or the path
    /// is not a list of names.
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
    use std::path::Path;

    use super::{Kind, NoEntry};

    const FOLDER_FLAGS: libc::c_int =
        libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC;
    const FILE_FLAGS: libc::c_int =
        libc::O_RDONLY | libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC;

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

    /// What `name` in `folder` is; `None` when nothing has that name.
    fn kind_at(folder: RawFd, name: &CStr) -> Option<Kind> {
        let mut stat = MaybeUninit::<libc::stat>::uninit();
        // SAFETY: a live descriptor, a NUL-terminated name and room for one `stat`.
        let result = unsafe {
            libc::fstatat(folder, name.as_ptr(), stat.as_mut_ptr(), libc::AT_SYMLINK_NOFOLLOW)
        };
        if result != 0 {
            return None;
        }
        // SAFETY: the call succeeded, so it filled the `stat`.
        let stat = unsafe { stat.assume_init() };
        Some(match stat.st_mode & libc::S_IFMT {
            libc::S_IFREG => Kind::File,
            libc::S_IFDIR => Kind::Folder,
            libc::S_IFLNK => Kind::Link,
            _ => Kind::Other,
        })
    }

    impl Tree {
        /// The work tree at `root`, the folder that the caller names.
        pub(in crate::git_ops) fn open(root: &Path) -> Option<Self> {
            let root = File::open(root).ok()?;
            root.metadata().ok()?.is_dir().then(|| Self { root: root.into(), above: Vec::new() })
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
                            _ => NoEntry::Nothing,
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
    use std::fs::File;
    use std::io;
    use std::marker::PhantomData;
    use std::path::{Path, PathBuf};

    use super::{Kind, NoEntry};

    /// A work tree, as its top folder.
    pub(in crate::git_ops) struct Tree {
        root: PathBuf,
    }

    /// A path under the work tree's top folder.
    pub(in crate::git_ops) struct Entry<'a> {
        path: PathBuf,
        tree: PhantomData<&'a Tree>,
    }

    /// What `path` is; `None` when nothing is there.
    fn kind_of(path: &Path) -> Option<Kind> {
        let kind = std::fs::symlink_metadata(path).ok()?.file_type();
        Some(if kind.is_symlink() {
            Kind::Link
        } else if kind.is_dir() {
            Kind::Folder
        } else if kind.is_file() {
            Kind::File
        } else {
            Kind::Other
        })
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
                    _ => return Err(NoEntry::Nothing),
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
        // No entry below a link, below nothing or below a file.
        assert_eq!(kind(&mut tree, "link/file"), Err(NoEntry::Link));
        assert_eq!(kind(&mut tree, "none/file"), Err(NoEntry::Nothing));
        assert_eq!(kind(&mut tree, "real/deep/file/below"), Err(NoEntry::Nothing));
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
}
