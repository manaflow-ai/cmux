use super::*;

fn terminal(cols: u16, rows: u16) -> Terminal {
    Terminal::new(cols, rows, 10_000_000, Callbacks::default()).unwrap()
}

#[test]
fn read_run_logical_text_joins_a_soft_wrapped_line_and_keeps_hard_breaks() {
    let mut term = terminal(20, 10);
    let long = "x".repeat(70);
    term.vt_write(format!("first\r\n{long}\r\nlast\r\n").as_bytes());
    let wrapped = term.active_text().unwrap();
    assert!(wrapped.lines().filter(|line| line.starts_with('x')).count() > 1);
    let unwrapped = term.active_text_unwrapped().unwrap();
    let lines: Vec<&str> = unwrapped.lines().filter(|line| !line.is_empty()).collect();
    assert_eq!(lines, ["first", long.as_str(), "last"]);
}

#[test]
fn read_run_logical_text_last_lines_reads_across_scrollback_and_drops_trailing_blank_rows() {
    let mut term = terminal(20, 5);
    let output: String = (1..=40).map(|line| format!("line {line}\r\n")).collect();
    term.vt_write(output.as_bytes());
    let long = "y".repeat(300);
    term.vt_write(format!("{long}\r\ndone\r\n").as_bytes());
    assert_eq!(term.last_lines_text(3, true).unwrap(), format!("line 40\n{long}\ndone"));
    assert_eq!(term.last_lines_text(1, true).unwrap(), "done");
    // Rows, not logical lines, without unwrap: the long line's last row.
    let rows = term.last_lines_text(2, false).unwrap();
    assert_eq!(rows, format!("{}\ndone", "y".repeat(20)));
    // More lines than exist: everything, oldest first.
    let all = term.last_lines_text(10_000, true).unwrap();
    assert!(all.starts_with("line 1\n"));
    assert!(all.ends_with("done"));
}

#[test]
fn read_run_logical_text_after_anchor_skips_the_anchored_line_and_its_wrapped_echo() {
    let mut term = terminal(20, 6);
    term.vt_write(b"old BENCH_OK\r\n$ ");
    let anchor = term.anchor_cursor_line().unwrap();
    // The typed command echoes on the anchored line and wraps past it.
    let typed = format!("echo {} BENCH_OK", "z".repeat(30));
    term.vt_write(typed.as_bytes());
    term.vt_write(b"\r\n");
    assert_eq!(term.text_after_anchor(&anchor).unwrap().trim(), "");
    term.vt_write(b"step 1\r\nBENCH_OK\r\n$ ");
    let after = term.text_after_anchor(&anchor).unwrap();
    let lines: Vec<&str> = after.lines().collect();
    assert_eq!(lines.first().copied(), Some("step 1"));
    assert!(lines.contains(&"BENCH_OK"));
    assert!(!after.contains("echo"), "the typed command is not new output: {after:?}");
    assert!(!after.contains("old"), "older output is not new output: {after:?}");
}

#[test]
fn read_run_logical_text_after_anchor_follows_the_line_into_scrollback() {
    let mut term = terminal(20, 4);
    term.vt_write(b"$ cmd");
    let anchor = term.anchor_cursor_line().unwrap();
    let output: String = (1..=10).map(|line| format!("\r\nout {line}")).collect();
    term.vt_write(output.as_bytes());
    let after = term.text_after_anchor(&anchor).unwrap();
    let lines: Vec<&str> = after.lines().collect();
    assert_eq!(lines.first().copied(), Some("out 1"));
    assert_eq!(lines.last().copied(), Some("out 10"));
}
