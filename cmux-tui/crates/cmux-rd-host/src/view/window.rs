//! The viewer's window (X11): presents the newest decoded picture at most once per display
//! refresh (the Present extension's MSC notifications; without it, as soon as one arrives), and
//! turns the person's keyboard, pointer and scroll in the window into `cmux.rd/1` input events.
//!
//! The window shows the stream 1:1 at (0, 0): the offer asked the host for a stream no wider
//! than this screen, so a pointer position in the window is a position in the stream's pixels,
//! which is what `InputEvent::Pointer` carries. Each picture is converted from I420 to BGRX with
//! the matrix and range its stream's SPS tags (the Mac host: BT.709, video range) in a MIT-SHM
//! segment and put with `ShmPutImage`.

use super::stream::{Picture, SharedMailbox, Waker};
use crate::clock::now_ns;
use crate::fdwait::wait_readable;
use crate::shm::{ServerAccess, ShmSeg};
use crate::Res;
use cmux_encode::color::Yuv;
use cmux_encode::I420;
use cmux_rd_proto::InputEvent;
use std::collections::BTreeSet;
use std::os::fd::AsRawFd;
use std::sync::mpsc;
use x11rb::connection::{Connection, RequestConnection};
use x11rb::properties::WmSizeHints;
use x11rb::protocol::present::{self, ConnectionExt as _};
use x11rb::protocol::xproto::{
    AtomEnum, ConfigureWindowAux, ConnectionExt as _, CreateGCAux, CreateWindowAux, EventMask,
    PropMode, WindowClass,
};
use x11rb::protocol::Event;
use x11rb::rust_connection::RustConnection;
use x11rb::wrapper::ConnectionExt as _;

/// Waiting this long for a refresh notification arms the next present anyway (a window on no
/// output may get none).
const PACE_GIVE_UP_NS: u64 = 50_000_000;
/// A key press counts toward key-to-presented only if a frame shows within this time.
const KEY_SAMPLE_LIMIT_NS: u64 = 2_000_000_000;

/// The size of `display`'s first screen, in pixels.
pub fn screen_size(display: &str) -> Res<(u32, u32)> {
    let (conn, screen) = x11rb::connect(Some(display))
        .map_err(|e| format!("cannot open X display {display}: {e}"))?;
    let s = &conn.setup().roots[screen];
    Ok((u32::from(s.width_in_pixels), u32::from(s.height_in_pixels)))
}

#[derive(Default)]
pub struct Report {
    pub presented: u64,
    pub present_ms: Vec<f64>,
    pub decoded_to_presented_ms: Vec<f64>,
    pub key_to_presented_ms: Vec<f64>,
    pub refresh_paced: bool,
}

pub struct Window {
    conn: RustConnection,
    window: u32,
    gc: u32,
    delete_atom: u32,
    shm: Option<ShmSeg>,
    size: (usize, usize),
    /// The Present extension's event id, when the server has the extension.
    present_eid: Option<u32>,
    control: bool,
    keys: KeyTable,
}

