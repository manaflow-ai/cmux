//! MIT-SHM segments backed by memfd (SHM 1.2 AttachFd), shared with the local X server.
//!
//! The X server reads or writes a segment's pages only while it serves a request that names
//! the segment. The segment id is private, every such request goes through a `&mut self`
//! method here, and each method waits for the server's answer before it returns. So no
//! request is in flight while a `&[u8]` or `&mut [u8]` over the pages is alive, and the two
//! never touch the pages at the same time. A segment that is only put from is attached
//! read-only, so the server refuses any request that would write it.

use crate::Res;
use std::os::fd::{FromRawFd, OwnedFd};
use x11rb::connection::Connection;
use x11rb::protocol::shm::ConnectionExt as _;
use x11rb::protocol::xproto::{Drawable, Gcontext, ImageFormat};

/// What the X server may do with a segment's pages.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ServerAccess {
    /// Read them (`ShmPutImage`); a request that writes them fails with `BadAccess`.
    Read,
    /// Read and write them (`ShmGetImage` too).
    ReadWrite,
}

pub struct ShmSeg {
    seg: u32,
    ptr: *mut u8,
    len: usize,
}

// SAFETY: the mapping is owned by this value and only accessed through &self/&mut self.
unsafe impl Send for ShmSeg {}

impl ShmSeg {
    pub fn new(conn: &impl Connection, len: usize, access: ServerAccess) -> Res<Self> {
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
            libc::mmap(
                std::ptr::null_mut(),
                len,
                libc::PROT_READ | libc::PROT_WRITE,
                libc::MAP_SHARED,
                fd,
                0,
            )
        };
        if ptr == libc::MAP_FAILED {
            return Err(std::io::Error::last_os_error().into());
        }
        // Owned from here, so a refused attach below unmaps it on drop.
        let mut this = Self { seg: 0, ptr: ptr.cast(), len };
        this.seg = conn.generate_id()?;
        // attach_fd takes ownership of the descriptor; the mapping stays valid after close.
        conn.shm_attach_fd(this.seg, owned, access == ServerAccess::Read)?.check()?;
        Ok(this)
    }

    /// The pages, to fill before [`put_image`](Self::put_image).
    pub fn pixels_mut(&mut self) -> &mut [u8] {
        // SAFETY: ptr/len describe a live mapping owned by self, and no request on the segment
        // is in flight (module doc), so nothing else touches it while this borrow lives.
        unsafe { std::slice::from_raw_parts_mut(self.ptr, self.len) }
    }

    /// `ShmGetImage` of the `w`x`h` rectangle at `x`,`y` of `drawable` (Z pixmap, 32 bits a
    /// pixel), into the segment from offset 0. Returns its `w * h * 4` bytes once the server
    /// has written them and answered.
    pub fn get_image(
        &mut self,
        conn: &impl Connection,
        drawable: Drawable,
        (x, y): (i16, i16),
        (w, h): (u16, u16),
    ) -> Res<&[u8]> {
        let len = usize::from(w) * usize::from(h) * 4;
        if len > self.len {
            return Err(format!("{w}x{h} needs {len} bytes; the segment has {}", self.len).into());
        }
        let fmt = ImageFormat::Z_PIXMAP.into();
        conn.shm_get_image(drawable, x, y, w, h, !0, fmt, self.seg, 0)?.reply()?;
        // SAFETY: as in `pixels_mut`; the reply means the server is done writing.
        Ok(unsafe { std::slice::from_raw_parts(self.ptr, len) })
    }

    /// `ShmPutImage` of the segment's first `w * h` pixels (Z pixmap, `depth`) to `drawable`
    /// at 0,0. Returns once the server has read them: a checked round trip, which also brings
    /// an X error from the put back here instead of the event queue.
    pub fn put_image(
        &mut self,
        conn: &impl Connection,
        drawable: Drawable,
        gc: Gcontext,
        (w, h): (u16, u16),
        depth: u8,
    ) -> Res<()> {
        let len = usize::from(w) * usize::from(h) * 4;
        if len > self.len {
            return Err(format!("{w}x{h} needs {len} bytes; the segment has {}", self.len).into());
        }
        let fmt = ImageFormat::Z_PIXMAP.into();
        conn.shm_put_image(drawable, gc, w, h, 0, 0, w, h, 0, 0, depth, fmt, false, self.seg, 0)?
            .check()?;
        Ok(())
    }
}

impl Drop for ShmSeg {
    fn drop(&mut self) {
        // SAFETY: unmapping our own mapping once.
        unsafe { libc::munmap(self.ptr.cast(), self.len) };
    }
}

#[cfg(test)]
#[path = "shm_tests.rs"]
mod tests;
