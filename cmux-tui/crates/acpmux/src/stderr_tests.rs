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
    assert_eq!(clean_stderr_line("\u{009d}title\u{009c}request timed out"), "request timed out");
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
