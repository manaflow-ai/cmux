//! Host terminal modes: the canonical terminal content rect, outer cursor
//! escapes, startup input modes, and host mouse capture sequences.

use cmux_tui_core::Rect;
use crossterm::event::{
    DisableMouseCapture, EnableBracketedPaste, EnableFocusChange, EnableMouseCapture,
};
use ghostty_vt::CursorShape;

use crate::app::pointer::deferred::OuterCursorSpec;

pub(super) fn canonical_terminal_content(content: Rect, rendered_size: Option<(u16, u16)>) -> Rect {
    let (cols, rows) = rendered_size.unwrap_or((content.width, content.height));
    Rect {
        x: content.x,
        y: content.y,
        width: content.width.min(cols),
        height: content.height.min(rows),
    }
}

pub(super) fn outer_cursor_escape_if_changed(
    applied: Option<OuterCursorSpec>,
    desired: OuterCursorSpec,
) -> Option<String> {
    (applied != Some(desired)).then(|| outer_cursor_escape(desired))
}

/// Host input modes asserted at client startup, before any inner-terminal
/// state is known. A scoped single-terminal attach (`attach --terminal`) is a
/// transparent passthrough: it must not assert mouse capture or the
/// shift-bypass report on the host, because the host terminal owns clicks and
/// selection until the inner application requests mouse tracking. Focus
/// reporting and bracketed paste stay enabled in both modes: the client
/// consumes those events itself and re-encodes paste for the inner terminal
/// according to the mode the inner application actually requested, so they
/// are transparent to the user.
pub(super) fn host_startup_input_modes(surface_only: bool) -> String {
    let mut out = String::new();
    if !surface_only {
        out.push_str(&host_mouse_capture_sequence(true));
    }
    let _ = crossterm::Command::write_ansi(&EnableFocusChange, &mut out);
    let _ = crossterm::Command::write_ansi(&EnableBracketedPaste, &mut out);
    out
}

pub(super) fn host_mouse_capture_sequence(enable: bool) -> String {
    let mut out = String::new();
    if enable {
        let _ = crossterm::Command::write_ansi(&EnableMouseCapture, &mut out);
        // Ask the host terminal to report Shift-modified mouse events so
        // Shift remains cmux's selection/context-menu escape while the inner
        // application owns ordinary mouse input.
        out.push_str("\x1b[>1s");
    } else {
        // Restore the conventional behavior where Shift bypasses capture.
        out.push_str("\x1b[>0s");
        let _ = crossterm::Command::write_ansi(&DisableMouseCapture, &mut out);
    }
    out
}

pub(super) fn host_mouse_capture_escape_if_changed(
    applied: Option<bool>,
    desired: bool,
) -> Option<String> {
    (applied != Some(desired)).then(|| host_mouse_capture_sequence(desired))
}

/// Initial host-cursor bookkeeping. A full TUI starts with unknown applied
/// state, so its first frame restores host cursor globals to defaults. A
/// scoped attach starts from an applied Reset so it emits no cursor escapes
/// until the inner application authors a cursor style.
pub(super) fn initial_applied_outer_cursor(surface_only: bool) -> Option<OuterCursorSpec> {
    surface_only.then_some(OuterCursorSpec::Reset)
}

/// Startup already asserted capture for full-TUI clients and asserted
/// nothing for scoped attach clients.
pub(super) fn initial_host_mouse_capture(surface_only: bool) -> Option<bool> {
    Some(!surface_only)
}

pub(super) fn outer_cursor_escape(spec: OuterCursorSpec) -> String {
    match spec {
        OuterCursorSpec::Reset => "\x1b]112\x07\x1b[0 q".to_string(),
        OuterCursorSpec::Terminal { color, shape, blinking } => {
            let style = match (shape, blinking) {
                (CursorShape::Block, true) => 1,
                (CursorShape::Block, false) => 2,
                (CursorShape::Underline, true) => 3,
                (CursorShape::Underline, false) => 4,
                (CursorShape::Bar, true) => 5,
                (CursorShape::Bar, false) => 6,
                // DECSCUSR has no hollow-block form. A steady block preserves
                // shape and avoids inventing blink behavior.
                (CursorShape::BlockHollow, _) => 2,
            };
            format!("\x1b]12;#{:02x}{:02x}{:02x}\x07\x1b[{style} q", color.r, color.g, color.b)
        }
    }
}
