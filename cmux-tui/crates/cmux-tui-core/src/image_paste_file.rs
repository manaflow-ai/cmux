//! Private, inode-checked temporary files. No caller-supplied path is accepted.

use std::ffi::{CStr, CString};
use std::fs::{self, File};
use std::io::{Read, Seek, SeekFrom, Write};
use std::os::fd::{AsRawFd, FromRawFd};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::PathBuf;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

#[derive(serde::Serialize, serde::Deserialize)]
struct Receipt {
    version: u8,
    ownership: [u8; 16],
    directory_device: u64,
    directory_inode: u64,
    file_device: u64,
    file_inode: u64,
    name: String,
    expires: u64,
}

#[derive(PartialEq, Eq)]
enum EntryOwnership {
    Owned,
    Foreign,
    Absent,
    Unavailable,
}

pub(crate) struct ImagePasteFile {
    directory: PathBuf,
    directory_handle: File,
    name: CString,
    file: File,
    receipt: File,
    cleanup: bool,
}

impl ImagePasteFile {
    pub(crate) fn create(extension: &str) -> std::io::Result<Self> {
        Self::create_in(&crate::image_paste_storage::ImagePasteStorage::open()?, extension)
    }

    pub(crate) fn create_in(
        storage: &crate::image_paste_storage::ImagePasteStorage,
        extension: &str,
    ) -> std::io::Result<Self> {
        if !["png", "jpg", "gif", "webp"].contains(&extension) {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidInput,
                "invalid image extension",
            ));
        }
        let mut random = [0u8; 16];
        getrandom::fill(&mut random)
            .map_err(|_| std::io::Error::other("temporary image randomness unavailable"))?;
        let name: String = random.iter().map(|byte| format!("{byte:02x}")).collect();
        let (directory, directory_handle) =
            storage.create_directory(&format!("cmux-image-{name}"))?;
        let result = (|| {
            let name = CString::new(format!("clipboard.{extension}")).unwrap();
            // The directory descriptor pins the newly created private directory.
            let fd = unsafe {
                libc::openat(
                    directory_handle.as_raw_fd(),
                    name.as_ptr(),
                    libc::O_RDWR
                        | libc::O_CREAT
                        | libc::O_EXCL
                        | libc::O_NOFOLLOW
                        | libc::O_CLOEXEC,
                    0o600,
                )
            };
            if fd < 0 {
                return Err(std::io::Error::last_os_error());
            }
            // openat returned a new descriptor owned only by this File.
            let file = unsafe { File::from_raw_fd(fd) };
            let directory_metadata = directory_handle.metadata()?;
            let file_metadata = file.metadata()?;
            let receipt_name = CString::new(".receipt").unwrap();
            // The receipt is durable before the first clipboard byte is accepted.
            let receipt_fd = unsafe {
                libc::openat(
                    directory_handle.as_raw_fd(),
                    receipt_name.as_ptr(),
                    libc::O_RDWR
                        | libc::O_CREAT
                        | libc::O_EXCL
                        | libc::O_NOFOLLOW
                        | libc::O_CLOEXEC,
                    0o600,
                )
            };
            if receipt_fd < 0 {
                unsafe {
                    libc::unlinkat(directory_handle.as_raw_fd(), name.as_ptr(), 0);
                }
                return Err(std::io::Error::last_os_error());
            }
            // openat returned a new, owned descriptor.
            let receipt = unsafe { File::from_raw_fd(receipt_fd) };
            let mut owned = Self {
                directory: directory.clone(),
                directory_handle,
                name,
                file,
                receipt,
                cleanup: true,
            };
            let mut ownership = [0u8; 16];
            getrandom::fill(&mut ownership)
                .map_err(|_| std::io::Error::other("image ownership randomness unavailable"))?;
            crate::image_paste_ownership::ImagePasteOwnership::mark(&owned.file, &ownership)?;
            let metadata = Receipt {
                version: 2,
                ownership,
                directory_device: directory_metadata.dev(),
                directory_inode: directory_metadata.ino(),
                file_device: file_metadata.dev(),
                file_inode: file_metadata.ino(),
                name: owned.name.to_str().unwrap().to_owned(),
                // Two minutes to upload plus ten minutes for the agent to read.
                expires: SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_secs()
                    + 720,
            };
            serde_json::to_writer(&mut owned.receipt, &metadata)?;
            owned.receipt.sync_all()?;
            owned.directory_handle.sync_all()?;
            Ok(owned)
        })();
        if result.is_err() {
            let _ = fs::remove_dir(&directory);
        }
        result
    }

    pub(crate) fn append(&mut self, bytes: &[u8]) -> std::io::Result<()> {
        self.file.write_all(bytes)
    }

    pub(crate) fn header(&mut self) -> std::io::Result<Vec<u8>> {
        self.file.seek(SeekFrom::Start(0))?;
        let mut header = vec![0; 32];
        let count = self.file.read(&mut header)?;
        header.truncate(count);
        Ok(header)
    }

    pub(crate) fn path(&self) -> std::io::Result<PathBuf> {
        if !self.directory_matches() || !self.file_matches() {
            return Err(std::io::Error::other("temporary image was replaced"));
        }
        Ok(self.directory.join(self.name.to_str().unwrap()))
    }

    fn directory_matches(&self) -> bool {
        match (fs::symlink_metadata(&self.directory), self.directory_handle.metadata()) {
            (Ok(path), Ok(owned)) => {
                path.is_dir() && path.dev() == owned.dev() && path.ino() == owned.ino()
            }
            _ => false,
        }
    }

    fn file_matches(&self) -> bool {
        self.entry_matches(&self.name, &self.file)
    }

    fn entry_matches(&self, name: &CStr, expected: &File) -> bool {
        self.entry_ownership(name, expected) == EntryOwnership::Owned
    }

    fn entry_ownership(&self, name: &CStr, expected: &File) -> EntryOwnership {
        let Ok(owned) = expected.metadata() else { return EntryOwnership::Unavailable };
        let mut current = std::mem::MaybeUninit::<libc::stat>::uninit();
        // AT_SYMLINK_NOFOLLOW compares the directory entry itself, never its target.
        let result = unsafe {
            libc::fstatat(
                self.directory_handle.as_raw_fd(),
                name.as_ptr(),
                current.as_mut_ptr(),
                libc::AT_SYMLINK_NOFOLLOW,
            )
        };
        if result != 0 {
            return if std::io::Error::last_os_error().kind() == std::io::ErrorKind::NotFound {
                EntryOwnership::Absent
            } else {
                EntryOwnership::Unavailable
            };
        }
        // fstatat initialized current on success.
        let current = unsafe { current.assume_init() };
        if current.st_dev == owned.dev()
            && current.st_ino == owned.ino()
            && current.st_mode & libc::S_IFMT == libc::S_IFREG
        {
            EntryOwnership::Owned
        } else {
            EntryOwnership::Foreign
        }
    }
}

