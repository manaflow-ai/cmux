//! Terminal key input on the control protocol: the kebab-case key and
//! modifier wire shapes, their validation, and the conversions to and from
//! Ghostty's `KeyInput`. Owns the clear-history fallback-key payload that the
//! daemon sends to a terminal host. Depends only on `ghostty_vt` and serde,
//! so it can move into a protocol crate unchanged.

use ghostty_vt::{KeyAction, KeyInput, Mods, sys};
use serde::{Deserialize, Serialize};

use crate::surface::CLEAR_HISTORY_KEY_TEXT_MAX_BYTES;

pub(super) const PROTOCOL_KEY_TEXT_MAX_BYTES: usize = CLEAR_HISTORY_KEY_TEXT_MAX_BYTES;

macro_rules! protocol_keys {
    ($($variant:ident => $constant:ident),+ $(,)?) => {
        #[derive(Debug, Clone, Copy, Deserialize, Serialize)]
        #[serde(rename_all = "kebab-case")]
        enum ProtocolKey {
            $($variant),+
        }

        impl TryFrom<sys::GhosttyKey> for ProtocolKey {
            type Error = anyhow::Error;

            fn try_from(key: sys::GhosttyKey) -> Result<Self, Self::Error> {
                match key {
                    $(sys::$constant => Ok(Self::$variant),)+
                    _ => anyhow::bail!("unsupported terminal key"),
                }
            }
        }

        impl From<ProtocolKey> for sys::GhosttyKey {
            fn from(key: ProtocolKey) -> Self {
                match key {
                    $(ProtocolKey::$variant => sys::$constant),+
                }
            }
        }
    };
}

