//! Helpers for copying process stderr into user-visible text.

/// Remove terminal control sequences and the prefix emitted by tracing's compact formatter.
///
/// Process stderr remains available in its raw form for logs and transcript entries. Callers
/// use this only when they copy a line into an error or diagnostic shown to a person.
pub(crate) fn clean_stderr_line(line: &str) -> String {
    let line = strip_ansi(line);
    let line = line.trim();
    let line = strip_tracing_prefix(line);
    line.trim().to_owned()
}

fn strip_ansi(input: &str) -> String {
    let mut output = String::with_capacity(input.len());
    let mut chars = input.chars().peekable();

    while let Some(ch) = chars.next() {
        match ch {
            '\x1b' => match chars.peek().copied() {
                Some('[') => {
                    chars.next();
                    while let Some(next) = chars.next() {
                        if ('@'..='~').contains(&next) {
                            break;
                        }
                    }
                }
                Some(']') => {
                    chars.next();
                    loop {
                        match chars.next() {
                            None | Some('\x07') | Some('\u{009c}') => break,
                            Some('\x1b') if chars.peek() == Some(&'\\') => {
                                chars.next();
                                break;
                            }
                            Some(_) => {}
                        }
                    }
                }
                Some(next) if ('0'..='~').contains(&next) => {
                    // A two-byte escape sequence (for example, ESC 7 or ESC c).
                    chars.next();
                }
                Some(next) if ('!'..='/').contains(&next) => {
                    // An escape sequence with intermediate bytes, such as ESC ( B.
                    chars.next();
                    while let Some(next) = chars.next() {
                        if ('0'..='~').contains(&next) {
                            break;
                        }
                    }
                }
                // A lone ESC or an unknown sequence should not make the error unreadable. Keep
                // the following ordinary character.
                _ => {}
            },
            '\u{009b}' => {
                while let Some(next) = chars.next() {
                    if ('@'..='~').contains(&next) {
                        break;
                    }
                }
            }
            '\u{009d}' => loop {
                match chars.next() {
                    None | Some('\x07') | Some('\u{009c}') => break,
                    Some('\x1b') if chars.peek() == Some(&'\\') => {
                        chars.next();
                        break;
                    }
                    Some(_) => {}
                }
            },
            '\u{009c}' | '\r' => {}
            _ => output.push(ch),
        }
    }

    output
}

fn strip_tracing_prefix(mut line: &str) -> &str {
    if let Some(rest) = strip_timestamp(line) {
        line = rest.trim_start();
    }
    if let Some(rest) = strip_level(line) {
        line = rest.trim_start();
    }
    line
}

fn strip_timestamp(line: &str) -> Option<&str> {
    let end = line.find(char::is_whitespace).unwrap_or(line.len());
    let token = &line[..end];
    let bytes = token.as_bytes();
    let timestamp = bytes.len() >= 20
        && digits(bytes, 0..4)
        && bytes[4] == b'-'
        && digits(bytes, 5..7)
        && bytes[7] == b'-'
        && digits(bytes, 8..10)
        && matches!(bytes[10], b'T' | b't')
        && bytes[13] == b':'
        && bytes[16] == b':'
        && digits(bytes, 11..13)
        && digits(bytes, 14..16)
        && digits(bytes, 17..19);
    timestamp.then(|| &line[end..])
}

fn digits(bytes: &[u8], mut range: std::ops::Range<usize>) -> bool {
    range.all(|at| bytes.get(at).is_some_and(|byte| byte.is_ascii_digit()))
}

fn strip_level(line: &str) -> Option<&str> {
    let end = line.find(char::is_whitespace).unwrap_or(line.len());
    let level = &line[..end];
    matches!(level, "ERROR" | "WARN" | "WARNING" | "INFO" | "DEBUG" | "TRACE").then(|| &line[end..])
}

#[cfg(test)]
mod tests {
    use super::clean_stderr_line;

    #[test]
    fn strips_tracing_timestamp_level_and_ansi() {
        let line = "\x1b[2m2026-10-25T01:44:57Z\x1b[0m \x1b[31mERROR\x1b[0m \x1b[2mcodex_models_manager::manager: failed to refresh available models: request timed out\x1b[0m";
        assert_eq!(
            clean_stderr_line(line),
            "codex_models_manager::manager: failed to refresh available models: request timed out"
        );
        assert_eq!(
            format!("request timed out (codex): {}", clean_stderr_line(line)),
            "request timed out (codex): codex_models_manager::manager: failed to refresh available models: request timed out"
        );
    }

    #[test]
    fn strips_osc_sequences() {
        assert_eq!(
            clean_stderr_line("\x1b]8;;https://example.com\x1b\\request timed out\x1b]8;;\x1b\\"),
            "request timed out"
        );
        assert_eq!(clean_stderr_line("\x1b]title\x07request timed out"), "request timed out");
        assert_eq!(
            clean_stderr_line("\u{009d}title\u{009c}request timed out"),
            "request timed out"
        );
    }

    #[test]
    fn strips_carriage_returns_from_progress_output() {
        assert_eq!(clean_stderr_line("phase 1\rphase 2"), "phase 1phase 2");
    }

    #[test]
    fn strips_lone_escape() {
        assert_eq!(clean_stderr_line("request\x1b timed out"), "request timed out");
        assert_eq!(clean_stderr_line("\x1b(Brequest timed out"), "request timed out");
        assert_eq!(clean_stderr_line("\x1b7\x1b8"), "");
        assert_eq!(clean_stderr_line("\x1b%G"), "");
    }

    #[test]
    fn a_line_containing_only_escapes_is_empty() {
        assert!(clean_stderr_line("\x1b[31m\x1b]title\x07").is_empty());
        assert!(clean_stderr_line("\x1b(B\x1b[m").is_empty());
    }
}
