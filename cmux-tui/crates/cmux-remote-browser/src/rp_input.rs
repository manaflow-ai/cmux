//! Viewer input (`cmux.rb/1` [`InputEvent`]) to calls of the CEF fork's
//! remote presentation ABI (`include/cef_cmux.h` in manaflow-ai/cef:
//! `cmux_rp_send_key`, `cmux_rp_send_wheel`, `cmux_rp_send_pinch`,
//! `cmux_rp_surface_send_mouse`, `CefBrowserHost::Ime*`). Pure: the r2 host
//! (remote-tab-r2.md) runs these calls on the CEF UI thread. Vectors:
//! `schemas/remote-tab/input-mapping.json`.

use serde::{Deserialize, Serialize};

use crate::proto::{InputEvent, Phase, PointerKind, Underline, modifiers};

/// `CMUX_RP_MOD_*` bits of `cef_cmux.h`.
pub mod rp_mod {
    pub const SHIFT: i32 = 1;
    pub const CONTROL: i32 = 1 << 1;
    pub const OPTION: i32 = 1 << 2;
    pub const COMMAND: i32 = 1 << 3;
    pub const CAPS_LOCK: i32 = 1 << 4;
    pub const REPEAT: i32 = 1 << 5;
}

/// Most edit commands one key may carry.
pub const MAX_EDIT_COMMANDS: usize = 8;
/// Blink keeps 3 UTF-16 units of key text (`WebKeyboardEvent::kTextLengthCap`
/// is 4 with the terminator). Longer text is IME text: use `ime_commit`.
pub const MAX_KEY_TEXT_UNITS: usize = 3;

