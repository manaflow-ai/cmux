//! Private, inode-checked temporary files. No caller-supplied path is accepted.

use std::ffi::{CStr, CString};
use std::fs::{self, File};
use std::io::{Read, Seek, SeekFrom, Write};
use std::os::fd::{AsRawFd, FromRawFd};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

/// Wall-clock seconds since the Unix epoch, the unit a receipt records its
/// expiry in. Every daemon sharing the per-UID storage compares receipts with
/// the same clock; tests drive a manual one so twelve-minute windows run
/// without sleeping.
#[derive(Clone, Default)]
pub(crate) struct WallClock(Option<Arc<AtomicU64>>);

impl WallClock {
    pub(crate) fn now(&self) -> u64 {
        match &self.0 {
            Some(manual) => manual.load(Ordering::SeqCst),
            None => SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_secs(),
        }
    }

    #[cfg(test)]
    pub(crate) fn manual(start: u64) -> Self {
        Self(Some(Arc::new(AtomicU64::new(start))))
    }

    #[cfg(test)]
    pub(crate) fn advance(&self, seconds: u64) {
        if let Some(manual) = &self.0 {
            manual.fetch_add(seconds, Ordering::SeqCst);
        }
    }
}

#[derive(Clone, serde::Serialize, serde::Deserialize)]
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
    record: Receipt,
    cleanup: bool,
}

/// Where a new receipt is written and synced before it is renamed over
/// `.receipt`; only a crash between the two can leave it behind.
const NEXT_RECEIPT: &CStr = c".receipt-next";

impl ImagePasteFile {
    #[cfg(test)]
    pub(crate) fn create(extension: &str) -> std::io::Result<Self> {
        Self::create_in(
            &crate::image_paste_storage::ImagePasteStorage::open()?,
            extension,
            WallClock::default().now() + 720,
        )
    }