impl Window {
    pub fn open(display: &str, title: &str, control: bool) -> Res<Self> {
        let (conn, screen_num) = x11rb::connect(Some(display))
            .map_err(|e| format!("cannot open X display {display}: {e}"))?;
        let screen = conn.setup().roots[screen_num].clone();
        if screen.root_depth != 24 {
            return Err(format!("root depth {} unsupported (need 24)", screen.root_depth).into());
        }
        let window = conn.generate_id()?;
        let events = EventMask::KEY_PRESS
            | EventMask::KEY_RELEASE
            | EventMask::BUTTON_PRESS
            | EventMask::BUTTON_RELEASE
            | EventMask::POINTER_MOTION
            | EventMask::FOCUS_CHANGE
            | EventMask::STRUCTURE_NOTIFY;
        conn.create_window(
            24,
            window,
            screen.root,
            0,
            0,
            640,
            400,
            0,
            WindowClass::INPUT_OUTPUT,
            screen.root_visual,
            &CreateWindowAux::new().background_pixel(screen.black_pixel).event_mask(events),
        )?;
        let atom = |name: &str| -> Res<u32> {
            Ok(conn.intern_atom(false, name.as_bytes())?.reply()?.atom)
        };
        let (protocols, delete_atom, net_name, utf8) = (
            atom("WM_PROTOCOLS")?,
            atom("WM_DELETE_WINDOW")?,
            atom("_NET_WM_NAME")?,
            atom("UTF8_STRING")?,
        );
        conn.change_property32(
            PropMode::REPLACE,
            window,
            protocols,
            AtomEnum::ATOM,
            &[delete_atom],
        )?;
        conn.change_property8(
            PropMode::REPLACE,
            window,
            AtomEnum::WM_NAME,
            AtomEnum::STRING,
            title.as_bytes(),
        )?;
        conn.change_property8(PropMode::REPLACE, window, net_name, utf8, title.as_bytes())?;
        let gc = conn.generate_id()?;
        conn.create_gc(gc, window, &CreateGCAux::new())?;
        conn.map_window(window)?;
        let present_eid = match conn.extension_information(present::X11_EXTENSION_NAME)? {
            Some(_) => {
                conn.present_query_version(1, 2)?.reply()?;
                let eid = conn.generate_id()?;
                conn.present_select_input(eid, window, present::EventMask::COMPLETE_NOTIFY)?;
                Some(eid)
            }
            None => None,
        };
        conn.flush()?;
        Ok(Self {
            conn,
            window,
            gc,
            delete_atom,
            shm: None,
            size: (0, 0),
            present_eid,
            control,
            keys: KeyTable::new(),
        })
    }

    /// Fits the window and its segment to a stream of `w` x `h`.
    fn resize(&mut self, w: usize, h: usize) -> Res<()> {
        self.shm = None;
        self.conn.configure_window(
            self.window,
            &ConfigureWindowAux::new().width(w as u32).height(h as u32),
        )?;
        let mut hints = WmSizeHints::new();
        hints.min_size = Some((w as i32, h as i32));
        hints.max_size = Some((w as i32, h as i32));
        hints.set_normal_hints(&self.conn, self.window)?;
        self.size = (w, h);
        self.shm = Some(ShmSeg::new(&self.conn, w * h * 4, ServerAccess::Read)?);
        Ok(())
    }

    fn present(&mut self, picture: &Picture) -> Res<()> {
        let (w, h) = (picture.image.width, picture.height());
        if w == 0 || h == 0 {
            return Ok(());
        }
        if (w, h) != self.size || self.shm.is_none() {
            self.resize(w, h)?;
        }
        let shm = self.shm.as_mut().ok_or("no shared memory segment")?;
        i420_to_bgrx(&picture.image, picture.color, h, shm.pixels_mut());
        // The server has copied the segment when this returns, so it can be refilled.
        shm.put_image(&self.conn, self.window, self.gc, (w as u16, h as u16), 24)
    }

