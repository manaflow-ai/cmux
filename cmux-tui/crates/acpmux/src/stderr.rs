//! Helpers for copying process stderr into user-visible text.

/// Remove terminal control sequences and the prefix emitted by tracing's compact formatter.
///
/// Process stderr remains available in its raw form for logs and transcript entries. Callers
/// use this only when they copy a line into an error or diagnostic shown to a person.
pub(crate) fn clean_stderr_line(line: &str) -> String {
    clean_stripped_line(&strip_ansi(line))
}

/// Each line of `text` as [`clean_stderr_line`] cleans it, with control sequences removed from the
/// whole text first: a string control's payload (DCS, OSC, SOS, PM, APC) may span lines, and none
/// of it may reach the person. Empty lines stay, so callers keep their own filtering.
pub(crate) fn clean_stderr_lines(text: &str) -> Vec<String> {
    strip_ansi(text).lines().map(clean_stripped_line).collect()
}

/// [`clean_stderr_lines`] for stderr already split into lines (a session's stderr tail).
pub(crate) fn clean_stderr_tail<'a>(lines: impl IntoIterator<Item = &'a String>) -> Vec<String> {
    clean_stderr_lines(&lines.into_iter().map(String::as_str).collect::<Vec<_>>().join("\n"))
}

fn clean_stripped_line(line: &str) -> String {
    strip_tracing_prefix(line.trim()).trim().to_owned()
}

/// Whether `text` ends inside a string control (DCS, OSC, SOS, PM, APC) that has not reached its
/// terminator yet: the lines after it are still that control's payload.
pub(crate) fn ends_inside_string_control(text: &str) -> bool {
    open_string_control(text).is_some()
}

/// The string control `text` ends inside, if any.
pub(crate) fn open_string_control(text: &str) -> Option<StringControl> {
    strip(text).1
}

/// A string control's kind, which decides its terminators: OSC ends at ST or BEL; DCS, SOS, PM
/// and APC end only at ST (ECMA-48), so a BEL in their payload is payload.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum StringControl {
    Osc,
    Other,
}

/// The byte offset just past the first terminator of `control` in `line` (C1 ST or ESC \\, and
/// BEL for OSC), for a line that continues that open control; None when it has none.
pub(crate) fn string_control_end(line: &str, control: StringControl) -> Option<usize> {
    let mut chars = line.char_indices().peekable();
    while let Some((at, ch)) = chars.next() {
        match ch {
            '\u{009c}' => return Some(at + ch.len_utf8()),
            '\x07' if control == StringControl::Osc => return Some(at + 1),
            '\x1b' if chars.peek().is_some_and(|&(_, next)| next == '\\') => return Some(at + 2),
            _ => {}
        }
    }
    None
}

fn strip_ansi(input: &str) -> String {
    strip(input).0
}

/// The text without control sequences, and the string control it ends inside, if any.
fn strip(input: &str) -> (String, Option<StringControl>) {
    let mut open = None;
    let mut output = String::with_capacity(input.len());
    let mut chars = input.chars().peekable();

    while let Some(ch) = chars.next() {
        match ch {
            '\x1b' => match chars.peek().copied() {
                Some('[') => {
                    chars.next();
                    skip_through_final(&mut chars, '@'..='~');
                }
                // OSC, and the string controls DCS, SOS, PM and APC: their payload runs to their
                // terminator.
                Some(kind @ (']' | 'P' | 'X' | '^' | '_')) => {
                    chars.next();
                    let control =
                        if kind == ']' { StringControl::Osc } else { StringControl::Other };
                    open = (!skip_string(&mut chars, control)).then_some(control);
                }
                Some(next) if ('0'..='~').contains(&next) => {
                    // A two-byte escape sequence (for example, ESC 7 or ESC c).
                    chars.next();
                }
                // ESC SP takes only F, G, L, M or N (7- or 8-bit controls, conformance levels); any
                // other ESC SP is a lone ESC before a space, which the text keeps.
                Some(' ') => {
                    let mut ahead = chars.clone();
                    ahead.next();
                    if ahead.next().is_some_and(|last| matches!(last, 'F' | 'G' | 'L' | 'M' | 'N'))
                    {
                        chars.next();
                        chars.next();
                    }
                }
                Some(next) if ('!'..='/').contains(&next) => {
                    // An escape sequence with intermediate bytes, such as ESC ( B.
                    chars.next();
                    skip_through_final(&mut chars, '0'..='~');
                }
                // A lone ESC or an unknown sequence should not make the error unreadable. Keep
                // the following ordinary character.
                _ => {}
            },
            '\u{009b}' => skip_through_final(&mut chars, '@'..='~'),
            '\u{009d}' | '\u{0090}' | '\u{0098}' | '\u{009e}' | '\u{009f}' => {
                let control =
                    if ch == '\u{009d}' { StringControl::Osc } else { StringControl::Other };
                open = (!skip_string(&mut chars, control)).then_some(control);
            }
            '\u{009c}' | '\r' => {}
            _ => output.push(ch),
        }
    }

    (output, open)
}

