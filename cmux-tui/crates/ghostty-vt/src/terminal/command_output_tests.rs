use super::*;

fn shell() -> Terminal {
    Terminal::new(40, 10, 10_000, Callbacks::default()).unwrap()
}

/// One prompt, a submitted command, its output and `D;code`, then the next prompt.
fn run(term: &mut Terminal, command: &str, output: &str, code: i32) {
    term.vt_write(format!("\x1b]133;A\x07$ \x1b]133;B\x07{command}\r\n\x1b]133;C\x07").as_bytes());
    term.vt_write(output.as_bytes());
    term.vt_write(format!("\x1b]133;D;{code}\x07").as_bytes());
}

fn prompt(term: &mut Terminal) {
    term.vt_write(b"\x1b]133;A\x07$ \x1b]133;B\x07");
}

#[test]
fn reads_the_command_and_its_output_above_the_prompt() {
    let mut term = shell();
    run(&mut term, "ls", "a\r\nb\r\n", 0);
    run(&mut term, "cargo test", "error[E0425]: x\r\nerror: could not compile\r\n", 101);
    prompt(&mut term);
    let last = term.last_command_output(100).unwrap();
    assert_eq!(last.command.as_deref(), Some("cargo test"));
    assert_eq!(last.output, "error[E0425]: x\nerror: could not compile");
    assert!(!last.truncated);
}

#[test]
fn a_command_without_output_reads_empty_and_keeps_its_command() {
    let mut term = shell();
    run(&mut term, "echo hi", "hi\r\n", 0);
    run(&mut term, "false", "", 1);
    prompt(&mut term);
    let last = term.last_command_output(100).unwrap();
    assert_eq!(last.command.as_deref(), Some("false"));
    assert_eq!(last.output, "");
}

#[test]
fn typing_at_the_new_prompt_does_not_change_the_read() {
    let mut term = shell();
    run(&mut term, "make", "boom\r\n", 2);
    prompt(&mut term);
    term.vt_write(b"git st");
    let last = term.last_command_output(100).unwrap();
    assert_eq!(last.command.as_deref(), Some("make"));
    assert_eq!(last.output, "boom");
}

/// A prompt drawn where the cursor is (`133;P`, no `133;A` fresh line), as a shell that skips its own newline does.
fn prompt_in_place(term: &mut Terminal) {
    term.vt_write(b"\x1b]133;P;k=i\x07$ \x1b]133;B\x07");
}

#[test]
fn output_without_a_final_newline_ends_on_the_prompt_row() {
    // `133;A` moves a prompt that would start mid-row to a fresh line, so the output keeps its own row.
    let mut term = shell();
    run(&mut term, "printf foo", "foo", 1);
    prompt(&mut term);
    assert_eq!(term.last_command_output(100).unwrap().output, "foo");

    // A prompt drawn in place shares the output's last row: "foo$ ".
    let mut term = shell();
    run(&mut term, "printf foo", "foo", 1);
    prompt_in_place(&mut term);
    let last = term.last_command_output(100).unwrap();
    assert_eq!(last.command.as_deref(), Some("printf foo"));
    assert_eq!(last.output, "foo");

    let mut term = shell();
    run(&mut term, "make", "one\r\ntwo", 2);
    prompt_in_place(&mut term);
    assert_eq!(term.last_command_output(100).unwrap().output, "one\ntwo");
}

#[test]
fn long_output_keeps_the_newest_rows() {
    let mut term = shell();
    let output: String = (1..=50).map(|line| format!("line {line}\r\n")).collect();
    run(&mut term, "seq", &output, 1);
    prompt(&mut term);
    let last = term.last_command_output(5).unwrap();
    assert!(last.truncated);
    assert_eq!(last.command, None, "the input is past the scanned rows");
    assert_eq!(last.output, "line 46\nline 47\nline 48\nline 49\nline 50");
}

#[test]
fn no_read_without_shell_integration_or_while_a_command_runs() {
    let mut term = shell();
    term.vt_write(b"$ ls\r\na\r\n$ ");
    assert_eq!(term.last_command_output(100), None, "no marks");

    let mut term = shell();
    term.vt_write(b"\x1b]133;A\x07$ \x1b]133;B\x07sleep 9\r\n\x1b]133;C\x07working\r\n");
    assert_eq!(term.last_command_output(100), None, "the cursor is in output");
}