protocol_keys! {
    Unidentified => GHOSTTY_KEY_UNIDENTIFIED,
    Backquote => GHOSTTY_KEY_BACKQUOTE,
    Backslash => GHOSTTY_KEY_BACKSLASH,
    BracketLeft => GHOSTTY_KEY_BRACKET_LEFT,
    BracketRight => GHOSTTY_KEY_BRACKET_RIGHT,
    Comma => GHOSTTY_KEY_COMMA,
    Digit0 => GHOSTTY_KEY_DIGIT_0,
    Digit1 => GHOSTTY_KEY_DIGIT_1,
    Digit2 => GHOSTTY_KEY_DIGIT_2,
    Digit3 => GHOSTTY_KEY_DIGIT_3,
    Digit4 => GHOSTTY_KEY_DIGIT_4,
    Digit5 => GHOSTTY_KEY_DIGIT_5,
    Digit6 => GHOSTTY_KEY_DIGIT_6,
    Digit7 => GHOSTTY_KEY_DIGIT_7,
    Digit8 => GHOSTTY_KEY_DIGIT_8,
    Digit9 => GHOSTTY_KEY_DIGIT_9,
    Equal => GHOSTTY_KEY_EQUAL,
    A => GHOSTTY_KEY_A,
    B => GHOSTTY_KEY_B,
    C => GHOSTTY_KEY_C,
    D => GHOSTTY_KEY_D,
    E => GHOSTTY_KEY_E,
    F => GHOSTTY_KEY_F,
    G => GHOSTTY_KEY_G,
    H => GHOSTTY_KEY_H,
    I => GHOSTTY_KEY_I,
    J => GHOSTTY_KEY_J,
    K => GHOSTTY_KEY_K,
    L => GHOSTTY_KEY_L,
    M => GHOSTTY_KEY_M,
    N => GHOSTTY_KEY_N,
    O => GHOSTTY_KEY_O,
    P => GHOSTTY_KEY_P,
    Q => GHOSTTY_KEY_Q,
    R => GHOSTTY_KEY_R,
    S => GHOSTTY_KEY_S,
    T => GHOSTTY_KEY_T,
    U => GHOSTTY_KEY_U,
    V => GHOSTTY_KEY_V,
    W => GHOSTTY_KEY_W,
    X => GHOSTTY_KEY_X,
    Y => GHOSTTY_KEY_Y,
    Z => GHOSTTY_KEY_Z,
    Minus => GHOSTTY_KEY_MINUS,
    Period => GHOSTTY_KEY_PERIOD,
    Quote => GHOSTTY_KEY_QUOTE,
    Semicolon => GHOSTTY_KEY_SEMICOLON,
    Slash => GHOSTTY_KEY_SLASH,
    Backspace => GHOSTTY_KEY_BACKSPACE,
    Enter => GHOSTTY_KEY_ENTER,
    Space => GHOSTTY_KEY_SPACE,
    Tab => GHOSTTY_KEY_TAB,
    Delete => GHOSTTY_KEY_DELETE,
    End => GHOSTTY_KEY_END,
    Home => GHOSTTY_KEY_HOME,
    Insert => GHOSTTY_KEY_INSERT,
    PageDown => GHOSTTY_KEY_PAGE_DOWN,
    PageUp => GHOSTTY_KEY_PAGE_UP,
    ArrowDown => GHOSTTY_KEY_ARROW_DOWN,
    ArrowLeft => GHOSTTY_KEY_ARROW_LEFT,
    ArrowRight => GHOSTTY_KEY_ARROW_RIGHT,
    ArrowUp => GHOSTTY_KEY_ARROW_UP,
    Numpad0 => GHOSTTY_KEY_NUMPAD_0,
    Numpad1 => GHOSTTY_KEY_NUMPAD_1,
    Numpad2 => GHOSTTY_KEY_NUMPAD_2,
    Numpad3 => GHOSTTY_KEY_NUMPAD_3,
    Numpad4 => GHOSTTY_KEY_NUMPAD_4,
    Numpad5 => GHOSTTY_KEY_NUMPAD_5,
    Numpad6 => GHOSTTY_KEY_NUMPAD_6,
    Numpad7 => GHOSTTY_KEY_NUMPAD_7,
    Numpad8 => GHOSTTY_KEY_NUMPAD_8,
    Numpad9 => GHOSTTY_KEY_NUMPAD_9,
    NumpadAdd => GHOSTTY_KEY_NUMPAD_ADD,
    NumpadBackspace => GHOSTTY_KEY_NUMPAD_BACKSPACE,
    NumpadComma => GHOSTTY_KEY_NUMPAD_COMMA,
    NumpadDecimal => GHOSTTY_KEY_NUMPAD_DECIMAL,
    NumpadDivide => GHOSTTY_KEY_NUMPAD_DIVIDE,
    NumpadEnter => GHOSTTY_KEY_NUMPAD_ENTER,
    NumpadEqual => GHOSTTY_KEY_NUMPAD_EQUAL,
    NumpadMultiply => GHOSTTY_KEY_NUMPAD_MULTIPLY,
    NumpadSubtract => GHOSTTY_KEY_NUMPAD_SUBTRACT,
    NumpadUp => GHOSTTY_KEY_NUMPAD_UP,
    NumpadDown => GHOSTTY_KEY_NUMPAD_DOWN,
    NumpadRight => GHOSTTY_KEY_NUMPAD_RIGHT,
    NumpadLeft => GHOSTTY_KEY_NUMPAD_LEFT,
    NumpadBegin => GHOSTTY_KEY_NUMPAD_BEGIN,
    NumpadHome => GHOSTTY_KEY_NUMPAD_HOME,
    NumpadEnd => GHOSTTY_KEY_NUMPAD_END,
    NumpadInsert => GHOSTTY_KEY_NUMPAD_INSERT,
    NumpadDelete => GHOSTTY_KEY_NUMPAD_DELETE,
    NumpadPageUp => GHOSTTY_KEY_NUMPAD_PAGE_UP,
    NumpadPageDown => GHOSTTY_KEY_NUMPAD_PAGE_DOWN,
    Escape => GHOSTTY_KEY_ESCAPE,
    F1 => GHOSTTY_KEY_F1,
    F2 => GHOSTTY_KEY_F2,
    F3 => GHOSTTY_KEY_F3,
    F4 => GHOSTTY_KEY_F4,
    F5 => GHOSTTY_KEY_F5,
    F6 => GHOSTTY_KEY_F6,
    F7 => GHOSTTY_KEY_F7,
    F8 => GHOSTTY_KEY_F8,
    F9 => GHOSTTY_KEY_F9,
    F10 => GHOSTTY_KEY_F10,
    F11 => GHOSTTY_KEY_F11,
    F12 => GHOSTTY_KEY_F12,
    F13 => GHOSTTY_KEY_F13,
    F14 => GHOSTTY_KEY_F14,
    F15 => GHOSTTY_KEY_F15,
    F16 => GHOSTTY_KEY_F16,
    F17 => GHOSTTY_KEY_F17,
    F18 => GHOSTTY_KEY_F18,
    F19 => GHOSTTY_KEY_F19,
    F20 => GHOSTTY_KEY_F20,
}

