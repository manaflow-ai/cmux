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
mod tests {
    use super::*;

    #[test]
    fn hub_text_is_printed_without_control_characters() {
        assert_eq!(printable("Ann's Mac"), "Ann's Mac");
        assert_eq!(printable("\u{1b}[2J\u{1b}[31mEvil\u{1b}[0m"), "Evil");
        assert_eq!(printable("a\u{1b}]0;title\u{7}b"), "ab");
        assert_eq!(printable("x\ny\rz\t\u{0}\u{7f}\u{9b}1m"), "xyz1m");
        assert_eq!(printable("\u{202e}cod.exe\u{202c}\u{2066}\u{200f}"), "cod.exe");
    }
}
