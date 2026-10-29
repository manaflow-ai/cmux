//! The `energy_status` tool: it reads the app's
//! `energy.status` (served in release builds too) and the session daemon's
//! `energy.status`, returns the report `cmux energy status --json` prints,
//! and changes nothing.

use super::*;

/// The fake daemon's answer to a field-less line: `energy.status` with its
/// own reading on and no override.
pub(super) fn daemon_line(fake: &Fake, cmd: &str) -> Result<Value, String> {
    fake.sent.borrow_mut().push(json!({"kind": "daemon_line", "cmd": cmd}));
    if fake.fail_resources || fake.live.borrow().daemon_down {
        return Err("connection refused".into());
    }
    Ok(
        json!({"saver": true, "source": "daemon", "reason": null, "override": null, "reading": true}),
    )
}

#[test]
fn energy_status_tool_reads_the_app_and_the_daemon_and_takes_no_arguments() {
    let mut server = Server::new(Fake::with_actions(), None);
    let tools = server.list();
    let tool = tools.iter().find(|tool| tool["name"] == "energy_status").expect("listed");
    assert_eq!(tool["annotations"]["readOnlyHint"], true);
    let result = call(&mut server, "energy_status", json!({}));
    assert_eq!(result["isError"], false, "{result}");
    let sent = server.backend.last("app");
    assert_eq!(
        (sent["method"].clone(), sent["mutation"].clone()),
        (json!("energy.status"), json!(false))
    );
    assert_eq!(server.backend.last("daemon_line")["cmd"], "energy.status");
    let report = &result["structuredContent"];
    assert_eq!(report["app"], json!({"policy": null, "inputs": null}), "{result}");
    assert_eq!(report["daemon"]["source"], "daemon", "{result}");
    assert_eq!(report["daemon"]["saver"], true, "{result}");
    assert_eq!(call(&mut server, "energy_status", json!({"saver": true}))["isError"], true);
}

#[test]
fn energy_status_tool_reports_each_side_that_does_not_answer() {
    let mut server = Server::new(Fake { fail_apps: true, ..Fake::with_actions() }, None);
    let result = call(&mut server, "energy_status", json!({}));
    assert_eq!(result["isError"], false, "{result}");
    let report = &result["structuredContent"];
    assert_eq!(report["app"], json!({"error": "app is down"}), "{result}");
    assert_eq!(report["daemon"]["source"], "daemon", "{result}");

    let mut server = Server::new(Fake { fail_resources: true, ..Fake::with_actions() }, None);
    let report = call(&mut server, "energy_status", json!({}))["structuredContent"].clone();
    assert_eq!(report["daemon"], json!({"error": "connection refused"}), "{report}");
    assert!(report["app"].get("policy").is_some(), "{report}");
}
