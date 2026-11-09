//! A classic terminal's saved scrollback as the text its new shell prints
//! once above its first prompt (`CMUX_RESTORE_SCROLLBACK_FILE`, read by the
//! shell layer). The text is read-only output: only printable text, line
//! breaks, tabs and color (SGR) sequences come back, so a saved title,
//! clipboard, hyperlink or mode change never runs again. The app only writes
//! it to a file only its user can read.

/// Classic's own limits for a restored terminal.
pub const MAX_CHARACTERS: usize = 400_000;
pub const MAX_LINES: usize = 4000;

/// The output to print for `scrollback`: the newest lines within the
/// limits, colors reset before and after, ending on a fresh line. None when
/// nothing printable is left.
pub fn replay(scrollback: &str) -> Option<String> {
    let clean = printable(scrollback);
    let mut lines: Vec<&str> = clean.split('\n').collect();
    while lines.last().is_some_and(|line| line.is_empty()) {
        lines.pop();
    }
    if lines.is_empty() {
        return None;
    }
    let start = lines.len().saturating_sub(MAX_LINES);
    let mut kept = &lines[start..];
    let mut count: usize = kept.iter().map(|line| line.chars().count() + 1).sum();
    while count > MAX_CHARACTERS && kept.len() > 1 {
        count -= kept[0].chars().count() + 1;
        kept = &kept[1..];
    }
    let body = kept.join("\n");
    let length = body.chars().count();
    let text = if length > MAX_CHARACTERS {
        body.chars().skip(length - MAX_CHARACTERS).collect()
    } else {
        body
    };
    // Reset before (a cut sequence) and after (a color still on).
    Some(format!("\u{1b}[0m{text}\u{1b}[0m\n"))
}

/// Printable text, `\n`, tabs and SGR sequences; `\r\n` becomes `\n`.
/// Every other control character and escape sequence is dropped.
fn printable(scrollback: &str) -> String {
    let chars: Vec<char> = scrollback.chars().collect();
    let mut out = String::with_capacity(scrollback.len());
    let mut index = 0;
    while index < chars.len() {
        let scalar = chars[index];
        index += 1;
        match scalar as u32 {
            0x0A | 0x09 => out.push(scalar),
            0x1B => index = escape(&chars, index, &mut out),
            0x00..=0x1F | 0x7F..=0x9F => {}
            _ => out.push(scalar),
        }
    }
    out
}

/// Skips the escape sequence after an ESC at `start - 1`, keeping it in
/// `out` only when it is SGR; returns where the text resumes.
fn escape(chars: &[char], start: usize, out: &mut String) -> usize {
    let Some(&first) = chars.get(start) else { return start };
    let within = |index: usize, range: std::ops::RangeInclusive<u32>| {
        chars.get(index).is_some_and(|c| range.contains(&(*c as u32)))
    };
    match first {
        '[' => {
            // CSI: parameters and intermediates, then one final byte.
            let mut end = start + 1;
            while within(end, 0x20..=0x3F) {
                end += 1;
            }
            if !within(end, 0x40..=0x7E) {
                return end;
            }
            let parameters = &chars[start + 1..end];
            if chars[end] == 'm' && parameters.iter().all(|c| (0x30..=0x3B).contains(&(*c as u32)))
            {
                out.push('\u{1b}');
                out.extend(&chars[start..=end]);
            }
            end + 1
        }
        ']' | 'P' | 'X' | '^' | '_' => {
            // OSC, DCS, SOS, PM, APC: a string up to BEL or ST (`ESC \`).
            let mut end = start + 1;
            while end < chars.len() {
                if chars[end] == '\u{07}' {
                    return end + 1;
                }
                // ST ends it; another ESC ends it and starts its own sequence.
                if chars[end] == '\u{1b}' {
                    return if chars.get(end + 1) == Some(&'\\') { end + 2 } else { end };
                }
                end += 1;
            }
            end
        }
        _ => {
            // Intermediates, then one final character (charset, keypad, save cursor, ...).
            let mut end = start;
            while within(end, 0x20..=0x2F) {
                end += 1;
            }
            if end < chars.len() { end + 1 } else { end }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn wrapped(text: &str) -> String {
        format!("\u{1b}[0m{text}\u{1b}[0m\n")
    }

    #[test]
    fn text_and_colors_come_back_and_line_endings_become_newlines() {
        assert_eq!(
            replay("$ make test\r\n\u{1b}[32mall 12 passed\u{1b}[0m\r\n\n").as_deref(),
            Some(wrapped("$ make test\n\u{1b}[32mall 12 passed\u{1b}[0m").as_str())
        );
        assert_eq!(replay("a\tb").as_deref(), Some(wrapped("a\tb").as_str()));
    }

    /// A saved title, clipboard write, hyperlink, mode change or cursor move never runs again.
    #[test]
    fn every_other_sequence_and_control_is_dropped() {
        let saved = "\u{1b}]0;title\u{07}\u{1b}]52;c;cGFzdGU=\u{1b}\\\u{1b}]8;;https://x\u{07}link\
                     \u{1b}]8;;\u{07}\u{1b}[?1049h\u{1b}[2J\u{1b}[1;31mred\u{1b}(B\u{1b}7\u{07}\u{08}\u{9b}x\
                     \u{1b}Pdcs\u{1b}\\\u{1b}_apc\u{1b}[0m";
        assert_eq!(
            replay(saved).as_deref(),
            Some(wrapped("link\u{1b}[1;31mredx\u{1b}[0m").as_str())
        );
        // An unterminated string is dropped to the end; a string cut by ESC hands over to it.
        assert_eq!(replay("ok\u{1b}]0;never ends").as_deref(), Some(wrapped("ok").as_str()));
        assert_eq!(
            replay("\u{1b}]0;t\u{1b}[31mx").as_deref(),
            Some(wrapped("\u{1b}[31mx").as_str())
        );
        // A CSI with a non-SGR parameter byte (private mode) is not color.
        assert_eq!(replay("\u{1b}[?25ma").as_deref(), Some(wrapped("a").as_str()));
    }

    #[test]
    fn nothing_printable_is_none() {
        assert_eq!(replay(""), None);
        assert_eq!(replay("\n\r\n\u{1b}]0;title\u{07}\u{07}"), None);
    }

    #[test]
    fn the_newest_lines_within_the_limits_are_kept() {
        let many: Vec<String> = (0..MAX_LINES + 10).map(|n| format!("line {n}")).collect();
        let text = replay(&many.join("\n")).unwrap();
        let body = text.trim_start_matches("\u{1b}[0m").trim_end_matches("\u{1b}[0m\n");
        assert_eq!(body.lines().count(), MAX_LINES);
        assert!(
            body.starts_with("line 10\n") && body.ends_with(&format!("line {}", MAX_LINES + 9))
        );

        // Whole lines go first, oldest first, while more than one is left.
        let long = format!("old\n{}\nnew", "x".repeat(MAX_CHARACTERS));
        let text = replay(&long).unwrap();
        assert_eq!(text, "\u{1b}[0mnew\u{1b}[0m\n");
        // One line over the limit keeps its tail.
        let line = format!("{}end", "x".repeat(MAX_CHARACTERS));
        let text = replay(&line).unwrap();
        let body = text.trim_start_matches("\u{1b}[0m").trim_end_matches("\u{1b}[0m\n");
        assert_eq!(body.chars().count(), MAX_CHARACTERS);
        assert!(body.ends_with("end"));
    }
}
