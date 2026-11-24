//! `cmux-rd bench --present :N` (Linux): draws every decoded frame into a window on an X display,
//! the way a viewer app shows the stream, so a screen capture of that display measures the whole
//! path to the viewer's screen (glass to glass), not only to the decoder.
//!
//! The window is override-redirect at (0,0), the size of the stream (no scaling), so it needs no
//! window manager. Each frame is converted from I420 to BGRX with the matrix and range its SPS
//! tags (`cmux_encode::color`; untagged means BT.601 video range) in a MIT-SHM segment and put with `ShmPutImage`; a round trip then waits until the X
//! server has copied it, so the frame is on the display when `show` returns and the segment can be
//! reused.
//!
//! Like a viewer app, the window takes the keyboard focus and hands every key press and release on
//! it back to the bench (`take_keys`), which sends them to the host, so a key typed on the viewer
//! display reaches the host's screen the way a person's does in the app.

use crate::shm::{ServerAccess, ShmSeg};
use crate::Res;
use cmux_encode::color::Yuv;
use openh264::formats::YUVSource;
use x11rb::connection::Connection;
use x11rb::protocol::xproto::{
    ConnectionExt as _, CreateGCAux, CreateWindowAux, EventMask, InputFocus, Window, WindowClass,
};
use x11rb::protocol::Event;
use x11rb::rust_connection::RustConnection;
use x11rb::wrapper::ConnectionExt as _;
use x11rb::CURRENT_TIME;

pub struct Presenter {
    conn: RustConnection,
    root: Window,
    root_visual: u32,
    window: Option<(Window, u32)>,
    shm: Option<ShmSeg>,
    size: (usize, usize),
}

impl Presenter {
    pub fn open(display: &str) -> Res<Self> {
        let (conn, screen_num) = x11rb::connect(Some(display))?;
        let screen = conn.setup().roots[screen_num].clone();
        if screen.root_depth != 24 {
            return Err(format!(
                "--present: root depth {} unsupported (need 24)",
                screen.root_depth
            )
            .into());
        }
        Ok(Self {
            conn,
            root: screen.root,
            root_visual: screen.root_visual,
            window: None,
            shm: None,
            size: (0, 0),
        })
    }

    /// (Re)creates the window and the segment for a stream of `w` x `h`.
    fn resize(&mut self, w: usize, h: usize) -> Res<()> {
        if let Some((win, gc)) = self.window.take() {
            self.conn.free_gc(gc)?;
            self.conn.destroy_window(win)?;
        }
        self.shm = None;
        let win = self.conn.generate_id()?;
        self.conn.create_window(
            24,
            win,
            self.root,
            0,
            0,
            w as u16,
            h as u16,
            0,
            WindowClass::INPUT_OUTPUT,
            self.root_visual,
            &CreateWindowAux::new()
                .override_redirect(1u32)
                .background_pixel(0)
                .event_mask(EventMask::KEY_PRESS | EventMask::KEY_RELEASE),
        )?;
        self.conn.map_window(win)?;
        // Override-redirect: no window manager gives it the focus, so it takes it, as an app's
        // focused viewer window has it.
        self.conn.set_input_focus(InputFocus::PARENT, win, CURRENT_TIME)?;
        let gc = self.conn.generate_id()?;
        self.conn.create_gc(gc, win, &CreateGCAux::new())?;
        // Kept before the segment: a failed segment must not make every later frame make a new window.
        self.window = Some((win, gc));
        self.size = (w, h);
        self.shm = Some(ShmSeg::new(&self.conn, w * h * 4, ServerAccess::Read)?);
        self.conn.sync()?;
        Ok(())
    }

    /// The X connection's socket, readable when a key event may be waiting.
    pub fn fd(&self) -> std::os::fd::RawFd {
        use std::os::fd::AsRawFd;
        self.conn.stream().as_raw_fd()
    }

    /// Key presses and releases on the window since the last call: (X keycode, down), in order.
    pub fn take_keys(&mut self) -> Res<Vec<(u8, bool)>> {
        let mut keys = Vec::new();
        while let Some(event) = self.conn.poll_for_event()? {
            match event {
                Event::KeyPress(e) => keys.push((e.detail, true)),
                Event::KeyRelease(e) => keys.push((e.detail, false)),
                _ => {}
            }
        }
        Ok(keys)
    }

    /// Shows one decoded picture and returns once the X server has it.
    /// `color`: the conversion the stream's SPS asks for (`cmux_encode::color::sps_vui`).
    pub fn show(&mut self, yuv: &impl YUVSource, color: Yuv) -> Res<()> {
        let (w, h) = yuv.dimensions();
        if (w, h) != self.size || self.window.is_none() {
            self.resize(w, h)?;
        }
        let (Some((win, gc)), Some(shm)) = (self.window, self.shm.as_mut()) else {
            return Err("--present: no shared memory segment for the window".into());
        };
        i420_to_bgrx(yuv, color, shm.pixels_mut(), w, h);
        // Returns once the server has copied the segment into the window.
        shm.put_image(&self.conn, win, gc, (w as u16, h as u16), 24)
    }
}

/// The decoded picture to BGRX with the stream's own matrix and range.
fn i420_to_bgrx(yuv: &impl YUVSource, color: Yuv, out: &mut [u8], w: usize, h: usize) {
    cmux_encode::color::i420_to_bgrx(yuv.y(), yuv.u(), yuv.v(), yuv.strides(), w, h, color, out);
}
