use super::*;

#[test]
fn pause_all_reports_partial_failure_without_losing_successes() {
    assert!(partial_failure(&json!({"ok":true,"data":{}})));
    assert!(partial_failure(&json!({"ok":true,"data":{"machines":[{"status":"running"}]}})));
    assert!(partial_failure(&json!({"ok": true, "data": {"machines": [
        {"machine": "vm-a", "status": "paused"},
        {"machine": "vm-b", "status": "failed", "error": {"code": "cloud.machine.busy"}}
    ]}})));
    assert!(!partial_failure(&json!({"ok": true, "data": {"machines": [
        {"machine": "vm-a", "status": "pausing"},
        {"machine": "vm-b", "status": "paused"}
    ]}})));
}
