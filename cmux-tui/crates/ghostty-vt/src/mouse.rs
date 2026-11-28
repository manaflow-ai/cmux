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

/// The active mouse coordinate wire format of a terminal.
///
/// xterm semantics: the extended-coordinate DEC modes (1005 UTF-8, 1006 SGR,
/// 1015 urxvt, 1016 SGR-pixels) are a single last-set-wins selector, not
/// independent flags. Ghostty tracks it that way internally; this mirrors
/// that value so replay serialization and re-encoding can reproduce the
/// semantic instead of a numeric flag dump.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum MouseWireFormat {
    #[default]
    X10,
    Utf8,
    Sgr,
    Urxvt,
    SgrPixels,
}

impl MouseWireFormat {
    /// The DEC private mode number selecting this format, if any.
    pub fn dec_mode(self) -> Option<u16> {
        match self {
            MouseWireFormat::X10 => None,
            MouseWireFormat::Utf8 => Some(1005),
            MouseWireFormat::Sgr => Some(1006),
            MouseWireFormat::Urxvt => Some(1015),
            MouseWireFormat::SgrPixels => Some(1016),
        }
    }
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

/// Fingerprints the effective tracking and wire-format behavior of Ghostty's
/// own encoder. This keeps Ghostty's parsed terminal state authoritative when
/// multiple DEC modes are enabled and their last-set precedence matters.
pub(crate) struct MouseModeProbe {
    encoder: MouseEncoder,
    #[cfg(test)]
    signature_calls: u64,
}

/// Allocation-free fingerprint of Ghostty's effective mouse encoder behavior.
/// The fixed probe inputs produce fewer than 192 bytes for every supported
/// protocol. The overflow hash keeps a deterministic fingerprint if an
/// upstream format ever exceeds that bound.
#[derive(Clone, PartialEq, Eq)]
pub(crate) struct MouseModeSignature {
    bytes: [u8; 192],
    stored_len: u16,
    total_len: u16,
    overflow_hash: u64,
}

impl Default for MouseModeSignature {
    fn default() -> Self {
        Self { bytes: [0; 192], stored_len: 0, total_len: 0, overflow_hash: 0xcbf2_9ce4_8422_2325 }
    }
}

impl Extend<u8> for MouseModeSignature {
    fn extend<T: IntoIterator<Item = u8>>(&mut self, iter: T) {
        for byte in iter {
            let index = usize::from(self.stored_len);
            if index < self.bytes.len() {
                self.bytes[index] = byte;
                self.stored_len += 1;
            } else {
                self.overflow_hash ^= u64::from(byte);
                self.overflow_hash = self.overflow_hash.wrapping_mul(0x100_0000_01b3);
            }
            self.total_len = self.total_len.saturating_add(1);
        }
    }
}

impl MouseEncoders {
    pub fn new() -> Result<Self> {
        Ok(Self { primary: MouseEncoder::new()?, release: MouseEncoder::new()? })
    }

    pub fn sync_from_terminal(&mut self, terminal: &Terminal) {
        self.primary.sync_from_terminal(terminal);
        self.release.sync_from_terminal(terminal);
    }

    pub fn encode(&mut self, input: MouseInput, out: &mut impl Extend<u8>) -> Result<()> {
        self.primary.encode(input, out)
    }

    pub fn encode_release(&mut self, input: MouseInput, out: &mut impl Extend<u8>) -> Result<()> {
        self.release.encode(input, out)
    }

    pub fn encode_press_pair(
        &mut self,
        press: MouseInput,
        release: MouseInput,
        press_out: &mut impl Extend<u8>,
        release_out: &mut impl Extend<u8>,
    ) -> Result<()> {
        self.release.encode(release, release_out)?;
        self.primary.encode(press, press_out)
    }

    pub fn reset_motion_dedupe(&mut self) {
        self.primary.reset_motion_dedupe();
    }
}

impl MouseModeProbe {
    pub(crate) fn new() -> Result<Self> {
        Ok(Self {
            encoder: MouseEncoder::new()?,
            #[cfg(test)]
            signature_calls: 0,
        })
    }

    pub(crate) fn signature(&mut self, terminal: sys::GhosttyTerminal) -> MouseModeSignature {
        #[cfg(test)]
        {
            self.signature_calls += 1;
        }
        self.encoder.sync_from_raw_terminal(terminal);
        self.encoder.reset_motion_dedupe();
        let mut signature = MouseModeSignature::default();
        // Together these events distinguish X10, normal, button-motion,
        // any-motion, UTF-8, SGR, URXVT, and pixel-coordinate behavior.
        for (tag, input) in [
            (
                1,
                MouseInput {
                    action: MouseAction::Press,
                    button: Some(MouseButton::Left),
                    mods: Mods::default(),
                    position: (300.5, 200.5),
                    screen_size: (800, 600),
                    cell_size: (8, 16),
                    any_button_pressed: true,
                },
            ),
            (
                2,
                MouseInput {
                    action: MouseAction::Release,
                    button: Some(MouseButton::Left),
                    mods: Mods::default(),
                    position: (301.5, 201.5),
                    screen_size: (800, 600),
                    cell_size: (8, 16),
                    any_button_pressed: false,
                },
            ),
            (
                3,
                MouseInput {
                    action: MouseAction::Motion,
                    button: Some(MouseButton::Left),
                    mods: Mods::default(),
                    position: (302.5, 202.5),
                    screen_size: (800, 600),
                    cell_size: (8, 16),
                    any_button_pressed: true,
                },
            ),
            (
                4,
                MouseInput {
                    action: MouseAction::Motion,
                    button: None,
                    mods: Mods::default(),
                    position: (303.5, 203.5),
                    screen_size: (800, 600),
                    cell_size: (8, 16),
                    any_button_pressed: false,
                },
            ),
            (
                5,
                MouseInput {
                    action: MouseAction::Press,
                    button: Some(MouseButton::Left),
                    mods: Mods::default(),
                    position: (300.5, 200.5),
                    screen_size: (800, 600),
                    cell_size: (1, 1),
                    any_button_pressed: true,
                },
            ),
        ] {
            let encoded_start = signature.total_len;
            let result = self.encoder.encode(input, &mut signature);
            let encoded_len = signature.total_len.saturating_sub(encoded_start);
            signature.extend([
                tag,
                u8::from(result.is_err()),
                encoded_len.to_le_bytes()[0],
                encoded_len.to_le_bytes()[1],
            ]);
        }
        signature
    }

