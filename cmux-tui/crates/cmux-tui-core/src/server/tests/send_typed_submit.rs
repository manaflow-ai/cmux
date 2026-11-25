//! `send-typed-submit-v1`: the phone's composer sends a one-line draft for a full-screen program
//! as typed text and Return in one `send` (Leo, 2026-11-21: "the text goes through. But then the
//! send doesn't go through"). Return then waits past an agent's paste-burst window after the
//! text, as the phone's separate Return did; after a paste the PTY writer's pacer waits instead.

use super::*;

#[test]
fn the_daemon_lists_typed_submit() {
    assert!(advertised_capabilities(false).contains(&"send-typed-submit-v1"));
}

#[test]
fn return_waits_past_the_paste_burst_window_after_typed_text_only() {
    assert_eq!(cmd_terminal_io::submit_wait(false, true), Duration::from_millis(250));
    assert!(cmd_terminal_io::submit_wait(false, true) > Duration::from_millis(120));
    // A paste: `paste_pacing` holds Return until the program read it.
    assert_eq!(cmd_terminal_io::submit_wait(true, true), Duration::ZERO);
    // A bare Return.
    assert_eq!(cmd_terminal_io::submit_wait(false, false), Duration::ZERO);
}
