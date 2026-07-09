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
        Ok(Self { encoder, event })
    }

    pub fn sync_from_terminal(&mut self, terminal: &Terminal) {
        unsafe {
            sys::ghostty_mouse_encoder_setopt_from_terminal(self.encoder, terminal.raw());
        }
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

            let size = sys::GhosttyMouseEncoderSize {
                size: size_of::<sys::GhosttyMouseEncoderSize>(),
                screen_width: input.screen_size.0,
                screen_height: input.screen_size.1,
                cell_width: input.cell_size.0.max(1),
                cell_height: input.cell_size.1.max(1),
                ..Default::default()
            };
            sys::ghostty_mouse_encoder_setopt(
                self.encoder,
                sys::GHOSTTY_MOUSE_ENCODER_OPT_SIZE,
                &size as *const _ as *const c_void,
            );
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
            // Ghostty normalizes a positive horizontal wheel delta (right)
            // as button six and a negative delta (left) as button seven.
            MouseButton::WheelLeft => sys::GHOSTTY_MOUSE_BUTTON_SEVEN,
            MouseButton::WheelRight => sys::GHOSTTY_MOUSE_BUTTON_SIX,
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
        assert_eq!(out, b"\x1b[<67;5;3M");

        out.clear();
        encoder.encode(input(MouseAction::Press, Some(MouseButton::WheelRight)), &mut out).unwrap();
        assert_eq!(out, b"\x1b[<66;5;3M");
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
}