    /// Creates the private file and its durable receipt, which lets a
    /// recovery sweep in any daemon remove the file after `expires`.
    pub(crate) fn create_in(
        storage: &crate::image_paste_storage::ImagePasteStorage,
        extension: &str,
        expires: u64,
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
            // The live lease: held while this daemon owns the upload, released
            // by the kernel when it exits or crashes. No sweep in any daemon
            // removes a file it cannot lock, whatever its receipt says.
            if !try_lock(&file) {
                unsafe {
                    libc::unlinkat(directory_handle.as_raw_fd(), name.as_ptr(), 0);
                }
                return Err(std::io::Error::other("temporary image lock unavailable"));
            }
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
            let mut ownership = [0u8; 16];
            getrandom::fill(&mut ownership)
                .map_err(|_| std::io::Error::other("image ownership randomness unavailable"))?;
            let record = Receipt {
                version: 2,
                ownership,
                directory_device: directory_metadata.dev(),
                directory_inode: directory_metadata.ino(),
                file_device: file_metadata.dev(),
                file_inode: file_metadata.ino(),
                name: name.to_str().unwrap().to_owned(),
                expires,
            };
            let mut owned = Self {
                directory: directory.clone(),
                directory_handle,
                name,
                file,
                receipt,
                record,
                cleanup: true,
            };
            crate::image_paste_ownership::ImagePasteOwnership::mark(&owned.file, &ownership)?;
            serde_json::to_writer(&mut owned.receipt, &owned.record)?;
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

    /// Moves the durable expiry a recovery sweep in any daemon honours. The
    /// new receipt is written and synced under a private name, then renamed
    /// over `.receipt`, so a sweep reads the old receipt or the new one and
    /// never a torn one. Only the small receipt is rewritten, never image bytes.
    pub(crate) fn set_expiry(&mut self, expires: u64) -> std::io::Result<()> {
        let (receipt_name, next_name) = (c".receipt", NEXT_RECEIPT);
        if !self.entry_matches(receipt_name, &self.receipt) {
            return Err(std::io::Error::other("temporary image receipt was replaced"));
        }
        if !self.remove_next_receipt() {
            return Err(std::io::Error::other("stale image receipt cannot be removed"));
        }
        let parent = self.directory_handle.as_raw_fd();
        // The directory descriptor pins this private directory; O_EXCL and
        // O_NOFOLLOW refuse any entry that appeared at the private name.
        let fd = unsafe {
            libc::openat(
                parent,
                next_name.as_ptr(),
                libc::O_RDWR | libc::O_CREAT | libc::O_EXCL | libc::O_NOFOLLOW | libc::O_CLOEXEC,
                0o600,
            )
        };
        if fd < 0 {
            return Err(std::io::Error::last_os_error());
        }
        // openat returned a new descriptor owned only by this File.
        let mut next = unsafe { File::from_raw_fd(fd) };
        let record = Receipt { expires, ..self.record.clone() };
        let written = serde_json::to_writer(&mut next, &record)
            .map_err(std::io::Error::from)
            .and_then(|()| next.sync_all());
        if let Err(error) = written {
            let _ = self.cleanup_entry(next_name, &next);
            return Err(error);
        }
        // Both names are single components of the pinned directory.
        if unsafe { libc::renameat(parent, next_name.as_ptr(), parent, receipt_name.as_ptr()) } != 0
        {
            let error = std::io::Error::last_os_error();
            let _ = self.cleanup_entry(next_name, &next);
            return Err(error);
        }
        self.receipt = next;
        self.record = record;
        self.directory_handle.sync_all()
    }

    /// Removes a receipt a crash left at its private write name, but only one
    /// that carries this file's ownership token. True when none remains.
    fn remove_next_receipt(&self) -> bool {
        let name = NEXT_RECEIPT;
        // No symlink or blocking special-file open is permitted.
        let fd = unsafe {
            libc::openat(
                self.directory_handle.as_raw_fd(),
                name.as_ptr(),
                libc::O_RDONLY | libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK,
            )
        };
        if fd < 0 {
            return std::io::Error::last_os_error().kind() == std::io::ErrorKind::NotFound;
        }
        // openat returned a new, owned descriptor.
        let file = unsafe { File::from_raw_fd(fd) };
        let owned = file.metadata().is_ok_and(|stat| stat.is_file() && stat.len() <= 1024)
            && serde_json::from_reader::<_, Receipt>((&file).take(1025))
                .is_ok_and(|record| record.ownership == self.record.ownership);
        owned && self.cleanup_entry(name, &file)
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
        // Darwin's dev_t is signed 32-bit; MetadataExt exposes it as u64.
        #[cfg(target_vendor = "apple")]
        let current_device = current.st_dev as u64;
        #[cfg(not(target_vendor = "apple"))]
        let current_device = current.st_dev;
        if current_device == owned.dev()
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
    pub(crate) fn recover_one(directory: PathBuf, now: u64) -> Option<(Instant, Self)> {
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
                    && crate::image_paste_ownership::ImagePasteOwnership::matches(
                        &file,
                        &record.ownership,
                    ))
                .then_some((name, file))
            })?;
        let remaining = record.expires.saturating_sub(now).min(720);
        let deadline = Instant::now() + Duration::from_secs(remaining);
        Some((
            deadline,
            Self { directory, directory_handle, name, file, receipt, record, cleanup: false },
        ))
    }

    pub(crate) fn directory(&self) -> &std::path::Path {
        &self.directory
    }

    #[cfg(test)]
    pub(crate) fn abandon_for_test(mut self) {
        // Model a crashed process: close descriptors without unlinking files.
        self.cleanup = false;
    }

    fn cleanup_entry(&self, name: &CStr, expected: &File) -> bool {
        if !self.entry_matches(name, expected) {
            return false;
        }
        let quarantine = CString::new(match name.to_bytes() {
            b".receipt" => ".cleanup-receipt",
            b".receipt-next" => ".cleanup-receipt-next",
            _ => ".cleanup-image",
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

/// Takes the file's exclusive advisory lock without waiting. A daemon holds it
/// on every upload it owns (from creation until the upload is dropped); the
/// kernel releases it when that daemon's descriptor closes, a crash included.
fn try_lock(file: &File) -> bool {
    // The descriptor is live for the duration of this call.
    unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) == 0 }
}

impl ImagePasteFile {
    /// Claims a recovered file for removal. False while another daemon (or
    /// another handle) still owns the upload, so a sweep never removes a live
    /// upload even when its receipt reads as expired: a stale handle, a wall
    /// clock stepped forward or back, or a receipt refresh racing the sweep.
    /// Taking the lock also keeps the owner from coming back while this
    /// handle removes the file, since only the creator ever holds it.
    pub(crate) fn claim_for_removal(&self) -> bool {
        try_lock(&self.file)
    }

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
        let _ = self.remove_next_receipt();
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
