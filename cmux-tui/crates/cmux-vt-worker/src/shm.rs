//! Shared memory the worker and the daemon both map: a descriptor-backed
//! segment (`memfd` on Linux, an unlinked POSIX `shm_open` object
//! elsewhere, as `cmux_holder::ring` makes ring segments) and a mapping of
//! it whose 8-byte words both processes reach only atomically.

use std::io;
use std::os::fd::{AsFd, AsRawFd, BorrowedFd, FromRawFd, OwnedFd};
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

    /// Copy `bytes` in at byte `offset` (checked against the mapping); for
    /// a segment only this process maps yet.
    pub(crate) fn write_at(&mut self, offset: usize, bytes: &[u8]) -> bool {
        let Some(end) = offset.checked_add(bytes.len()) else { return false };
        if end > self.len {
            return false;
        }
        // SAFETY: `offset..end` is inside the live mapping, `bytes` is a
        // distinct buffer, and `&mut self` is the only reference to it here.
        unsafe {
            std::ptr::copy_nonoverlapping(
                bytes.as_ptr(),
                self.ptr.as_ptr().add(offset),
                bytes.len(),
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

/// A new shared segment of `len` bytes (zeroed), close-on-exec, whose size
/// no holder of a descriptor to it can change: a worker that shrank a page
/// the daemon maps would make the daemon's next read fault (SIGBUS).
pub(crate) fn create_segment(len: usize) -> io::Result<OwnedFd> {
    let segment = new_segment()?;
    let size = libc::off_t::try_from(len)
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "segment too large"))?;
    // SAFETY: sizes a descriptor this function owns.
    if unsafe { libc::ftruncate(segment.as_raw_fd(), size) } != 0 {
        return Err(io::Error::last_os_error());
    }
    seal_size(&segment)?;
    Ok(segment)
}

/// A shared segment holding a copy of `bytes` (at least one byte).
pub(crate) fn segment_with(bytes: &[u8]) -> io::Result<OwnedFd> {
    let segment = create_segment(bytes.len())?;
    let mut map = Mapping::map(segment.as_fd(), bytes.len(), true)?;
    if !map.write_at(0, bytes) {
        return Err(io::Error::other("segment shorter than its bytes"));
    }
    Ok(segment)
}

/// Seal the memfd's size for good (`F_SEAL_SHRINK | F_SEAL_GROW`, then
/// `F_SEAL_SEAL` so no seal can be added or removed later). Writes stay
/// allowed: the worker writes its pages.
#[cfg(target_os = "linux")]
fn seal_size(segment: &OwnedFd) -> io::Result<()> {
    let seals = libc::F_SEAL_SHRINK | libc::F_SEAL_GROW | libc::F_SEAL_SEAL;
    // SAFETY: fcntl on a descriptor this function's caller owns; no pointers.
    if unsafe { libc::fcntl(segment.as_raw_fd(), libc::F_ADD_SEALS, seals) } != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

/// A sized POSIX shared memory object cannot be resized on macOS (a second
/// `ftruncate` fails with EINVAL), so there is nothing to seal.
#[cfg(not(target_os = "linux"))]
fn seal_size(_segment: &OwnedFd) -> io::Result<()> {
    Ok(())
}

#[cfg(target_os = "linux")]
fn new_segment() -> io::Result<OwnedFd> {
    // SAFETY: memfd_create returns a new descriptor or -1.
    let fd = unsafe {
        libc::memfd_create(c"cmux-vt-page".as_ptr(), libc::MFD_CLOEXEC | libc::MFD_ALLOW_SEALING)
    };
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

#[cfg(test)]
mod tests {
    use super::*;

    fn size(fd: &OwnedFd) -> i64 {
        // SAFETY: fstat on a live descriptor into a zeroed local.
        let mut stat: libc::stat = unsafe { std::mem::zeroed() };
        // SAFETY: as above.
        assert_eq!(unsafe { libc::fstat(fd.as_raw_fd(), &mut stat) }, 0);
        stat.st_size as i64
    }

    /// A worker holds a writable descriptor to its page; shrinking or
    /// growing the page through it must fail, or the daemon's next read of
    /// its mapping would fault past the end of the file.
    #[test]
    fn a_page_holder_cannot_resize_the_segment() {
        let segment = create_segment(8192).expect("segment");
        let workers = segment.try_clone().expect("the worker's descriptor");
        for len in [0, 4096, 1 << 20] {
            // SAFETY: ftruncate on a live descriptor; no pointers.
            let resized = unsafe { libc::ftruncate(workers.as_raw_fd(), len) };
            assert_ne!(resized, 0, "ftruncate to {len} must fail");
        }
        assert_eq!(size(&segment), 8192);
        #[cfg(target_os = "linux")]
        {
            // SAFETY: fcntl reads the seals; no pointers.
            let seals = unsafe { libc::fcntl(workers.as_raw_fd(), libc::F_GET_SEALS) };
            let want = libc::F_SEAL_SHRINK | libc::F_SEAL_GROW | libc::F_SEAL_SEAL;
            assert_eq!(seals & want, want);
            // SAFETY: as above; F_SEAL_SEAL refuses any new seal.
            let added = unsafe { libc::fcntl(workers.as_raw_fd(), libc::F_ADD_SEALS, 0) };
            assert_ne!(added, 0);
        }
    }

    #[test]
    fn a_segment_with_bytes_maps_them_back() {
        let segment = segment_with(b"kitty image bytes").expect("segment");
        let map = Mapping::map(segment.as_fd(), 17, false).expect("map");
        let mut out = [0u8; 17];
        assert!(map.copy_out(0, &mut out));
        assert_eq!(&out, b"kitty image bytes");
    }
}