impl ImagePasteFile {
    pub(crate) fn recover_one(directory: PathBuf) -> Option<(Instant, Self)> {
        let directory_handle = fs::OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open(&directory)
            .ok()?;
        let dir = directory_handle.metadata().ok()?;
        if dir.uid() != unsafe { libc::geteuid() } || dir.mode() & 0o777 != 0o700 {
            return None;
        }
        let receipt_name = CString::new(".receipt").ok()?;
        let open_file = |name: &CStr| -> Option<File> {
            // No symlink or blocking special-file open is permitted during recovery.
            let fd = unsafe {
                libc::openat(
                    directory_handle.as_raw_fd(),
                    name.as_ptr(),
                    libc::O_RDONLY | libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK,
                )
            };
            if fd < 0 { None } else { Some(unsafe { File::from_raw_fd(fd) }) }
        };
        let receipt = open_file(&receipt_name)?;
        if !receipt.metadata().ok()?.is_file() || receipt.metadata().ok()?.len() > 1024 {
            return None;
        }
        let record: Receipt = serde_json::from_reader((&receipt).take(1025)).ok()?;
        if record.version != 2
            || record.directory_device != dir.dev()
            || record.directory_inode != dir.ino()
            || !["clipboard.png", "clipboard.jpg", "clipboard.gif", "clipboard.webp"]
                .contains(&record.name.as_str())
        {
            return None;
        }
        // An interrupted unlink may have left the image at its private
        // quarantine name. The same persistent token must authorize either entry.
        let (name, file) =
            [record.name.as_str(), ".cleanup-image"].into_iter().find_map(|name| {
                let name = CString::new(name).ok()?;
                let file = open_file(&name)?;
                let stat = file.metadata().ok()?;
                (stat.is_file()
                    && stat.dev() == record.file_device
                    && stat.ino() == record.file_inode
                    && stat.len() <= crate::image_paste::MAX_IMAGE_BYTES as u64
                    && crate::image_paste_ownership::ImagePasteOwnership::matches(
                        &file,
                        &record.ownership,
                    ))
                .then_some((name, file))
            })?;
        let now = SystemTime::now().duration_since(UNIX_EPOCH).ok()?.as_secs();
        let remaining = record.expires.saturating_sub(now).min(720);
        let deadline = Instant::now() + Duration::from_secs(remaining);
        Some((deadline, Self { directory, directory_handle, name, file, receipt, cleanup: false }))
    }