/// One call into the fork, with C ABI values.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "call", rename_all = "snake_case")]
pub enum RpCall {
    SendKey {
        down: bool,
        code: String,
        key: String,
        text: String,
        unmodified_text: String,
        modifiers: i32,
        commands: Vec<(String, String)>,
    },
    SendWheel {
        x: f64,
        y: f64,
        dx: f64,
        dy: f64,
        precise: bool,
        phase: i32,
        momentum_phase: i32,
        modifiers: i32,
    },
    SendPinch {
        phase: i32,
        scale: f64,
        x: f64,
        y: f64,
    },
    /// `CefBrowserHost::SendMouseMoveEvent` / `SendMouseClickEvent` (page).
    PageMouse {
        kind: i32,
        x: f64,
        y: f64,
        button: i32,
        click_count: i32,
        modifiers: i32,
    },
    /// `cmux_rp_surface_send_mouse` (popup surface).
    SurfaceMouse {
        surface: u32,
        kind: i32,
        x: f64,
        y: f64,
        button: i32,
        click_count: i32,
        modifiers: i32,
    },
    ImeSetComposition {
        text: String,
        underlines: Vec<Underline>,
        selection_start: u32,
        selection_end: u32,
        replacement: Option<[u32; 2]>,
    },
    ImeCommit {
        text: String,
        replacement: Option<[u32; 2]>,
    },
    ImeFinish {
        keep_selection: bool,
    },
    ImeCancel,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum InputReject {
    /// A key with no or a malformed DOM code.
    BadCode,
    /// Key text longer than Blink keeps; send it as `ime_commit`.
    TextTooLong,
    /// Too many or malformed edit commands.
    BadEditCommands,
    /// Pinch phases are began, changed, ended or cancelled.
    BadPhase,
    /// Popup surfaces take pointer input only.
    SurfaceInputUnsupported,
    /// A coordinate or scale that is not a finite number.
    NotFinite,
}

/// `CMUX_RP_PHASE_*` of `cef_cmux.h`.
pub fn rp_phase(phase: Phase) -> i32 {
    match phase {
        Phase::None => 0,
        Phase::MayBegin => 1,
        Phase::Began => 2,
        Phase::Changed => 3,
        Phase::Ended => 4,
        Phase::Cancelled => 5,
    }
}

/// `cmux.rb/1` modifier bits to `CMUX_RP_MOD_*` (Fn has no web equivalent).
pub fn rp_modifiers(rb: u32, repeat: bool) -> i32 {
    let mut out = 0;
    for (from, to) in [
        (modifiers::SHIFT, rp_mod::SHIFT),
        (modifiers::CONTROL, rp_mod::CONTROL),
        (modifiers::OPTION, rp_mod::OPTION),
        (modifiers::COMMAND, rp_mod::COMMAND),
        (modifiers::CAPS_LOCK, rp_mod::CAPS_LOCK),
    ] {
        if rb & from != 0 {
            out |= to;
        }
    }
    if repeat {
        out |= rp_mod::REPEAT;
    }
    out
}

fn finite(values: &[f64]) -> Result<(), InputReject> {
    if values.iter().all(|v| v.is_finite()) { Ok(()) } else { Err(InputReject::NotFinite) }
}

fn valid_code(code: &str) -> bool {
    !code.is_empty() && code.len() <= 32 && code.bytes().all(|b| b.is_ascii_alphanumeric())
}

fn valid_command_name(name: &str) -> bool {
    !name.is_empty() && name.len() <= 64 && name.bytes().all(|b| b.is_ascii_alphanumeric())
}

fn pointer_kind(kind: PointerKind) -> Option<i32> {
    match kind {
        PointerKind::Move => Some(0),
        PointerKind::Down => Some(1),
        PointerKind::Up => Some(2),
        // Enter and leave are moves for the page; the ABI has no separate call.
        PointerKind::Enter | PointerKind::Leave => Some(0),
    }
}

/// Maps one viewer input event to the fork call that applies it.
pub fn map_input(event: &InputEvent) -> Result<RpCall, InputReject> {
    match event {
        InputEvent::Key {
            surface,
            down,
            code,
            key,
            text,
            unmodified_text,
            modifiers,
            repeat,
            edit_commands,
            ..
        } => {
            if *surface != 0 {
                return Err(InputReject::SurfaceInputUnsupported);
            }
            if !valid_code(code) {
                return Err(InputReject::BadCode);
            }
            if text.encode_utf16().count() > MAX_KEY_TEXT_UNITS
                || unmodified_text.encode_utf16().count() > MAX_KEY_TEXT_UNITS
            {
                return Err(InputReject::TextTooLong);
            }
            if edit_commands.len() > MAX_EDIT_COMMANDS
                || !edit_commands.iter().all(|c| valid_command_name(&c.name))
            {
                return Err(InputReject::BadEditCommands);
            }
            Ok(RpCall::SendKey {
                down: *down,
                code: code.clone(),
                key: key.clone(),
                text: if *down { text.clone() } else { String::new() },
                unmodified_text: if *down { unmodified_text.clone() } else { String::new() },
                modifiers: rp_modifiers(*modifiers, *repeat),
                commands: if *down {
                    edit_commands.iter().map(|c| (c.name.clone(), c.value.clone())).collect()
                } else {
                    Vec::new()
                },
            })
        }
        InputEvent::Pointer { surface, kind, x, y, button, click_count, modifiers, .. } => {
            finite(&[*x, *y])?;
            let kind = pointer_kind(*kind).unwrap_or(0);
            let modifiers = rp_modifiers(*modifiers, false);
            let button = i32::from(*button);
            let click_count = i32::from(*click_count);
            if *surface != 0 {
                Ok(RpCall::SurfaceMouse {
                    surface: *surface,
                    kind,
                    x: *x,
                    y: *y,
                    button,
                    click_count,
                    modifiers,
                })
            } else {
                Ok(RpCall::PageMouse { kind, x: *x, y: *y, button, click_count, modifiers })
            }
        }
        InputEvent::Wheel { surface, x, y, dx, dy, precise, phase, momentum_phase, modifiers } => {
            if *surface != 0 {
                return Err(InputReject::SurfaceInputUnsupported);
            }
            finite(&[*x, *y, *dx, *dy])?;
            Ok(RpCall::SendWheel {
                x: *x,
                y: *y,
                dx: *dx,
                dy: *dy,
                precise: *precise,
                phase: rp_phase(*phase),
                momentum_phase: rp_phase(*momentum_phase),
                modifiers: rp_modifiers(*modifiers, false),
            })
        }
        InputEvent::Pinch { surface, phase, scale, x, y } => {
            if *surface != 0 {
                return Err(InputReject::SurfaceInputUnsupported);
            }
            finite(&[*scale, *x, *y])?;
            if matches!(phase, Phase::None | Phase::MayBegin) || *scale <= 0.0 {
                return Err(InputReject::BadPhase);
            }
            Ok(RpCall::SendPinch { phase: rp_phase(*phase), scale: *scale, x: *x, y: *y })
        }
        InputEvent::ImeSetComposition {
            surface,
            text,
            underlines,
            selection_start,
            selection_end,
            replacement,
        } => {
            if *surface != 0 {
                return Err(InputReject::SurfaceInputUnsupported);
            }
            Ok(RpCall::ImeSetComposition {
                text: text.clone(),
                underlines: underlines.clone(),
                selection_start: *selection_start,
                selection_end: *selection_end,
                replacement: *replacement,
            })
        }
        InputEvent::ImeCommit { surface, text, replacement } => {
            if *surface != 0 {
                return Err(InputReject::SurfaceInputUnsupported);
            }
            Ok(RpCall::ImeCommit { text: text.clone(), replacement: *replacement })
        }
        InputEvent::ImeFinish { surface, keep_selection } => {
            if *surface != 0 {
                return Err(InputReject::SurfaceInputUnsupported);
            }
            Ok(RpCall::ImeFinish { keep_selection: *keep_selection })
        }
        InputEvent::ImeCancel { surface } => {
            if *surface != 0 {
                return Err(InputReject::SurfaceInputUnsupported);
            }
            Ok(RpCall::ImeCancel)
        }
    }
}
