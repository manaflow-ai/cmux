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
        conn.shm_attach_fd(this.seg, owned, false)?.check()?;
        Ok(this)
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::inject::tests::Xvfb;
    use x11rb::protocol::xproto::{
        ConnectionExt as _, CreateGCAux, ImageFormat, Rectangle, Window,
    };

    /// Paints the top-left `w`x`h` of `root` white (Xvfb's root starts black, the same as a
    /// fresh segment's zeros) and returns once the server has drawn it.
    fn paint_white(conn: &impl Connection, root: Window, (w, h): (u16, u16)) {
        let gc = conn.generate_id().unwrap();
        conn.create_gc(gc, root, &CreateGCAux::new().foreground(0xff_ff_ff)).unwrap();
        conn.poly_fill_rectangle(root, gc, &[Rectangle { x: 0, y: 0, width: w, height: h }])
            .unwrap();
        conn.get_input_focus().unwrap().reply().unwrap();
    }

    /// A `&[u8]` must not change while it is borrowed. A request naming the segment makes the
    /// X server write its pages, so no shared borrow of them may be alive while one runs.
    #[test]
    #[ignore = "needs Xvfb; run with --ignored on a Linux host"]
    fn the_server_never_writes_under_a_borrowed_slice() {
        let xvfb = Xvfb::start();
        let (conn, screen) = x11rb::connect(Some(&xvfb.display)).unwrap();
        let root = conn.setup().roots[screen].root;
        let (w, h) = (64u16, 64u16);
        paint_white(&conn, root, (w, h));
        let seg = ShmSeg::new(&conn, usize::from(w) * usize::from(h) * 4).unwrap();
        let held: &[u8] = seg.as_slice();
        let before = held.to_vec();
        // The reply means the server wrote the white rectangle into the pages.
        conn.shm_get_image(root, 0, 0, w, h, !0, ImageFormat::Z_PIXMAP.into(), seg.seg, 0)
            .unwrap()
            .reply()
            .unwrap();
        assert_eq!(held, &before[..], "the X server wrote the pages under a live &[u8]");
    }
}
