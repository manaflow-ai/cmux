//! Input injection with XTest for `cmux.rd/1` input events. Tracks pressed keys and
//! buttons so they can all be released when control ends or an event was lost.

use crate::keymap::hid_to_x;
use crate::Res;
use cmux_rd_proto::InputEvent;
use std::collections::BTreeSet;
use x11rb::connection::Connection;
use x11rb::protocol::xproto::{
    Window, BUTTON_PRESS_EVENT, BUTTON_RELEASE_EVENT, KEY_PRESS_EVENT, KEY_RELEASE_EVENT,
    MOTION_NOTIFY_EVENT,
};
use x11rb::protocol::xtest::ConnectionExt as _;
use x11rb::rust_connection::RustConnection;

pub struct Injector {
    conn: RustConnection,
    root: Window,
    keys: BTreeSet<u8>,
    buttons: BTreeSet<u8>,
    /// Events with no XTest mapping (for example text), counted for stats.
    pub unsupported: u64,
}

impl Injector {
    pub fn new(display: &str) -> Res<Self> {
        let (conn, screen_num) = x11rb::connect(Some(display))?;
        let root = conn.setup().roots[screen_num].root;
        conn.xtest_get_version(2, 2)?.reply()?;
        Ok(Self { conn, root, keys: BTreeSet::new(), buttons: BTreeSet::new(), unsupported: 0 })
    }

    fn fake(&self, ty: u8, detail: u8, x: i32, y: i32) -> Res<()> {
        let (x, y) =
            (x.clamp(0, i32::from(i16::MAX)) as i16, y.clamp(0, i32::from(i16::MAX)) as i16);
        self.conn.xtest_fake_input(ty, detail, x11rb::CURRENT_TIME, self.root, x, y, 0)?;
        Ok(())
    }

    /// Injects one event and flushes.
    pub fn apply(&mut self, event: &InputEvent) -> Res<()> {
        match event {
            InputEvent::Key { usage, down } => match hid_to_x(*usage) {
                Some(code) => {
                    self.fake(if *down { KEY_PRESS_EVENT } else { KEY_RELEASE_EVENT }, code, 0, 0)?;
                    if *down {
                        self.keys.insert(code);
                    } else {
                        self.keys.remove(&code);
                    }
                }
                None => self.unsupported += 1,
            },
            InputEvent::Pointer { x, y } => self.fake(MOTION_NOTIFY_EVENT, 0, *x, *y)?,
            InputEvent::Button { button, down } => {
                let b = (*button).clamp(1, 9);
                self.fake(if *down { BUTTON_PRESS_EVENT } else { BUTTON_RELEASE_EVENT }, b, 0, 0)?;
                if *down {
                    self.buttons.insert(b);
                } else {
                    self.buttons.remove(&b);
                }
            }
            InputEvent::Scroll { dx, dy, .. } => {
                // X scrolls in wheel clicks: buttons 4/5 vertical, 6/7 horizontal, one per 100 units.
                for (amount, neg, pos) in [(*dy, 4u8, 5u8), (*dx, 6u8, 7u8)] {
                    let clicks = (amount.unsigned_abs() / 100).min(20);
                    let button = if amount < 0 { neg } else { pos };
                    for _ in 0..clicks {
                        self.fake(BUTTON_PRESS_EVENT, button, 0, 0)?;
                        self.fake(BUTTON_RELEASE_EVENT, button, 0, 0)?;
                    }
                }
            }
            // Desktop sessions do not offer the input.service cap.
            InputEvent::Text(_) | InputEvent::Service { .. } => self.unsupported += 1,
        }
        self.conn.flush()?;
        Ok(())
    }

    /// Releases every key and button this injector pressed.
    pub fn release_all(&mut self) -> Res<()> {
        for code in std::mem::take(&mut self.keys) {
            self.fake(KEY_RELEASE_EVENT, code, 0, 0)?;
        }
        for b in std::mem::take(&mut self.buttons) {
            self.fake(BUTTON_RELEASE_EVENT, b, 0, 0)?;
        }
        self.conn.flush()?;
        Ok(())
    }
}
