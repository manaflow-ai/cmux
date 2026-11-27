//! Text from the hub or a viewer, made safe to print to a terminal or the journal.

/// Bidi formatting characters: they reorder what a terminal shows (U+202E turns a name
/// around) though `char::is_control` does not count them.
pub fn is_bidi_control(c: char) -> bool {
    matches!(
        c,
        '\u{061c}' | '\u{200e}' | '\u{200f}' | '\u{202a}'..='\u{202e}' | '\u{2066}'..='\u{2069}'
    )
}

/// Text from the hub or a viewer, safe to print to a terminal or the journal: C0 and C1
/// controls, whole ANSI escape sequences (CSI, OSC and the like) and bidi controls removed.
pub fn printable(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut chars = text.chars().peekable();
    while let Some(c) = chars.next() {
        match c {
            '\u{1b}' => match chars.next() {
                // CSI: parameters and intermediates, then one final character in @..~.
                Some('[') => {
                    for c in chars.by_ref() {
                        if ('@'..='~').contains(&c) {
                            break;
                        }
                    }
                }
                // OSC, DCS, SOS, PM, APC: a string ended by BEL or ESC \.
                Some(']' | 'P' | 'X' | '^' | '_') => {
                    while let Some(c) = chars.next() {
                        if c == '\u{7}' {
                            break;
                        }
                        if c == '\u{1b}' {
                            if chars.peek() == Some(&'\\') {
                                chars.next();
                            }
                            break;
                        }
                    }
                }
                // A two-character escape (ESC c, ESC 7, ...).
                _ => {}
            },
            c if c.is_control() || is_bidi_control(c) => {}
            c => out.push(c),
        }
    }
    out
}

#[cfg(test)]
#[path = "text_tests.rs"]
mod tests;