    /// Presents and reads input until the stream closes the mailbox or the person closes the window.
    pub fn run(
        mut self,
        mailbox: &SharedMailbox,
        present_waker: &Waker,
        input: &mpsc::Sender<InputEvent>,
        input_waker: &Waker,
    ) -> Res<Report> {
        let mut report = Report { refresh_paced: self.present_eid.is_some(), ..Report::default() };
        let mut tracker = InputTracker::default();
        // Refresh pacing: `armed` lets one present happen; a present disarms it and asks for
        // the next refresh (MSC), whose notification arms it again.
        let (mut armed, mut last_msc, mut asked_at, mut serial) = (true, 0u64, 0u64, 0u32);
        if self.present_eid.is_some() {
            // Learn the current MSC first (an immediate notification).
            self.conn.present_notify_msc(self.window, serial, 0, 0, 0)?;
            armed = false;
            asked_at = now_ns();
        }
        let mut key_down_at: Option<u64> = None;
        let fd = self.conn.stream().as_raw_fd();
        loop {
            let mut out = Vec::new();
            while let Some(event) = self.conn.poll_for_event()? {
                match event {
                    Event::PresentCompleteNotify(e) if e.window == self.window => {
                        last_msc = e.msc;
                        armed = true;
                    }
                    Event::ClientMessage(e) if e.data.as_data32()[0] == self.delete_atom => {
                        tracker.release_all(&mut out);
                        send(&out, input, input_waker);
                        return Ok(report);
                    }
                    Event::KeyPress(e) => {
                        if let Some(usage) = self.keys.usage(e.detail) {
                            key_down_at.get_or_insert(now_ns());
                            tracker.key(usage, true, &mut out);
                        }
                    }
                    Event::KeyRelease(e) => {
                        if let Some(usage) = self.keys.usage(e.detail) {
                            tracker.key(usage, false, &mut out);
                        }
                    }
                    Event::MotionNotify(e) => {
                        tracker.pointer(e.event_x.into(), e.event_y.into(), &mut out)
                    }
                    Event::ButtonPress(e) => {
                        tracker.pointer(e.event_x.into(), e.event_y.into(), &mut out);
                        tracker.button(e.detail, true, &mut out);
                    }
                    Event::ButtonRelease(e) => {
                        tracker.pointer(e.event_x.into(), e.event_y.into(), &mut out);
                        tracker.button(e.detail, false, &mut out);
                    }
                    // Keys and buttons held when the window loses focus would stay down on the host.
                    Event::FocusOut(_) => tracker.release_all(&mut out),
                    _ => {}
                }
            }
            if self.control {
                send(&out, input, input_waker);
            }
            if !armed && now_ns().saturating_sub(asked_at) >= PACE_GIVE_UP_NS {
                armed = true;
            }
            if armed {
                let picture = {
                    let mut slot = mailbox.lock().unwrap_or_else(|e| e.into_inner());
                    if slot.closed {
                        return Ok(report);
                    }
                    slot.ready.take()
                };
                if let Some(picture) = picture {
                    let t0 = now_ns();
                    let shown = self.present(&picture);
                    let t1 = now_ns();
                    if shown.is_ok() {
                        report.presented += 1;
                        report.present_ms.push((t1 - t0) as f64 / 1e6);
                        report.decoded_to_presented_ms.push((t1 - picture.decoded_ns) as f64 / 1e6);
                        if let Some(at) = key_down_at {
                            if picture.complete_ns > at {
                                if t1 - at <= KEY_SAMPLE_LIMIT_NS {
                                    report.key_to_presented_ms.push((t1 - at) as f64 / 1e6);
                                }
                                key_down_at = None;
                            }
                        }
                    }
                    if let Some(at) = key_down_at {
                        if t1 - at > KEY_SAMPLE_LIMIT_NS {
                            key_down_at = None;
                        }
                    }
                    mailbox.lock().unwrap_or_else(|e| e.into_inner()).spare = Some(picture);
                    shown?;
                    if self.present_eid.is_some() {
                        serial = serial.wrapping_add(1);
                        self.conn.present_notify_msc(self.window, serial, last_msc + 1, 0, 0)?;
                        armed = false;
                        asked_at = t1;
                    }
                }
            }
            self.conn.flush()?;
            present_waker.drain();
            let pending = mailbox.lock().unwrap_or_else(|e| e.into_inner()).ready.is_some();
            let timeout = if pending && !armed { PACE_GIVE_UP_NS / 5 } else { 100_000_000 };
            // A picture that came while drawing was announced on the waker already drained;
            // `pending` above keeps the wait short instead.
            wait_readable(
                &[fd, present_waker.fd()],
                Some(if pending && armed { 0 } else { timeout }),
            )?;
        }
    }
}

