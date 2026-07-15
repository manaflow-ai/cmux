use std::ffi::c_void;
use std::mem::size_of;
use std::ptr;

use ghostty_vt_sys as sys;

use crate::key::Mods;
use crate::terminal::Terminal;
use crate::{Result, check};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MouseAction {
    Press,
    Release,
    Motion,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MouseButton {
    Left,
    Right,
    Middle,
    WheelUp,
    WheelDown,
    WheelLeft,
    WheelRight,
}

#[derive(Debug, Clone, Copy)]
pub struct MouseInput {
    pub action: MouseAction,
    pub button: Option<MouseButton>,
    pub mods: Mods,
    /// Position in surface-space pixels. Coordinates outside the screen
    /// remain valid so a release can terminate a drag outside the pane.
    pub position: (f32, f32),
    pub screen_size: (u32, u32),
    pub cell_size: (u32, u32),
    pub any_button_pressed: bool,
}

/// Encodes normalized pointer events with the mouse mode and wire format
/// requested by the application running in a terminal.
pub struct MouseEncoder {
    encoder: sys::GhosttyMouseEncoder,
    event: sys::GhosttyMouseEvent,
    terminal_state: Option<(u64, u64)>,
    size: Option<((u32, u32), (u32, u32))>,
}

// The opaque Ghostty encoder and event have no thread affinity. MouseEncoder
// owns both pointers and requires &mut self for every operation, so moving the
// pair between threads is safe. Shared access remains guarded by the caller.
unsafe impl Send for MouseEncoder {}

/// Per-surface encoders synchronized when terminal mouse modes change.
/// Keeping both encoders behind the surface avoids taking the terminal lock
/// on UI pointer paths while preserving a press/release protocol snapshot.
pub struct MouseEncoders {
    primary: MouseEncoder,
    release: MouseEncoder,
}

impl MouseEncoders {
    pub fn new() -> Result<Self> {
        Ok(Self { primary: MouseEncoder::new()?, release: MouseEncoder::new()? })
    }

    pub fn sync_from_terminal(&mut self, terminal: &Terminal) {
        self.primary.sync_from_terminal(terminal);
        self.release.sync_from_terminal(terminal);
    }

    pub fn encode(&mut self, input: MouseInput, out: &mut Vec<u8>) -> Result<()> {
        self.primary.encode(input, out)
    }

    pub fn encode_release(&mut self, input: MouseInput, out: &mut Vec<u8>) -> Result<()> {
        self.release.encode(input, out)
    }

    pub fn encode_press_pair(
        &mut self,
        press: MouseInput,
        release: MouseInput,
        press_out: &mut Vec<u8>,
        release_out: &mut Vec<u8>,
    ) -> Result<()> {
        self.release.encode(release, release_out)?;
        self.primary.encode(press, press_out)
    }

    pub fn reset_motion_dedupe(&mut self) {
        self.primary.reset_motion_dedupe();
    }
}

impl MouseEncoder {
    pub fn new() -> Result<Self> {
        let mut encoder: sys::GhosttyMouseEncoder = ptr::null_mut();
        check(unsafe { sys::ghostty_mouse_encoder_new(ptr::null(), &mut encoder) })?;
        let mut event: sys::GhosttyMouseEvent = ptr::null_mut();
        if let Err(error) = check(unsafe { sys::ghostty_mouse_event_new(ptr::null(), &mut event) })
        {
            unsafe { sys::ghostty_mouse_encoder_free(encoder) };
            return Err(error);
        }
        let track_last_cell = true;
        unsafe {
            sys::ghostty_mouse_encoder_setopt(
                encoder,
                sys::GHOSTTY_MOUSE_ENCODER_OPT_TRACK_LAST_CELL,
                &track_last_cell as *const _ as *const c_void,
            );
        }
        Ok(Self { encoder, event, terminal_state: None, size: None })
    }

    pub fn sync_from_terminal(&mut self, terminal: &Terminal) {
        let state = (terminal.instance_id(), terminal.mouse_mode_revision());
        if self.terminal_state == Some(state) {
            return;
        }
        unsafe {
            sys::ghostty_mouse_encoder_setopt_from_terminal(self.encoder, terminal.raw());
        }
        self.terminal_state = Some(state);
    }

    /// Forget the last encoded motion cell so an event that was not delivered
    /// can be encoded again at the same coordinates.
    pub fn reset_motion_dedupe(&mut self) {
        unsafe { sys::ghostty_mouse_encoder_reset(self.encoder) };
    }

    pub fn encode(&mut self, input: MouseInput, out: &mut Vec<u8>) -> Result<()> {
        let action = match input.action {
            MouseAction::Press => sys::GHOSTTY_MOUSE_ACTION_PRESS,
            MouseAction::Release => sys::GHOSTTY_MOUSE_ACTION_RELEASE,
            MouseAction::Motion => sys::GHOSTTY_MOUSE_ACTION_MOTION,
        };
        unsafe {
            sys::ghostty_mouse_event_set_action(self.event, action);
            if let Some(button) = input.button {
                sys::ghostty_mouse_event_set_button(self.event, button.raw());
            } else {
                sys::ghostty_mouse_event_clear_button(self.event);
            }
            sys::ghostty_mouse_event_set_mods(self.event, input.mods.0);
            sys::ghostty_mouse_event_set_position(
                self.event,
                sys::GhosttyMousePosition { x: input.position.0, y: input.position.1 },
            );

            let cell_size = (input.cell_size.0.max(1), input.cell_size.1.max(1));
            let size_key = (input.screen_size, cell_size);
            if self.size != Some(size_key) {
                let size = sys::GhosttyMouseEncoderSize {
                    size: size_of::<sys::GhosttyMouseEncoderSize>(),
                    screen_width: input.screen_size.0,
                    screen_height: input.screen_size.1,
                    cell_width: cell_size.0,
                    cell_height: cell_size.1,
                    ..Default::default()
                };
                sys::ghostty_mouse_encoder_setopt(
                    self.encoder,
                    sys::GHOSTTY_MOUSE_ENCODER_OPT_SIZE,
                    &size as *const _ as *const c_void,
                );
                self.size = Some(size_key);
            }
            sys::ghostty_mouse_encoder_setopt(
                self.encoder,
                sys::GHOSTTY_MOUSE_ENCODER_OPT_ANY_BUTTON_PRESSED,
                &input.any_button_pressed as *const _ as *const c_void,
            );
        }

        let mut buf = [0u8; 64];
        let mut written = 0;
        let result = unsafe {
            sys::ghostty_mouse_encoder_encode(
                self.encoder,
                self.event,
                buf.as_mut_ptr().cast(),
                buf.len(),
                &mut written,
            )
        };
        if result == sys::GHOSTTY_OUT_OF_SPACE {
            let mut big = vec![0u8; written.max(buf.len() * 2)];
            let mut big_written = 0;
            check(unsafe {
                sys::ghostty_mouse_encoder_encode(
                    self.encoder,
                    self.event,
                    big.as_mut_ptr().cast(),
                    big.len(),
                    &mut big_written,
                )
            })?;
            out.extend_from_slice(&big[..big_written]);
            return Ok(());
        }
        check(result)?;
        out.extend_from_slice(&buf[..written]);
        Ok(())
    }
}

impl MouseButton {
    fn raw(self) -> sys::GhosttyMouseButton {
        match self {
            MouseButton::Left => sys::GHOSTTY_MOUSE_BUTTON_LEFT,
            MouseButton::Right => sys::GHOSTTY_MOUSE_BUTTON_RIGHT,
            MouseButton::Middle => sys::GHOSTTY_MOUSE_BUTTON_MIDDLE,
            MouseButton::WheelUp => sys::GHOSTTY_MOUSE_BUTTON_FOUR,
            MouseButton::WheelDown => sys::GHOSTTY_MOUSE_BUTTON_FIVE,
            MouseButton::WheelLeft => sys::GHOSTTY_MOUSE_BUTTON_SIX,
            MouseButton::WheelRight => sys::GHOSTTY_MOUSE_BUTTON_SEVEN,
        }
    }
}

impl Drop for MouseEncoder {
    fn drop(&mut self) {
        unsafe {
            sys::ghostty_mouse_event_free(self.event);
            sys::ghostty_mouse_encoder_free(self.encoder);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::Callbacks;

    fn input(action: MouseAction, button: Option<MouseButton>) -> MouseInput {
        MouseInput {
            action,
            button,
            mods: Mods::default(),
            position: (4.5, 2.5),
            screen_size: (80, 24),
            cell_size: (1, 1),
            any_button_pressed: action != MouseAction::Release,
        }
    }

    #[test]
    fn sgr_click_and_wheel_follow_terminal_modes() {
        let mut terminal = Terminal::new(80, 24, 0, Callbacks::default()).unwrap();
        terminal.vt_write(b"\x1b[?1000h\x1b[?1006h");
        let mut encoder = MouseEncoder::new().unwrap();
        encoder.sync_from_terminal(&terminal);

        let mut out = Vec::new();
        encoder.encode(input(MouseAction::Press, Some(MouseButton::Left)), &mut out).unwrap();
        assert_eq!(out, b"\x1b[<0;5;3M");

        out.clear();
        encoder.encode(input(MouseAction::Release, Some(MouseButton::Left)), &mut out).unwrap();
        assert_eq!(out, b"\x1b[<0;5;3m");

        out.clear();
        encoder.encode(input(MouseAction::Press, Some(MouseButton::WheelUp)), &mut out).unwrap();
        assert_eq!(out, b"\x1b[<64;5;3M");

        out.clear();
        encoder.encode(input(MouseAction::Press, Some(MouseButton::WheelLeft)), &mut out).unwrap();
        assert_eq!(out, b"\x1b[<66;5;3M");

        out.clear();
        encoder.encode(input(MouseAction::Press, Some(MouseButton::WheelRight)), &mut out).unwrap();
        assert_eq!(out, b"\x1b[<67;5;3M");
    }

    #[test]
    fn disabled_mouse_mode_suppresses_output() {
        let terminal = Terminal::new(80, 24, 0, Callbacks::default()).unwrap();
        let mut encoder = MouseEncoder::new().unwrap();
        encoder.sync_from_terminal(&terminal);
        let mut out = Vec::new();

        encoder.encode(input(MouseAction::Press, Some(MouseButton::Left)), &mut out).unwrap();

        assert!(out.is_empty());
    }

    #[test]
    fn sgr_pixels_uses_rendered_cell_geometry() {
        let mut terminal = Terminal::new(80, 24, 0, Callbacks::default()).unwrap();
        terminal.vt_write(b"\x1b[?1000h\x1b[?1016h");
        let mut encoder = MouseEncoder::new().unwrap();
        encoder.sync_from_terminal(&terminal);
        let mut event = input(MouseAction::Press, Some(MouseButton::Left));
        event.position = (36.0, 40.0);
        event.screen_size = (640, 384);
        event.cell_size = (8, 16);
        let mut out = Vec::new();

        encoder.encode(event, &mut out).unwrap();

        assert_eq!(out, b"\x1b[<0;36;40M");
    }

    #[test]
    fn same_cell_motion_is_suppressed_until_mode_or_geometry_changes() {
        let mut terminal = Terminal::new(80, 24, 0, Callbacks::default()).unwrap();
        terminal.vt_write(b"\x1b[?1003h\x1b[?1006h");
        let mut encoder = MouseEncoder::new().unwrap();
        encoder.sync_from_terminal(&terminal);
        let mut event = input(MouseAction::Motion, None);
        event.position = (36.0, 40.0);
        event.screen_size = (640, 384);
        event.cell_size = (8, 16);
        let mut out = Vec::new();

        encoder.encode(event, &mut out).unwrap();
        assert_eq!(out, b"\x1b[<35;5;3M");

        out.clear();
        event.position = (39.0, 47.0);
        encoder.sync_from_terminal(&terminal);
        encoder.encode(event, &mut out).unwrap();
        assert!(out.is_empty());

        out.clear();
        event.cell_size = (4, 8);
        encoder.encode(event, &mut out).unwrap();
        assert_eq!(out, b"\x1b[<35;10;6M");
    }

    #[test]
    fn reasserted_mouse_mode_resynchronizes_last_set_precedence() {
        let mut terminal = Terminal::new(80, 24, 0, Callbacks::default()).unwrap();
        terminal.vt_write(b"\x1b[?1000h\x1b[?1002h\x1b[?1006h");
        let mut encoder = MouseEncoder::new().unwrap();
        encoder.sync_from_terminal(&terminal);
        let mut event = input(MouseAction::Motion, Some(MouseButton::Left));
        event.any_button_pressed = true;
        let mut out = Vec::new();

        encoder.encode(event, &mut out).unwrap();
        assert!(!out.is_empty(), "button tracking must report drag motion");

        terminal.vt_write(b"\x1b[?1000h");
        encoder.sync_from_terminal(&terminal);
        out.clear();
        encoder.encode(event, &mut out).unwrap();

        assert!(out.is_empty(), "reasserted normal tracking must suppress motion");
    }

    #[test]
    fn restored_mouse_mode_resynchronizes_saved_precedence() {
        let mut terminal = Terminal::new(80, 24, 0, Callbacks::default()).unwrap();
        terminal.vt_write(b"\x1b[?1000h\x1b[?1000s\x1b[?1002h\x1b[?1006h");
        let mut encoder = MouseEncoder::new().unwrap();
        encoder.sync_from_terminal(&terminal);
        let mut event = input(MouseAction::Motion, Some(MouseButton::Left));
        event.any_button_pressed = true;
        let mut out = Vec::new();

        encoder.encode(event, &mut out).unwrap();
        assert!(!out.is_empty(), "button tracking must report drag motion");

        terminal.vt_write(b"\x1b[?1000r");
        encoder.sync_from_terminal(&terminal);
        out.clear();
        encoder.encode(event, &mut out).unwrap();

        assert!(out.is_empty(), "restored normal tracking must suppress motion");
    }

    #[test]
    fn reset_allows_same_cell_motion_to_be_encoded_again() {
        let mut terminal = Terminal::new(80, 24, 0, Callbacks::default()).unwrap();
        terminal.vt_write(b"\x1b[?1003h\x1b[?1006h");
        let mut encoder = MouseEncoder::new().unwrap();
        encoder.sync_from_terminal(&terminal);
        let event = input(MouseAction::Motion, None);
        let mut out = Vec::new();

        encoder.encode(event, &mut out).unwrap();
        out.clear();
        encoder.encode(event, &mut out).unwrap();
        assert!(out.is_empty());

        encoder.reset_motion_dedupe();
        encoder.encode(event, &mut out).unwrap();
        assert_eq!(out, b"\x1b[<35;5;3M");
    }
}
