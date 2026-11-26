use std::fmt::Write;

/// Maximum UTF-8 byte length of one untrusted field in terminal diagnostics.
pub(crate) const DIAGNOSTIC_FIELD_MAX_BYTES: usize = 256;

/// Make an untrusted protocol field safe for one terminal output line.
///
/// Control characters are rendered as visible escapes. The result is bounded
/// by UTF-8 bytes and ends with an ellipsis when text was omitted. Protocol
/// validation stays at the wire boundary; this function changes display only.
pub(crate) fn terminal_text(value: &str) -> String {
    terminal_text_with_limit(value, DIAGNOSTIC_FIELD_MAX_BYTES)
}

fn terminal_text_with_limit(value: &str, max_bytes: usize) -> String {
    let mut output = String::with_capacity(value.len().min(max_bytes));
    let mut units = Vec::new();
    let mut truncated = false;

    for character in value.chars() {
        let escaped = escape_character(character);
        if output.len() + escaped.len() > max_bytes {
            truncated = true;
            break;
        }
        output.push_str(&escaped);
        units.push(escaped);
    }

    if truncated {
        const ELLIPSIS: &str = "…";
        while output.len() + ELLIPSIS.len() > max_bytes {
            let Some(unit) = units.pop() else { break };
            output.truncate(output.len() - unit.len());
        }
        if ELLIPSIS.len() <= max_bytes {
            output.push_str(ELLIPSIS);
        }
    }

    output
}

fn escape_character(character: char) -> String {
    match character {
        '\n' => "\\n".to_owned(),
        '\r' => "\\r".to_owned(),
        '\t' => "\\t".to_owned(),
        '\u{2028}' | '\u{2029}' => unicode_escape(character),
        '\u{061c}'
        | '\u{200e}'
        | '\u{200f}'
        | '\u{202a}'..='\u{202e}'
        | '\u{2066}'..='\u{2069}' => unicode_escape(character),
        character if character.is_control() => unicode_escape(character),
        character => character.to_string(),
    }
}

fn unicode_escape(character: char) -> String {
    let mut escaped = String::new();
    write!(&mut escaped, "\\u{{{:X}}}", character as u32).expect("write to String");
    escaped
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn terminal_text_escapes_terminal_controls_and_preserves_unicode() {
        let input = "safe 日本語 🐈\x1b]0;owned\x07\rforged\nline\u{009b}31m";

        assert_eq!(
            terminal_text(input),
            "safe 日本語 🐈\\u{1B}]0;owned\\u{7}\\rforged\\nline\\u{9B}31m"
        );
    }

    #[test]
    fn terminal_text_escapes_visual_line_and_direction_controls() {
        assert_eq!(
            terminal_text("left\u{2028}right\u{202e}hidden"),
            "left\\u{2028}right\\u{202E}hidden"
        );
    }

    #[test]
    fn terminal_text_is_byte_bounded_without_splitting_unicode() {
        assert_eq!(terminal_text_with_limit("éééé", 7), "éé…");
        assert_eq!(terminal_text_with_limit("\x1bAAAA", 9), "\\u{1B}…");
        assert_eq!(terminal_text_with_limit("AAAA\x1b", 8), "AAAA…");
        assert!(terminal_text(&"界".repeat(200)).len() <= DIAGNOSTIC_FIELD_MAX_BYTES);
    }
}
