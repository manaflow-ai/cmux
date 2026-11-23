//! `cmux terminal <t> copy` prints the copied text as plain text, the way
//! `terminal <t> screen read` does (bench round 4 item 10, W5-R): it printed
//! a key/value table, with the text on one row and its newlines escaped.
//! `--json` keeps the record.

use super::*;

fn line_shown(text: &str, wanted: &str) -> bool {
    text.lines().any(|line| line.trim_end() == wanted)
}

#[test]
fn w5r_terminal_copy_prints_plain_text_and_json_keeps_the_record() {
    let server = HeadlessServer::start("w5r-copy-text");
    let created = json_cli(&server, &["tab", "create", "terminal"]);
    assert_success(&created);
    let terminal = json_output(&created)["value"]["terminal_id"].as_str().unwrap().to_string();
    let typed = json_cli(
        &server,
        &["terminal", &terminal, "write", "--text", "echo w5r-one; echo w5r-two\n"],
    );
    assert_success(&typed);
    // The typed line also names both words; only the output has the second
    // alone on its line. The daemon's screen wait answers when it arrives.
    let shown = json_cli(
        &server,
        &[
            "terminal",
            &terminal,
            "screen",
            "wait",
            "--pattern",
            "^w5r-two\\s*$",
            "--timeout-ms",
            "20000",
        ],
    );
    assert_success(&shown);

    for mode in ["scrollback", "screen"] {
        let copied = cli(&server, &["terminal", &terminal, "copy", "--mode", mode]);
        assert_success(&copied);
        let stdout = String::from_utf8_lossy(&copied.stdout);
        assert!(
            line_shown(&stdout, "w5r-one") && line_shown(&stdout, "w5r-two"),
            "copy --mode {mode} did not print the text as lines: {stdout:?}"
        );
        assert!(
            !stdout.lines().any(|line| line.starts_with("mode ") || line.starts_with("text ")),
            "copy --mode {mode} printed a key/value table: {stdout:?}"
        );

        let record = json_cli(&server, &["terminal", &terminal, "copy", "--mode", mode]);
        assert_success(&record);
        let record = json_output(&record);
        assert_eq!(record["mode"], mode, "{record}");
        assert!(line_shown(record["text"].as_str().unwrap_or_default(), "w5r-two"), "{record}");
    }
}