    pub(crate) fn directory(&self) -> &std::path::Path {
        &self.directory
    }

    #[cfg(test)]
    pub(crate) fn abandon_for_test(mut self) {
        // Model a crashed process: close descriptors without unlinking files.
        self.cleanup = false;
    }

    pub(crate) fn size(&self) -> usize {
        self.file.metadata().map_or(0, |m| m.len() as usize)
    }

    fn cleanup_entry(&self, name: &CStr, expected: &File) -> bool {
        if !self.entry_matches(name, expected) {
            return false;
        }
        let quarantine = CString::new(if name.to_bytes() == b".receipt" {
            ".cleanup-receipt"
        } else {
            ".cleanup-image"
        })
        .unwrap();
        let parent = self.directory_handle.as_raw_fd();
        // Move without clobbering, then check what actually moved. A replacement
        // between the initial check and rename is restored instead of deleted.
        if name == quarantine.as_c_str() || rename_noreplace(parent, name, &quarantine).is_ok() {
            if self.entry_matches(&quarantine, expected) {
                if unsafe { libc::unlinkat(parent, quarantine.as_ptr(), 0) } == 0 {
                    return true;
                }
                let _ = rename_noreplace(parent, &quarantine, name);
            } else {
                // If a newer file occupies the original name, preserve both.
                let _ = rename_noreplace(parent, &quarantine, name);
            }
        }
        false
    }
}

impl ImagePasteFile {
    pub(crate) fn remove_owned(&self) -> bool {
        // Retain the receipt on failure so a later recovery sweep can retry.
        let quarantine = CString::new(".cleanup-image").unwrap();
        match (
            self.entry_ownership(&self.name, &self.file),
            self.entry_ownership(&quarantine, &self.file),
        ) {
            (EntryOwnership::Owned, _) if self.cleanup_entry(&self.name, &self.file) => {}
            (_, EntryOwnership::Owned) if self.cleanup_entry(&quarantine, &self.file) => {}
            (EntryOwnership::Owned, _) | (_, EntryOwnership::Owned) => return false,
            (EntryOwnership::Unavailable, _) | (_, EntryOwnership::Unavailable) => return false,
            _ => (), // Ownership changed or the file is already gone; preserve replacements.
        }
        let _ = self.cleanup_entry(&CString::new(".receipt").unwrap(), &self.receipt);
        if self.directory_matches() {
            let _ = fs::remove_dir(&self.directory);
        }
        true
    }
}

impl Drop for ImagePasteFile {
    fn drop(&mut self) {
        if self.cleanup {
            let _ = self.remove_owned();
        }
    }
}

// Same descriptor-relative, no-replace primitive used by workspace file mutations.
#[cfg(any(target_os = "linux", target_os = "android"))]
fn rename_noreplace(parent: i32, source: &CStr, target: &CStr) -> std::io::Result<()> {
    // Both C strings and the directory descriptor remain live through this syscall.
    let result = unsafe {
        libc::syscall(
            libc::SYS_renameat2,
            parent,
            source.as_ptr(),
            parent,
            target.as_ptr(),
            libc::RENAME_NOREPLACE,
        )
    };
    if result == 0 { Ok(()) } else { Err(std::io::Error::last_os_error()) }
}

#[cfg(target_vendor = "apple")]
fn rename_noreplace(parent: i32, source: &CStr, target: &CStr) -> std::io::Result<()> {
    // Both C strings and the directory descriptor remain live through this syscall.
    let result = unsafe {
        libc::renameatx_np(parent, source.as_ptr(), parent, target.as_ptr(), libc::RENAME_EXCL)
    };
    if result == 0 { Ok(()) } else { Err(std::io::Error::last_os_error()) }
}

#[cfg(not(any(target_os = "linux", target_os = "android", target_vendor = "apple")))]
fn rename_noreplace(_parent: i32, _source: &CStr, _target: &CStr) -> std::io::Result<()> {
    Err(std::io::Error::other("safe image cleanup is unavailable"))
}

#[cfg(test)]
#[path = "image_paste_file_tests.rs"]
mod tests;