    /// Classify the terminal's active coordinate wire format by encoding one
    /// synthetic press through Ghostty's own encoder. Tracking is forced to
    /// "normal" on the probe encoder so the format is observable even while
    /// the application has tracking disabled; the wire format itself still
    /// comes from Ghostty's parsed last-set-wins terminal state.
    pub(crate) fn classify_wire_format(
        &mut self,
        terminal: sys::GhosttyTerminal,
    ) -> Option<MouseWireFormat> {
        self.encoder.sync_from_raw_terminal(terminal);
        self.encoder.force_normal_tracking();
        self.encoder.reset_motion_dedupe();
        let mut bytes: Vec<u8> = Vec::with_capacity(32);
        self.encoder
            .encode(
                MouseInput {
                    action: MouseAction::Press,
                    button: Some(MouseButton::Left),
                    mods: Mods::default(),
                    // Cell (151, 13) one-based, pixel ~(1201, 201): the cell
                    // and pixel X coordinates are far apart so SGR and
                    // SGR-pixels are distinguishable, and the X10 byte for
                    // column 151 (183) needs two UTF-8 bytes, separating
                    // X10 from UTF-8 by length.
                    position: (1200.5, 200.5),
                    screen_size: (2400, 600),
                    cell_size: (8, 16),
                    any_button_pressed: true,
                },
                &mut bytes,
            )
            .ok()?;
        classify_probe_press(&bytes)
    }

    #[cfg(test)]
    pub(crate) fn signature_calls(&self) -> u64 {
        self.signature_calls
    }
}

fn classify_probe_press(bytes: &[u8]) -> Option<MouseWireFormat> {
    match bytes {
        [0x1b, b'[', b'<', rest @ ..] => {
            let text = std::str::from_utf8(rest).ok()?;
            let x: u32 = text.split(';').nth(1)?.parse().ok()?;
            Some(if x >= 600 { MouseWireFormat::SgrPixels } else { MouseWireFormat::Sgr })
        }
        [0x1b, b'[', b'M', ..] => {
            Some(if bytes.len() == 6 { MouseWireFormat::X10 } else { MouseWireFormat::Utf8 })
        }
        [0x1b, b'[', digit, ..] if digit.is_ascii_digit() => Some(MouseWireFormat::Urxvt),
        _ => None,
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
        self.sync_from_raw_terminal(terminal.raw());
        self.terminal_state = Some(state);
    }

    fn sync_from_raw_terminal(&mut self, terminal: sys::GhosttyTerminal) {
        unsafe { sys::ghostty_mouse_encoder_setopt_from_terminal(self.encoder, terminal) };
    }

    /// Force the tracking mode to "normal" so a press encodes regardless of
    /// the terminal's tracking state. Probe-only: the wire format set by
    /// [`Self::sync_from_raw_terminal`] is left untouched.
    fn force_normal_tracking(&mut self) {
        let tracking: sys::GhosttyMouseTrackingMode = sys::GHOSTTY_MOUSE_TRACKING_NORMAL;
        unsafe {
            sys::ghostty_mouse_encoder_setopt(
                self.encoder,
                sys::GHOSTTY_MOUSE_ENCODER_OPT_EVENT,
                &tracking as *const _ as *const c_void,
            );
        }
    }

    /// Forget the last encoded motion cell so an event that was not delivered
    /// can be encoded again at the same coordinates.
    pub fn reset_motion_dedupe(&mut self) {
        unsafe { sys::ghostty_mouse_encoder_reset(self.encoder) };
    }

    pub fn encode(&mut self, input: MouseInput, out: &mut impl Extend<u8>) -> Result<()> {
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
            out.extend(big[..big_written].iter().copied());
            return Ok(());
        }
        check(result)?;
        out.extend(buf[..written].iter().copied());
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
    fn csi_controls_do_not_hide_mouse_format_changes_from_encoder() {
        let mut terminal = Terminal::new(80, 24, 0, Callbacks::default()).unwrap();
        terminal.vt_write(b"\x1b[?1000h");
        let mut encoder = MouseEncoder::new().unwrap();
        encoder.sync_from_terminal(&terminal);

        terminal.vt_write(b"\x1b[?1006\x07h");
        assert!(terminal.mode(1006, false), "Ghostty must accept BEL inside CSI parameters");
        encoder.sync_from_terminal(&terminal);

        let mut out = Vec::new();
        encoder.encode(input(MouseAction::Press, Some(MouseButton::Left)), &mut out).unwrap();
        assert_eq!(
            out, b"\x1b[<0;5;3M",
            "encoder synchronization must follow Ghostty's authoritative SGR mouse mode"
        );
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
