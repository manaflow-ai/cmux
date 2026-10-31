//! Helpers for copying process stderr into user-visible text.

/// One line without its terminal control sequences or the prefix tracing's compact formatter adds.
/// Callers clean whole texts ([`clean_stderr_lines`]) or streams ([`StderrStream`]).
#[cfg(test)]
pub(crate) fn clean_stderr_line(line: &str) -> String {
    clean_stripped_line(&strip_ansi(line))
}

/// Each line of `text` without terminal control sequences or the prefix tracing's compact
/// formatter adds, with control sequences removed from the whole text first: a string control's payload (DCS, OSC, SOS, PM, APC) may span lines, and none
/// of it may reach the person. Empty lines stay, so callers keep their own filtering.
pub(crate) fn clean_stderr_lines(text: &str) -> Vec<String> {
    strip_ansi(text).lines().map(clean_stripped_line).collect()
}

/// One process's stderr, cleaned line by line as it arrives. A string control (DCS, OSC, SOS, PM,
/// APC) may run across lines, so the control a line ends inside is carried to the next line: its
/// payload never reads as text, however the stream is cut into lines, turns or buffers.
#[derive(Clone, Debug, Default)]
pub(crate) struct StderrStream {
    open: Option<StringControl>,
}

impl StderrStream {
    /// Whether the stream is inside a string control (its next line is still payload).
    pub(crate) fn is_open(&self) -> bool {
        self.open.is_some()
    }

    /// One line cleaned on its own, with no stream before it.
    pub(crate) fn clean_line_of(mut self, line: &str) -> String {
        self.clean_line(line)
    }

    /// `line` without control sequences or the tracing prefix, read as the continuation of every
    /// line before it.
    pub(crate) fn clean_line(&mut self, line: &str) -> String {
        let opener = match self.open {
            Some(StringControl::Osc) => "\x1b]",
            Some(StringControl::Other) => "\x1bP",
            None => "",
        };
        let (text, open) = strip(&format!("{opener}{line}"));
        self.open = open;
        clean_stripped_line(&text)
    }
}

fn clean_stripped_line(line: &str) -> String {
    strip_tracing_prefix(line.trim()).trim().to_owned()
}

/// A string control's kind, which decides its terminators: OSC ends at ST or BEL; DCS, SOS, PM
/// and APC end only at ST (ECMA-48), so a BEL in their payload is payload.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum StringControl {
    Osc,
    Other,
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
    let (token, rest) = line.split_once(char::is_whitespace).unwrap_or((line, ""));
    let bytes = token.as_bytes();
    let at = |index: usize| bytes.get(index).copied();
    let timestamp = bytes.len() >= 20
        && digits(bytes, 0..4)
        && at(4) == Some(b'-')
        && digits(bytes, 5..7)
        && at(7) == Some(b'-')
        && digits(bytes, 8..10)
        && matches!(at(10), Some(b'T' | b't'))
        && at(13) == Some(b':')
        && at(16) == Some(b':')
        && digits(bytes, 11..13)
        && digits(bytes, 14..16)
        && digits(bytes, 17..19);
    timestamp.then_some(rest)
}

fn digits(bytes: &[u8], mut range: std::ops::Range<usize>) -> bool {
    range.all(|at| bytes.get(at).is_some_and(|byte| byte.is_ascii_digit()))
}

fn strip_level(line: &str) -> Option<&str> {
    let (level, rest) = line.split_once(char::is_whitespace).unwrap_or((line, ""));
    matches!(level, "ERROR" | "WARN" | "WARNING" | "INFO" | "DEBUG" | "TRACE").then_some(rest)
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
        use super::{StderrStream, clean_stderr_lines};
        // The payload's newlines go with it.
        assert_eq!(
            clean_stderr_lines("\x1bPsecret\nleaked \x1b\\visible error"),
            vec!["visible error"]
        );
        assert_eq!(clean_stderr_lines("\x1b]8;;https://x\ny\x07ok\nnext"), vec!["ok", "next"]);
        let mut stream = StderrStream::default();
        let lines: Vec<String> = ["\x1b_Gpayload", "more payload", "end\x1b\\request timed out"]
            .into_iter()
            .map(|line| stream.clean_line(line))
            .collect();
        assert_eq!(lines, vec!["", "", "request timed out"]);
        // A BEL does not end a DCS, however the lines fall.
        let mut stream = StderrStream::default();
        assert_eq!(stream.clean_line("\x1bPsecret"), "");
        assert_eq!(stream.clean_line("\x07still-secret"), "");
        assert_eq!(stream.clean_line("\x1b\\shown"), "shown");
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
        assert_eq!(clean_stderr_line("\x1bPsecret\x07still-secret\x1b\\visible"), "visible");
        assert_eq!(clean_stderr_line("\x1b_Ga\x07b\u{009c}visible"), "visible");
        assert_eq!(clean_stderr_line("\x1b]title\x07visible"), "visible");
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