fn send(events: &[InputEvent], input: &mpsc::Sender<InputEvent>, waker: &Waker) {
    if events.is_empty() {
        return;
    }
    for e in events {
        let _ = input.send(e.clone());
    }
    waker.wake();
}

/// X keycodes (evdev + 8) to USB HID keyboard usages, the inverse of the host's keymap.
pub struct KeyTable([u32; 256]);

impl KeyTable {
    pub fn new() -> Self {
        let mut table = [0u32; 256];
        for id in 0..=0xffu32 {
            let usage = 0x0007_0000 | id;
            if let Some(code) = crate::keymap::hid_to_x(usage) {
                // The first usage for a code wins (the table has no duplicates today).
                if table[code as usize] == 0 {
                    table[code as usize] = usage;
                }
            }
        }
        Self(table)
    }

    pub fn usage(&self, keycode: u8) -> Option<u32> {
        let usage = self.0[keycode as usize];
        (usage != 0).then_some(usage)
    }
}

/// The window's input as `cmux.rd/1` events: what is held (so a lost focus releases it) and
/// where the pointer was last sent (so motion between buttons is not repeated).
#[derive(Default)]
pub struct InputTracker {
    keys: BTreeSet<u32>,
    buttons: BTreeSet<u8>,
    pointer: Option<(i32, i32)>,
}

impl InputTracker {
    pub fn key(&mut self, usage: u32, down: bool, out: &mut Vec<InputEvent>) {
        if down {
            self.keys.insert(usage);
        } else if !self.keys.remove(&usage) {
            // A release whose press went elsewhere (focus came in with it held).
            return;
        }
        out.push(InputEvent::Key { usage, down });
    }

    /// Pointer motion: the newest position replaces one not yet sent in this batch.
    pub fn pointer(&mut self, x: i32, y: i32, out: &mut Vec<InputEvent>) {
        if self.pointer == Some((x, y)) {
            return;
        }
        self.pointer = Some((x, y));
        if let Some(InputEvent::Pointer { x: px, y: py }) = out.last_mut() {
            (*px, *py) = (x, y);
            return;
        }
        out.push(InputEvent::Pointer { x, y });
    }

    /// X buttons: 1 left, 2 middle, 3 right, 8 back, 9 forward (the host's numbering);
    /// 4 to 7 are wheel clicks, one line each (dy < 0 scrolls up, dx < 0 left).
    pub fn button(&mut self, button: u8, down: bool, out: &mut Vec<InputEvent>) {
        let scroll = |dx: i32, dy: i32| InputEvent::Scroll { dx, dy, precise: false };
        match button {
            4..=7 if down => out.push(match button {
                4 => scroll(0, -100),
                5 => scroll(0, 100),
                6 => scroll(-100, 0),
                _ => scroll(100, 0),
            }),
            4..=7 => {}
            1..=3 | 8 | 9 => {
                if down {
                    self.buttons.insert(button);
                } else if !self.buttons.remove(&button) {
                    return;
                }
                out.push(InputEvent::Button { button, down });
            }
            _ => {}
        }
    }

    pub fn release_all(&mut self, out: &mut Vec<InputEvent>) {
        for usage in std::mem::take(&mut self.keys) {
            out.push(InputEvent::Key { usage, down: false });
        }
        for button in std::mem::take(&mut self.buttons) {
            out.push(InputEvent::Button { button, down: false });
        }
    }
}

/// I420 (even size, tight strides) to BGRX with `color`'s matrix and range, as the bench
/// presenter.
fn i420_to_bgrx(p: &I420, color: Yuv, h: usize, out: &mut [u8]) {
    let (w, cw) = (p.width, p.width / 2);
    cmux_encode::color::i420_to_bgrx(&p.y, &p.u, &p.v, (w, cw, cw), w, h, color, out);
}

#[cfg(test)]
#[path = "window_tests.rs"]
mod tests;