#[derive(Debug, Clone, Copy, Default, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct ProtocolModifiers {
    shift: bool,
    control: bool,
    alt: bool,
    #[serde(rename = "super")]
    super_key: bool,
    caps_lock: bool,
    num_lock: bool,
}

impl ProtocolModifiers {
    fn try_from_ghostty(mods: Mods) -> anyhow::Result<Self> {
        let known = Mods::SHIFT.0
            | Mods::CTRL.0
            | Mods::ALT.0
            | Mods::SUPER.0
            | Mods::CAPS_LOCK.0
            | Mods::NUM_LOCK.0;
        if mods.0 & !known != 0 {
            anyhow::bail!("unsupported terminal modifier bits");
        }
        Ok(Self {
            shift: mods.contains(Mods::SHIFT),
            control: mods.contains(Mods::CTRL),
            alt: mods.contains(Mods::ALT),
            super_key: mods.contains(Mods::SUPER),
            caps_lock: mods.contains(Mods::CAPS_LOCK),
            num_lock: mods.contains(Mods::NUM_LOCK),
        })
    }

    fn into_ghostty(self) -> Mods {
        let mut mods = Mods::default();
        for (enabled, flag) in [
            (self.shift, Mods::SHIFT),
            (self.control, Mods::CTRL),
            (self.alt, Mods::ALT),
            (self.super_key, Mods::SUPER),
            (self.caps_lock, Mods::CAPS_LOCK),
            (self.num_lock, Mods::NUM_LOCK),
        ] {
            if enabled {
                mods = mods | flag;
            }
        }
        mods
    }
}

/// Validated key input carried over the clear-history control protocol for
/// authoritative terminal-mode encoding.
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct ProtocolKeyInput {
    key: ProtocolKey,
    mods: ProtocolModifiers,
    consumed_mods: ProtocolModifiers,
    #[serde(default)]
    composing: bool,
    utf8: String,
    unshifted_codepoint: Option<char>,
    #[serde(default)]
    shifted_codepoint: Option<char>,
    #[serde(default)]
    base_layout_codepoint: Option<char>,
    action: Option<ProtocolKeyAction>,
    macos_option_as_alt: bool,
}

#[derive(Debug, Clone, Copy, Deserialize, Serialize)]
#[serde(rename_all = "kebab-case")]
enum ProtocolKeyAction {
    Press,
    Release,
    Repeat,
}

fn validate_protocol_key_text(text: &str) -> anyhow::Result<()> {
    if text.len() > PROTOCOL_KEY_TEXT_MAX_BYTES {
        anyhow::bail!("terminal key text exceeds the 4 KiB protocol limit");
    }
    if text.chars().any(char::is_control) {
        anyhow::bail!("terminal key text contains control characters");
    }
    Ok(())
}

