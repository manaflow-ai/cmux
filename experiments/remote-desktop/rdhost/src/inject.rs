//! Input injection with XTest (key tap, absolute pointer move, button tap).

use crate::proto::{Input, INPUT_BUTTON_TAP, INPUT_KEY_TAP, INPUT_POINTER_MOVE};
use crate::Res;
use x11rb::connection::Connection;
use x11rb::protocol::xproto::{
    Window, BUTTON_PRESS_EVENT, BUTTON_RELEASE_EVENT, KEY_PRESS_EVENT, KEY_RELEASE_EVENT, MOTION_NOTIFY_EVENT,
};
use x11rb::protocol::xtest::ConnectionExt as _;
use x11rb::rust_connection::RustConnection;

/// X keycode used when the client sends a code outside the X range 8..=255 (38 = "a" on the default map).
const FALLBACK_KEYCODE: u8 = 38;

pub struct Injector {
    conn: RustConnection,
    root: Window,
}

impl Injector {
    pub fn new(display: &str) -> Res<Self> {
        let (conn, screen_num) = x11rb::connect(Some(display))?;
        let root = conn.setup().roots[screen_num].root;
        conn.xtest_get_version(2, 2)?.reply()?;
        Ok(Self { conn, root })
    }

    fn fake(&self, ty: u8, detail: u8, x: i32, y: i32) -> Res<()> {
        let (x, y) = (x.clamp(0, i16::MAX as i32) as i16, y.clamp(0, i16::MAX as i32) as i16);
        self.conn.xtest_fake_input(ty, detail, x11rb::CURRENT_TIME, self.root, x, y, 0)?;
        Ok(())
    }

    /// Injects one INPUT message and flushes it to the server.
    pub fn apply(&self, input: &Input) -> Res<()> {
        match input.kind {
            INPUT_KEY_TAP => {
                let code = u8::try_from(input.code).ok().filter(|c| *c >= 8).unwrap_or(FALLBACK_KEYCODE);
                self.fake(KEY_PRESS_EVENT, code, 0, 0)?;
                self.fake(KEY_RELEASE_EVENT, code, 0, 0)?;
            }
            INPUT_POINTER_MOVE => self.fake(MOTION_NOTIFY_EVENT, 0, input.x, input.y)?,
            INPUT_BUTTON_TAP => {
                let button = u8::try_from(input.code).ok().filter(|b| (1..=7).contains(b)).unwrap_or(1);
                self.fake(MOTION_NOTIFY_EVENT, 0, input.x, input.y)?;
                self.fake(BUTTON_PRESS_EVENT, button, 0, 0)?;
                self.fake(BUTTON_RELEASE_EVENT, button, 0, 0)?;
            }
            other => return Err(format!("unknown input kind {other}").into()),
        }
        self.conn.flush()?;
        Ok(())
    }
}
