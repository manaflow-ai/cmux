//! Shared memory the worker and the daemon both map: a descriptor-backed
//! segment (`memfd` on Linux, an unlinked POSIX `shm_open` object
//! elsewhere, as `cmux_holder::ring` makes ring segments) and a mapping of
//! it whose 8-byte words both processes reach only atomically.

use std::io;
use std::os::fd::{AsRawFd, BorrowedFd, FromRawFd, OwnedFd};
use std::ptr::NonNull;
use std::sync::atomic::AtomicU64;

/// A shared mapping of a segment, unmapped on drop.
#[derive(Debug)]
pub(crate) struct Mapping {
    ptr: NonNull<u8>,
    len: usize,
}

// SAFETY: the mapping is owned by this value; every access goes through
// atomics or through `&mut self`, so moving it between threads is sound.
unsafe impl Send for Mapping {}

impl Mapping {
    /// Map `len` bytes of `fd` shared: read-only unless `writable`.
    pub(crate) fn map(fd: BorrowedFd<'_>, len: usize, writable: bool) -> io::Result<Self> {
        if len == 0 {
            return Err(io::Error::new(io::ErrorKind::InvalidInput, "an empty mapping"));
        }
        let prot = if writable { libc::PROT_READ | libc::PROT_WRITE } else { libc::PROT_READ };
        // SAFETY: maps `len` bytes of a live descriptor; the result is checked.
        let map = unsafe {
            libc::mmap(std::ptr::null_mut(), len, prot, libc::MAP_SHARED, fd.as_raw_fd(), 0)
        };
        if map == libc::MAP_FAILED {
            return Err(io::Error::last_os_error());
        }
        NonNull::new(map.cast::<u8>())
            .map(|ptr| Self { ptr, len })
            .ok_or_else(|| io::Error::other("mmap returned null"))
    }

    pub(crate) fn len(&self) -> usize {
        self.len
    }

    /// The aligned word at byte `offset`, if all of it is inside the mapping.
    pub(crate) fn word(&self, offset: usize) -> Option<&AtomicU64> {
        if !offset.is_multiple_of(8) || offset.checked_add(8)? > self.len {
            return None;
        }
        // SAFETY: the mapping is page aligned and `offset` is a multiple of 8,
        // so the word is aligned; it is inside the live mapping, and both
        // processes reach the words of a shared segment only atomically.
        Some(unsafe { &*self.ptr.as_ptr().add(offset).cast::<AtomicU64>() })
    }

    /// Copy `out.len()` bytes from byte `offset` (checked against the
    /// mapping). The writer may store into them meanwhile: the caller
    /// validates the copy afterwards (copy, then validate), never the
    /// mapping in place.
    pub(crate) fn copy_out(&self, offset: usize, out: &mut [u8]) -> bool {
        let Some(end) = offset.checked_add(out.len()) else { return false };
        if end > self.len {
            return false;
        }
        // SAFETY: `offset..end` is inside the live mapping and `out` is a
        // distinct local buffer. A writer in another process may change
        // these bytes meanwhile: the caller discards any copy its validation
        // finds overwritten.
        unsafe {
            std::ptr::copy_nonoverlapping(
                self.ptr.as_ptr().add(offset),
                out.as_mut_ptr(),
                out.len(),
            );
        }
        true
    }
}

impl Drop for Mapping {
    fn drop(&mut self) {
        // SAFETY: unmaps the mapping this value made.
        unsafe { libc::munmap(self.ptr.as_ptr().cast(), self.len) };
    }
}

/// A new shared segment of `len` bytes (zeroed), close-on-exec.
pub(crate) fn create_segment(len: usize) -> io::Result<OwnedFd> {
    let segment = new_segment()?;
    let size = libc::off_t::try_from(len)
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "segment too large"))?;
    // SAFETY: sizes a descriptor this function owns.
    if unsafe { libc::ftruncate(segment.as_raw_fd(), size) } != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(segment)
}

#[cfg(target_os = "linux")]
fn new_segment() -> io::Result<OwnedFd> {
    // SAFETY: memfd_create returns a new descriptor or -1.
    let fd = unsafe { libc::memfd_create(c"cmux-vt-page".as_ptr(), libc::MFD_CLOEXEC) };
    if fd < 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: a fresh descriptor this function owns.
    Ok(unsafe { OwnedFd::from_raw_fd(fd) })
}

/// An unlinked POSIX shared memory object: only descriptors reach it.
#[cfg(not(target_os = "linux"))]
fn new_segment() -> io::Result<OwnedFd> {
    use std::sync::atomic::{AtomicU32, Ordering};
    static NEXT: AtomicU32 = AtomicU32::new(0);
    for _ in 0..16 {
        // At most 31 bytes on macOS (PSHMNAMLEN).
        let name =
            format!("/cmvp{:x}.{:x}", std::process::id(), NEXT.fetch_add(1, Ordering::Relaxed));
        let name = std::ffi::CString::new(name)
            .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "page segment name"))?;
        // SAFETY: shm_open with a NUL-terminated name; the mode is variadic.
        let fd = unsafe {
            libc::shm_open(
                name.as_ptr(),
                libc::O_RDWR | libc::O_CREAT | libc::O_EXCL | libc::O_CLOEXEC,
                0o600 as libc::c_uint,
            )
        };
        if fd < 0 {
            let error = io::Error::last_os_error();
            if error.kind() == io::ErrorKind::AlreadyExists {
                continue;
            }
            return Err(error);
        }
        // SAFETY: removes the name just made; the descriptor keeps the object.
        unsafe { libc::shm_unlink(name.as_ptr()) };
        // SAFETY: a fresh descriptor this function owns.
        return Ok(unsafe { OwnedFd::from_raw_fd(fd) });
    }
    Err(io::Error::new(io::ErrorKind::AlreadyExists, "no free page segment name"))
}