impl TryFrom<&KeyInput> for ProtocolKeyInput {
    type Error = anyhow::Error;

    fn try_from(input: &KeyInput) -> Result<Self, Self::Error> {
        validate_protocol_key_text(&input.utf8)?;
        let unshifted_codepoint = match input.unshifted_codepoint {
            0 => None,
            codepoint => Some(
                char::from_u32(codepoint)
                    .ok_or_else(|| anyhow::anyhow!("invalid unshifted key codepoint"))?,
            ),
        };
        let shifted_codepoint = match input.shifted_codepoint {
            0 => None,
            codepoint => Some(
                char::from_u32(codepoint)
                    .ok_or_else(|| anyhow::anyhow!("invalid shifted key codepoint"))?,
            ),
        };
        let base_layout_codepoint = match input.base_layout_codepoint {
            0 => None,
            codepoint => Some(
                char::from_u32(codepoint)
                    .ok_or_else(|| anyhow::anyhow!("invalid base-layout key codepoint"))?,
            ),
        };
        Ok(Self {
            key: ProtocolKey::try_from(input.key)?,
            mods: ProtocolModifiers::try_from_ghostty(input.mods)?,
            consumed_mods: ProtocolModifiers::try_from_ghostty(input.consumed_mods)?,
            composing: input.composing,
            utf8: input.utf8.clone(),
            unshifted_codepoint,
            shifted_codepoint,
            base_layout_codepoint,
            action: input.action.map(|action| match action {
                KeyAction::Press => ProtocolKeyAction::Press,
                KeyAction::Release => ProtocolKeyAction::Release,
                KeyAction::Repeat => ProtocolKeyAction::Repeat,
            }),
            macos_option_as_alt: input.macos_option_as_alt,
        })
    }
}

impl TryFrom<ProtocolKeyInput> for KeyInput {
    type Error = anyhow::Error;

    fn try_from(input: ProtocolKeyInput) -> Result<Self, Self::Error> {
        validate_protocol_key_text(&input.utf8)?;
        let mods = input.mods.into_ghostty();
        let consumed_mods = input.consumed_mods.into_ghostty();
        if consumed_mods.0 & !mods.0 != 0 {
            anyhow::bail!("consumed terminal modifiers are not active");
        }
        if !input.macos_option_as_alt
            && (!mods.contains(Mods::ALT) || !consumed_mods.contains(Mods::ALT))
        {
            anyhow::bail!("consumed macOS Option requires an active Alt modifier");
        }
        Ok(Self {
            key: input.key.into(),
            mods,
            consumed_mods,
            composing: input.composing,
            utf8: input.utf8,
            unshifted_codepoint: input.unshifted_codepoint.map_or(0, char::into),
            shifted_codepoint: input.shifted_codepoint.map_or(0, char::into),
            base_layout_codepoint: input.base_layout_codepoint.map_or(0, char::into),
            action: input.action.map(|action| match action {
                ProtocolKeyAction::Press => KeyAction::Press,
                ProtocolKeyAction::Release => KeyAction::Release,
                ProtocolKeyAction::Repeat => KeyAction::Repeat,
            }),
            macos_option_as_alt: input.macos_option_as_alt,
        })
    }
}

pub(crate) fn encode_terminal_host_clear_history(
    fallback_key: Option<&KeyInput>,
) -> anyhow::Result<Vec<u8>> {
    let fallback_key = fallback_key.map(ProtocolKeyInput::try_from).transpose()?;
    Ok(serde_json::to_vec(&fallback_key)?)
}

pub(crate) fn decode_terminal_host_clear_history(
    payload: &[u8],
) -> anyhow::Result<Option<KeyInput>> {
    let fallback_key: Option<ProtocolKeyInput> = serde_json::from_slice(payload)?;
    fallback_key.map(KeyInput::try_from).transpose()
}
