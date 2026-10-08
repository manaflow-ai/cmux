//! Sanitizers for human (non-JSON) CLI output: terminal controls in server
//! strings render as inert text.

/// Visible placeholder for characters a terminal could interpret as part of
/// a control or escape sequence. Remote-supplied strings (browser titles,
/// terminal titles set by programs, workspace and notification names) flow
/// into human output and must render as inert text.
const CONTROL_PLACEHOLDER: char = '\u{fffd}';

/// C0 controls, DEL, C1 controls, and the Unicode line and paragraph
/// separators. Written raw, any of these can alter terminal state or break
/// the line structure of human output. Callers decide which whitespace
/// controls keep a meaning before falling through to this check.
fn is_terminal_control(ch: char) -> bool {
    matches!(ch, '\u{0}'..='\u{1f}' | '\u{7f}'..='\u{9f}' | '\u{2028}' | '\u{2029}')
}

/// Sanitize a single-line human cell. CR and LF keep the visible `\n` escape
/// so multi-line values stay on one table row; every other control character,
/// including TAB, becomes a placeholder so the cell-width padding stays
/// correct. Width math must always use the sanitized string.
pub(super) fn sanitize_human_cell(value: &str) -> String {
    let mut sanitized = String::with_capacity(value.len());
    for ch in value.chars() {
        match ch {
            '\r' | '\n' => sanitized.push_str("\\n"),
            ch if is_terminal_control(ch) => sanitized.push(CONTROL_PLACEHOLDER),
            ch => sanitized.push(ch),
        }
    }
    sanitized
}

/// Sanitize multi-line human text (top-level strings, error messages). LF and
/// TAB keep their meaning, CRLF collapses to LF, and a lone CR becomes a
/// placeholder because it can rewrite the current line.
pub(super) fn sanitize_human_block(value: &str) -> String {
    let mut sanitized = String::with_capacity(value.len());
    let mut chars = value.chars().peekable();
    while let Some(ch) = chars.next() {
        match ch {
            '\n' | '\t' => sanitized.push(ch),
            '\r' if chars.peek() == Some(&'\n') => {}
            ch if is_terminal_control(ch) => sanitized.push(CONTROL_PLACEHOLDER),
            ch => sanitized.push(ch),
        }
    }
    sanitized
}