/// Skips a CSI or escape sequence through its final byte in `finals`. An ESC or a C1 control
/// inside it cancels it and starts the next sequence (ECMA-48), so it is left for the caller:
/// `ESC [ ESC ] ... BEL` is a cut-short CSI and then an OSC, whose payload must go too.
fn skip_through_final(
    chars: &mut std::iter::Peekable<std::str::Chars<'_>>,
    finals: std::ops::RangeInclusive<char>,
) {
    while let Some(&next) = chars.peek() {
        if next == '\x1b' || ('\u{0080}'..='\u{009f}').contains(&next) {
            return;
        }
        chars.next();
        if finals.contains(&next) {
            return;
        }
    }
}

/// Skips a string control's payload through its terminator: ST (ESC \\ or C1 ST), or BEL for
/// OSC. False when the text ended first.
fn skip_string(
    chars: &mut std::iter::Peekable<std::str::Chars<'_>>,
    control: StringControl,
) -> bool {
    loop {
        match chars.next() {
            None => return false,
            Some('\u{009c}') => return true,
            Some('\x07') if control == StringControl::Osc => return true,
            Some('\x1b') if chars.peek() == Some(&'\\') => {
                chars.next();
                return true;
            }
            Some(_) => {}
        }
    }
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
    fn strips_string_controls_with_their_payloads() {
        // DCS, SOS, PM and APC carry a payload up to ST (terminal graphics, for one).
        for introducer in ['P', 'X', '^', '_'] {
            let line = format!("\x1b{introducer}secret\x1b\\error");
            assert_eq!(clean_stderr_line(&line), "error", "ESC {introducer}");
        }
        assert_eq!(clean_stderr_line("\x1b_Gi=1;AAAA\x1b\\request timed out"), "request timed out");
        for introducer in ['\u{0090}', '\u{0098}', '\u{009e}', '\u{009f}'] {
            let line = format!("{introducer}secret\u{009c}error");
            assert_eq!(clean_stderr_line(&line), "error", "C1 {:?}", introducer);
        }
    }

    #[test]
    fn a_string_control_spanning_lines_leaks_nothing() {
        use super::{clean_stderr_lines, clean_stderr_tail, ends_inside_string_control};
        // The payload's newlines go with it.
        assert_eq!(
            clean_stderr_lines("\x1bPsecret\nleaked \x1b\\visible error"),
            vec!["visible error"]
        );
        assert_eq!(clean_stderr_lines("\x1b]8;;https://x\ny\x07ok\nnext"), vec!["ok", "next"]);
        let tail =
            vec!["\x1b_Gpayload".to_owned(), "more payload\x1b\\request timed out".to_owned()];
        assert_eq!(clean_stderr_tail(&tail), vec!["request timed out"]);
        assert!(ends_inside_string_control("ok \x1bPsecret"));
        assert!(!ends_inside_string_control("\x1bPsecret\x1b\\ok"));
        assert!(!ends_inside_string_control("\x1b[31mplain"));
    }

    #[test]
    fn an_escape_inside_a_sequence_starts_the_next_one() {
        assert_eq!(clean_stderr_line("\x1b[\x1b]secret\x07error"), "error");
        assert_eq!(clean_stderr_line("\x1b[31\x1bPsecret\x1b\\error"), "error");
        assert_eq!(clean_stderr_line("\x1b(\x1b]secret\x07error"), "error");
        assert_eq!(clean_stderr_line("\u{009b}1\u{009d}secret\u{009c}error"), "error");
        assert_eq!(clean_stderr_line("\x1b[1mbold\x1b[0m error"), "bold error");
    }

    #[test]
    fn only_osc_ends_at_bel() {
        use super::{StringControl, ends_inside_string_control, string_control_end};
        assert_eq!(clean_stderr_line("\x1bPsecret\x07still-secret\x1b\\visible"), "visible");
        assert_eq!(clean_stderr_line("\x1b_Ga\x07b\u{009c}visible"), "visible");
        assert_eq!(clean_stderr_line("\x1b]title\x07visible"), "visible");
        assert!(ends_inside_string_control("\x1bPsecret\x07more"));
        assert_eq!(string_control_end("a\x07b\x1b\\c", StringControl::Other), Some(5));
        assert_eq!(string_control_end("a\x07b", StringControl::Osc), Some(2));
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
        assert_eq!(clean_stderr_line("\x1b Frequest timed out"), "request timed out");
    }

    #[test]
    fn a_line_containing_only_escapes_is_empty() {
        assert!(clean_stderr_line("\x1b[31m\x1b]title\x07").is_empty());
        assert!(clean_stderr_line("\x1b(B\x1b[m").is_empty());
    }
}
