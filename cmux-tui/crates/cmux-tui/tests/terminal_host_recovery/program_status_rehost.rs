//! cx-6so.36.10: OSC 7501 program status records survive a host replacement
//! followed by a daemon restart. The daemon seeds the replacement host with
//! its records, so the next daemon adopts them from that host: a tab that
//! showed "blocked" before both still shows it, with the same `updated_seq`.

use super::host_replacement::{wait_for_daemon_custody, wait_for_replacement};
use super::pty_custody::{signal_pid, wait_for_dead_host};
use super::*;
use crate::program_status_restart::{program_status, wait_for_program_status, without_since};

#[test]
fn program_status_records_survive_a_host_replacement_then_a_daemon_restart() {
    let _exclusive = exclusive_process_test();
    let mut harness = RecoveryHarness::start("program-status-rehost");
    let created = request(
        &harness.socket,
        serde_json::json!({
            "id": 1,
            "cmd": "run",
            "argv": [
                "/bin/sh",
                "-c",
                concat!(
                    // "Plan" asks "Apply?"; a finished build sits beside it.
                    "printf '\\033]7501;state=blocked:kind=permission:id=plan:app=terraform:title=UGxhbg==:msg=QXBwbHk/\\033\\\\'; ",
                    "printf '\\033]7501;state=done:id=build:app=make\\033\\\\'; ",
                    "printf 'reported\\r\\n'; sleep 600",
                ),
            ],
            "new_workspace": true,
            "name": "program-status-rehosted",
            "cols": 80,
            "rows": 8,
        }),
    );
    let surface = created["surface"].as_u64().unwrap();
    let terminal_id = created["terminal_id"].as_str().unwrap().to_string();
    let incarnation = created["terminal_incarnation"].as_str().unwrap().to_string();
    assert!(wait_for_screen(&harness.socket, surface, "reported").contains("reported"));
    let before = wait_for_program_status(&harness, 2);
    assert_eq!(before[1]["state"], "blocked", "{before}");
    let (record_path, record) = wait_for_host_records(&harness.host_root(), 1).remove(0);
    wait_for_daemon_custody(&harness, true);

    // The host dies under the running daemon, which replaces it on the
    // same shell; the program reports nothing more.
    signal_pid(record.host_pid, libc::SIGKILL);
    wait_for_dead_host(&record_path, &record);
    let replacement = wait_for_replacement(&harness, &record);
    assert_eq!(replacement.incarnation, incarnation);

    harness.sigkill();
    harness.restart();
    let resolved = wait_for_terminal_lifecycle(&harness.socket, &terminal_id, "running");
    assert_eq!(resolved["terminal_incarnation"], incarnation.as_str(), "{resolved}");

    let after = wait_for_program_status(&harness, 2);
    assert_eq!(
        without_since(after),
        without_since(before),
        "program status changed across the replacement and restart"
    );

    request(
        &harness.socket,
        serde_json::json!({
            "id": 3,
            "cmd": "close-terminal",
            "terminal_id": terminal_id,
            "terminal_incarnation": incarnation,
        }),
    );
    wait_for_no_host_records(&harness.host_root());
}

/// cx-6so.36.11: the reconnect to the replacement host replays its screen
/// into the daemon's mirror, through the parser that feeds the live records.
/// The screen held a prompt mark (OSC 133;A) before the program's report;
/// the replay must not end the record: the program still waits. (The VT
/// replay carries no OSC 133 marks today; this keeps it so.)
#[test]
fn a_prompt_mark_in_the_reconnect_replay_keeps_a_waiting_programs_record() {
    let _exclusive = exclusive_process_test();
    let harness = RecoveryHarness::start("program-status-reconnect-replay");
    let created = request(
        &harness.socket,
        serde_json::json!({
            "id": 1,
            "cmd": "run",
            "argv": [
                "/bin/sh",
                "-c",
                concat!(
                    // A shell prompt (OSC 133;A), then a program it ran asks
                    // "Apply?" and waits.
                    "printf '\\033]133;A\\007$ apply\\r\\n'; ",
                    "printf '\\033]7501;state=blocked:kind=permission:id=plan:app=terraform\\033\\\\'; ",
                    "printf 'reported\\r\\n'; sleep 600",
                ),
            ],
            "new_workspace": true,
            "name": "program-status-replayed",
            "cols": 80,
            "rows": 8,
        }),
    );
    let surface = created["surface"].as_u64().unwrap();
    let terminal_id = created["terminal_id"].as_str().unwrap().to_string();
    let incarnation = created["terminal_incarnation"].as_str().unwrap().to_string();
    assert!(wait_for_screen(&harness.socket, surface, "reported").contains("reported"));
    let before = wait_for_program_status(&harness, 1);
    assert_eq!(before[0]["state"], "blocked", "{before}");
    let (record_path, record) = wait_for_host_records(&harness.host_root(), 1).remove(0);
    wait_for_daemon_custody(&harness, true);

    signal_pid(record.host_pid, libc::SIGKILL);
    wait_for_dead_host(&record_path, &record);
    wait_for_replacement(&harness, &record);
    // Typed text the terminal echoes back reaches the daemon only through
    // the replacement host: the reconnect, and its replay, are done.
    request(
        &harness.socket,
        serde_json::json!({"cmd":"send","surface":surface,"text":"reconnected"}),
    );
    assert!(wait_for_screen(&harness.socket, surface, "reconnected").contains("reconnected"));

    let after = program_status(&harness);
    assert_eq!(after, before, "the reconnect replay ended the waiting program's record");

    request(
        &harness.socket,
        serde_json::json!({
            "id": 3,
            "cmd": "close-terminal",
            "terminal_id": terminal_id,
            "terminal_incarnation": incarnation,
        }),
    );
    wait_for_no_host_records(&harness.host_root());
}
