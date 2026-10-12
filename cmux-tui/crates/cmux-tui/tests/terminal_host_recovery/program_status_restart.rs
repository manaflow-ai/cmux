//! cx-6so.36.6: OSC 7501 program status records survive a daemon restart.
//! The terminal host keeps them and hands them to the adopting daemon, so a
//! tab that showed "blocked" before the restart still shows it after.

use super::*;

fn program_status(harness: &RecoveryHarness, terminal_id: &str, id: &str) -> serde_json::Value {
    let terminals = resource_request(
        &harness.socket,
        id,
        "terminal.list",
        serde_json::json!({"machine":"current","session":"current"}),
        None,
    );
    terminals
        .as_array()
        .unwrap()
        .iter()
        .find(|terminal| terminal["id"] == terminal_id)
        .unwrap_or_else(|| panic!("terminal {terminal_id} is not listed: {terminals}"))["extra"]
        ["program_status"]
        .clone()
}

fn wait_for_program_status(
    harness: &RecoveryHarness,
    terminal_id: &str,
    records: usize,
) -> serde_json::Value {
    let deadline = Instant::now() + test_timeout(Duration::from_secs(10));
    loop {
        let status = program_status(harness, terminal_id, "program-status-list");
        if status.as_array().is_some_and(|list| list.len() == records) {
            return status;
        }
        assert!(Instant::now() < deadline, "program status never showed {records} records: {status}");
        std::thread::sleep(Duration::from_millis(50));
    }
}

#[test]
fn program_status_records_survive_a_daemon_restart() {
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
                    "printf 'reported\\r\\n'; sleep 30",
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
    let before = wait_for_program_status(&harness, &terminal_id, 2);
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
    let after = wait_for_program_status(&harness, &terminal_id, 2);
    assert_eq!(after, before, "program status changed across the restart");

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
