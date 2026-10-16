//! A private namespace below a trusted temporary-directory ancestry.

use std::ffi::CString;
use std::fs::{self, File};
use std::io;
use std::os::fd::{AsRawFd, FromRawFd};
use std::os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};

pub(crate) struct ImagePasteStorage {
    root: PathBuf,
    directory: File,
}

impl ImagePasteStorage {
    pub(crate) fn open() -> io::Result<Self> {
        Self::at(&std::env::temp_dir())
    }

    pub(crate) fn at(temporary: &Path) -> io::Result<Self> {
        let temporary = temporary.canonicalize()?;
        // A non-sticky writable ancestor would allow another user to redirect
        // a later path lookup even while the final directory fd remains pinned.
        for ancestor in temporary.ancestors() {
            let directory = Self::open_directory(ancestor)?;
            let metadata = directory.metadata()?;
            let uid = unsafe { libc::geteuid() };
            if (metadata.uid() != uid && metadata.uid() != 0)
                || (metadata.mode() & 0o022 != 0 && metadata.mode() & 0o1000 == 0)
            {
                return Err(io::Error::new(
                    io::ErrorKind::PermissionDenied,
                    "unsafe image temporary directory",
                ));
            }
        }
        let root = temporary.join(format!("cmux-image-paste-{}", unsafe { libc::geteuid() }));
        match fs::DirBuilder::new().mode(0o700).create(&root) {
            Ok(()) => (),
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => (),
            Err(error) => return Err(error),
        }
        let directory = Self::open_directory(&root)?;
        Self::require_private(&directory)?;
        Ok(Self { root, directory })
    }

    pub(crate) fn root(&self) -> &Path {
        &self.root
    }

    pub(crate) fn entries(&self) -> io::Result<fs::ReadDir> {
        fs::read_dir(self.root())
    }

    pub(crate) fn create_directory(&self, name: &str) -> io::Result<(PathBuf, File)> {
        if !name.strip_prefix("cmux-image-").is_some_and(|suffix| {
            suffix.len() == 32 && suffix.bytes().all(|b| b.is_ascii_hexdigit())
        }) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "invalid image directory name",
            ));
        }
        let name = CString::new(name).map_err(io::Error::other)?;
        // Generated single components are created and opened relative to the
        // pinned namespace, never by following a caller-supplied destination.
        let result = unsafe { libc::mkdirat(self.directory.as_raw_fd(), name.as_ptr(), 0o700) };
        if result != 0 {
            return Err(io::Error::last_os_error());
        }
        let descriptor = unsafe {
            libc::openat(
                self.directory.as_raw_fd(),
                name.as_ptr(),
                libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
            )
        };
        if descriptor < 0 {
            return Err(io::Error::last_os_error());
        }
        // openat returned a new owned descriptor.
        let directory = unsafe { File::from_raw_fd(descriptor) };
        Self::require_private(&directory)?;
        Ok((self.root.join(name.to_str().unwrap()), directory))
    }

    fn open_directory(path: &Path) -> io::Result<File> {
        fs::OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open(path)
    }

    fn require_private(directory: &File) -> io::Result<()> {
        let metadata = directory.metadata()?;
        if metadata.uid() != unsafe { libc::geteuid() } || metadata.mode() & 0o777 != 0o700 {
            return Err(io::Error::new(
                io::ErrorKind::PermissionDenied,
                "image directory must be private",
            ));
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    #[test]
    fn cloud_image_paste_refuses_a_writable_non_sticky_temporary_parent() {
        let mut nonce = [0u8; 16];
        getrandom::fill(&mut nonce).unwrap();
        let suffix: String = nonce.iter().map(|b| format!("{b:02x}")).collect();
        let parent = std::env::temp_dir().join(format!("image-unsafe-test-{suffix}"));
        fs::create_dir(&parent).unwrap();
        fs::set_permissions(&parent, fs::Permissions::from_mode(0o777)).unwrap();
        assert!(ImagePasteStorage::at(&parent).is_err());
        fs::remove_dir(parent).unwrap();
    }
}
