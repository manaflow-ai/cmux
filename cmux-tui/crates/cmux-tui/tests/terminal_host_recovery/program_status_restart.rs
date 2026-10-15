//! cx-6so.36.6: OSC 7501 program status records survive a daemon restart.
//! The terminal host keeps them and hands them to the adopting daemon, so a
//! tab that showed "blocked" before the restart still shows it after.

use super::*;

/// `extra.program_status` of the harness's only terminal.
/// Without `updated_at_ms`: the host and the daemon each stamp a report
/// when their own parser reads it.
pub(super) fn program_status(harness: &RecoveryHarness) -> serde_json::Value {
    let terminals = resource_request(
        &harness.socket,
        "program-status-list",
        "terminal.list",
        serde_json::json!({"machine":"current","session":"current"}),
        None,
    );
    let terminals = terminals.as_array().unwrap();
    assert_eq!(terminals.len(), 1, "expected one terminal: {terminals:?}");
    let mut status = terminals[0]["extra"]["program_status"].clone();
    for record in status.as_array_mut().into_iter().flatten() {
        record.as_object_mut().unwrap().remove("updated_at_ms");
    }
    status
}

/// `status` without `since_ms`, to compare across a daemon restart: the
/// terminal-host snapshot does not carry it, so a restored record starts at
/// the host's own stamp (`ProgramStatusRecord::since_ms`), not the daemon's;
/// the two parsers read a report a few ms apart (cx-zskkw, macOS).
pub(super) fn without_since(mut status: serde_json::Value) -> serde_json::Value {
    for record in status.as_array_mut().into_iter().flatten() {
        record.as_object_mut().unwrap().remove("since_ms");
    }
    status
}

pub(super) fn wait_for_program_status(
    harness: &RecoveryHarness,
    records: usize,
) -> serde_json::Value {
    let deadline = Instant::now() + test_timeout(Duration::from_secs(10));
    loop {
        let status = program_status(harness);
        if status.as_array().is_some_and(|list| list.len() == records) {
            return status;
        }
        assert!(Instant::now() < deadline, "never {records} program status records: {status}");
        std::thread::sleep(Duration::from_millis(50));
    }
}

#[test]
fn program_status_records_survive_a_daemon_restart() {
    let _exclusive = exclusive_process_test();
    let mut harness = RecoveryHarness::start("program-status-restart");
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
            "name": "program-status-survivor",
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
    wait_for_host_records(&harness.host_root(), 1);

    harness.sigkill();
    harness.restart();
    let deadline = Instant::now() + test_timeout(Duration::from_secs(15));
    loop {
        let resolved = request(
            &harness.socket,
            serde_json::json!({"id": 2, "cmd": "resolve-terminal", "terminal_id": &terminal_id}),
        );
        if resolved["lifecycle"] == "running"
            && resolved["terminal_incarnation"].as_str() == Some(incarnation.as_str())
            && resolved["surface"].as_u64().is_some()
        {
            break;
        }
        assert!(Instant::now() < deadline, "replacement daemon did not adopt the terminal");
        std::thread::sleep(Duration::from_millis(50));
    }

    // Every field comes back, `updated_seq` too: clients compare it with the
    // last one they saw, so a reset would show old alerts as new.
    let after = wait_for_program_status(&harness, 2);
    assert_eq!(
        without_since(after),
        without_since(before),
        "program status changed across the restart"
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
