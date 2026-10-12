//! A program killed while it tracks the mouse must not leave the shell's
//! prompt typing mouse reports, while a running program keeps its modes.
#![cfg(unix)]

use super::*;

/// Enables any-motion tracking with SGR reports, as a TUI does.
const TRACK_MOUSE: &str = r"\033[?1003h\033[?1006h";

fn terminal(server: &HeadlessServer) -> String {
    let created = json_cli(server, &["tab", "create", "terminal"]);
    assert_success(&created);
    json_output(&created)["value"]["terminal_id"].as_str().unwrap().to_string()
}

fn run(server: &HeadlessServer, terminal: &str, line: &str) {
    assert_success(&json_cli(server, &["terminal", terminal, "write", "--text", line]));
}

fn move_mouse(server: &HeadlessServer, terminal: &str) {
    for column in ["5", "6", "7"] {
        let moved = json_cli(
            server,
            &["terminal", terminal, "mouse", "move", "--row", "3", "--column", column],
        );
        assert_success(&moved);
    }
}

#[test]
fn a_killed_mouse_tracking_program_leaves_no_reports_at_the_prompt() {
    let server = HeadlessServer::start("mouse-reset-killed");
    let terminal = terminal(&server);
    run(&server, &terminal, &format!("sh -c 'printf \"{TRACK_MOUSE}\"; kill -9 $$'\n"));
    // The next command runs at the prompt the shell drew after the kill.
    run(&server, &terminal, "echo ready_$((2+3))\n");
    wait_for_screen(&server, &terminal, "ready_5");

    move_mouse(&server, &terminal);
    run(&server, &terminal, "echo after_$((3+1))\n");
    let screen = wait_for_screen(&server, &terminal, "after_4");
    assert!(screen.contains("after_4"), "the command after the moves did not run:\n{screen}");
    assert!(!screen.contains("35;"), "mouse moves typed reports into the shell:\n{screen}");
}

#[test]
fn a_running_program_keeps_its_mouse_reports_across_its_own_prompt_mark() {
    let server = HeadlessServer::start("mouse-reset-running");
    let terminal = terminal(&server);
    // The program prints a prompt mark itself while it is the foreground
    // job, then reads the first bytes of a report raw.
    run(
        &server,
        &terminal,
        &format!(
            "sh -c 'stty raw -echo; printf \"{TRACK_MOUSE}\\033]133;A\\007\"; \
             dd bs=1 count=3 2>/dev/null | od -An -c | tr -s \" \" _; \
             stty sane; printf \"\\033[?1003l\\033[?1006l\"; echo; echo read_$((1+1))'\n"
        ),
    );
    let deadline = Instant::now() + Duration::from_secs(30);
    let screen = loop {
        move_mouse(&server, &terminal);
        let screen = wait_for_screen(&server, &terminal, "read_2");
        if screen.contains("read_2") || Instant::now() > deadline {
            break screen;
        }
    };
    assert!(screen.contains("_033_[_<"), "the program never got its report:\n{screen}");
}
