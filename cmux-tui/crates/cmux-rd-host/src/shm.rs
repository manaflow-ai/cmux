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
mod tests {
    use super::*;
    use crate::inject::tests::Xvfb;
    use x11rb::protocol::xproto::{ConnectionExt as _, CreateGCAux, Rectangle, Window};

    /// Paints the top-left `w`x`h` of `root` white (Xvfb's root starts black, the same as a
    /// fresh segment's zeros) and returns once the server has drawn it.
    fn paint_white(conn: &impl Connection, root: Window, (w, h): (u16, u16)) {
        let gc = conn.generate_id().unwrap();
        conn.create_gc(gc, root, &CreateGCAux::new().foreground(0xff_ff_ff)).unwrap();
        conn.poly_fill_rectangle(root, gc, &[Rectangle { x: 0, y: 0, width: w, height: h }])
            .unwrap();
        conn.get_input_focus().unwrap().reply().unwrap();
    }

    fn all_pixels(bytes: &[u8], bgr: [u8; 3]) -> bool {
        bytes.chunks_exact(4).all(|px| px[..3] == bgr)
    }

    /// What `get_image` returns is what the server wrote, after it wrote it.
    #[test]
    #[ignore = "needs Xvfb; run with --ignored on a Linux host"]
    fn get_image_returns_what_the_server_wrote() {
        let xvfb = Xvfb::start();
        let (conn, screen) = x11rb::connect(Some(&xvfb.display)).unwrap();
        let root = conn.setup().roots[screen].root;
        paint_white(&conn, root, (64, 64));
        let mut seg = ShmSeg::new(&conn, 64 * 64 * 4, ServerAccess::ReadWrite).unwrap();
        let pixels = seg.get_image(&conn, root, (0, 0), (64, 64)).unwrap();
        assert_eq!(pixels.len(), 64 * 64 * 4);
        assert!(all_pixels(pixels, [0xff; 3]), "the white rectangle did not come back");
        assert!(seg.get_image(&conn, root, (0, 0), (65, 64)).is_err(), "past the segment");
    }

    /// A segment that is only put from is read-only to the server: a request that would
    /// write it is refused, so its pages change only through `pixels_mut`. Putting from it
    /// still works.
    #[test]
    #[ignore = "needs Xvfb; run with --ignored on a Linux host"]
    fn a_read_only_segment_is_never_written_by_the_server() {
        let xvfb = Xvfb::start();
        let (conn, screen) = x11rb::connect(Some(&xvfb.display)).unwrap();
        let root = conn.setup().roots[screen].root;
        paint_white(&conn, root, (64, 64));
        let mut seg = ShmSeg::new(&conn, 64 * 64 * 4, ServerAccess::Read).unwrap();
        let refused = conn
            .shm_get_image(root, 0, 0, 64, 64, !0, ImageFormat::Z_PIXMAP.into(), seg.seg, 0)
            .unwrap()
            .reply();
        assert!(refused.is_err(), "the server wrote a read-only segment");
        assert!(seg.pixels_mut().iter().all(|&b| b == 0), "its pages changed");
        // Red (BGRX) put from it reaches the root.
        for px in seg.pixels_mut().chunks_exact_mut(4) {
            px.copy_from_slice(&[0, 0, 0xff, 0]);
        }
        let gc = conn.generate_id().unwrap();
        conn.create_gc(gc, root, &CreateGCAux::new()).unwrap();
        seg.put_image(&conn, root, gc, (64, 64), 24).unwrap();
        let mut back = ShmSeg::new(&conn, 64 * 64 * 4, ServerAccess::ReadWrite).unwrap();
        let pixels = back.get_image(&conn, root, (0, 0), (64, 64)).unwrap();
        assert!(all_pixels(pixels, [0, 0, 0xff]), "the put did not reach the root");
    }
}
