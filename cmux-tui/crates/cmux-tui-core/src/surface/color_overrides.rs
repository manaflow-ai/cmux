//! Terminal color overrides: apply them to a terminal and encode the VT bytes
//! that move a mirror from one override state to the next.

use super::*;

pub(super) fn terminal_color_override_full_state(next: &TerminalColorOverrides) -> Vec<u8> {
    let mut output = if next.cursor_visual.is_some() { b"\x1b[0 q".to_vec() } else { Vec::new() };
    output.extend_from_slice(&terminal_color_override_delta(&Default::default(), next));
    output
}

/// Apply one complete terminal-host Colors state to a local libghostty parser.
/// Snapshot replay intentionally leaves embedder defaults local while this
/// helper restores application-authored dynamic colors, palette entries, and
/// cursor semantics at the advertised sequence boundary.
pub fn apply_terminal_color_overrides(terminal: &mut Terminal, colors: &TerminalColorOverrides) {
    let transition = terminal_color_override_full_state(colors);
    if !transition.is_empty() {
        terminal.vt_write(&transition);
    }
}

pub(super) fn terminal_color_overrides_match_applied(
    mut observed: TerminalColorOverrides,
    applied: &TerminalColorOverrides,
) -> bool {
    // Version 1 has no cursor metadata. Its cursor state is carried only by
    // ordinary VT output, so it must not trip the sparse-color iff contract.
    if applied.cursor_visual.is_none() {
        observed.cursor_visual = None;
    }
    observed == *applied
}

pub(super) fn terminal_color_override_delta(
    previous: &TerminalColorOverrides,
    next: &TerminalColorOverrides,
) -> Vec<u8> {
    fn dynamic_color(output: &mut Vec<u8>, set_code: u16, reset_code: u16, color: Option<Rgb>) {
        match color {
            Some(color) => output.extend_from_slice(
                format!(
                    "\x1b]{set_code};rgb:{:02x}/{:02x}/{:02x}\x1b\\",
                    color.r, color.g, color.b
                )
                .as_bytes(),
            ),
            None => output.extend_from_slice(format!("\x1b]{reset_code}\x1b\\").as_bytes()),
        }
    }

    let mut output = Vec::new();
    if previous.foreground != next.foreground {
        dynamic_color(&mut output, 10, 110, next.foreground);
    }
    if previous.background != next.background {
        dynamic_color(&mut output, 11, 111, next.background);
    }
    if previous.cursor != next.cursor {
        dynamic_color(&mut output, 12, 112, next.cursor);
    }
    // Version 1 has no cursor metadata, so absence means unknown/preserve for
    // live deltas. Every v2 pair is force-applied even when byte-identical:
    // cursor activity may have switched/reset per-screen storage in between.
    if let Some(cursor_visual) = next.cursor_visual {
        let value = match cursor_visual {
            (CursorShape::Block | CursorShape::BlockHollow, true) => 1,
            (CursorShape::Block | CursorShape::BlockHollow, false) => 2,
            (CursorShape::Underline, true) => 3,
            (CursorShape::Underline, false) => 4,
            (CursorShape::Bar, true) => 5,
            (CursorShape::Bar, false) => 6,
        };
        output.extend_from_slice(format!("\x1b[{value} q").as_bytes());
    }
    for index in 0..256 {
        if previous.palette[index] == next.palette[index] {
            continue;
        }
        match next.palette[index] {
            Some(color) => output.extend_from_slice(
                format!("\x1b]4;{index};rgb:{:02x}/{:02x}/{:02x}\x1b\\", color.r, color.g, color.b)
                    .as_bytes(),
            ),
            None => output.extend_from_slice(format!("\x1b]104;{index}\x1b\\").as_bytes()),
        }
    }
    output
}
