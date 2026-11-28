//! MIT-SHM segments backed by memfd (SHM 1.2 AttachFd), shared with the local X server.

use crate::Res;
use std::os::fd::{FromRawFd, OwnedFd};
use x11rb::connection::Connection;
use x11rb::protocol::shm::ConnectionExt as _;

pub struct ShmSeg {
    pub seg: u32,
    ptr: *mut u8,
    len: usize,
}

// SAFETY: the mapping is owned by this value and only accessed through &self/&mut self.
unsafe impl Send for ShmSeg {}

impl ShmSeg {
    pub fn new(conn: &impl Connection, len: usize) -> Res<Self> {
        conn.shm_query_version()?.reply()?;
        // SAFETY: plain libc calls with checked return values.
        let fd = unsafe { libc::memfd_create(c"rdhost-shm".as_ptr(), libc::MFD_CLOEXEC) };
        if fd < 0 {
            return Err(std::io::Error::last_os_error().into());
        }
        // SAFETY: fd is a fresh descriptor we own.
        let owned = unsafe { OwnedFd::from_raw_fd(fd) };
        if unsafe { libc::ftruncate(fd, len as libc::off_t) } != 0 {
            return Err(std::io::Error::last_os_error().into());
        }
        let ptr = unsafe {
            libc::mmap(std::ptr::null_mut(), len, libc::PROT_READ | libc::PROT_WRITE, libc::MAP_SHARED, fd, 0)
        };
        if ptr == libc::MAP_FAILED {
            return Err(std::io::Error::last_os_error().into());
        }
        let seg = conn.generate_id()?;
        // attach_fd takes ownership of the descriptor; the mapping stays valid after close.
        conn.shm_attach_fd(seg, owned, false)?.check()?;
        Ok(Self { seg, ptr: ptr.cast(), len })
    }

    pub fn as_slice(&self) -> &[u8] {
        // SAFETY: ptr/len describe a live mapping owned by self.
        unsafe { std::slice::from_raw_parts(self.ptr, self.len) }
    }

    pub fn as_mut_slice(&mut self) -> &mut [u8] {
        // SAFETY: as above, with unique access through &mut self.
        unsafe { std::slice::from_raw_parts_mut(self.ptr, self.len) }
    }
}

impl Drop for ShmSeg {
    fn drop(&mut self) {
        // SAFETY: unmapping our own mapping once.
        unsafe { libc::munmap(self.ptr.cast(), self.len) };
    }
}
