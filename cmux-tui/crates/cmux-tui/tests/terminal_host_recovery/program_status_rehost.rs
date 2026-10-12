//! cx-6so.36.10: OSC 7501 program status records survive a host replacement
//! followed by a daemon restart. The daemon seeds the replacement host with
//! its records, so the next daemon adopts them from that host: a tab that
//! showed "blocked" before both still shows it, with the same `updated_seq`.

use super::host_replacement::wait_for_replacement;
use super::pty_custody::{signal_pid, wait_for_dead_host};
use super::*;
use crate::program_status_restart::wait_for_program_status;

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
    super::host_replacement::wait_for_daemon_custody(&harness, true);

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
    assert_eq!(after, before, "program status changed across the replacement and restart");

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
