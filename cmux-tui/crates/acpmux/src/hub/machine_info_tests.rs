use super::*;
use crate::store::{META_SCHEMA, SessionMeta};
use serde_json::json;
use std::sync::Arc;

fn hub() -> Arc<Hub> {
    let config: crate::config::Config =
        serde_json::from_value(json!({"store": {"mode": "memory"}})).unwrap();
    let store = crate::store::open(&config.store, std::path::Path::new("/nonexistent")).unwrap();
    Hub::new(config, store)
}

#[test]
fn reads_real_secret_events_without_projecting_secret_values() {
    let hub = hub();
    // No creation marker here: the machine is local whatever box runs the test.
    hub.set_vm_marker_root("/nonexistent".into());
    let meta: SessionMeta = serde_json::from_value(json!({
        "schema": META_SCHEMA,
        "id": "machine-info-secret-events",
        "name": "machine-info-secret-events",
        "harness": "claude",
        "cwd": "/tmp",
        "status": "idle",
        "createdAt": 1,
        "updatedAt": 1,
    }))
    .unwrap();
    hub.store.save(&meta).unwrap();
    let session = hub.make_session(meta);

    hub.append(
        &session,
        "mux",
        "secret_request",
        json!({
            "secretId": "secret-1",
            "name": "API_TOKEN",
            "reason": "test machine_info projection",
        }),
    );
    hub.append(
        &session,
        "mux",
        "secret_decision",
        json!({
            "secretId": "secret-1",
            "name": "API_TOKEN",
            "outcome": "provided",
            // A defensive sentinel: even an unexpected value field in an old log must not
            // cross the machine_info projection boundary.
            "value": "machine-info-secret-sentinel",
        }),
    );

    let result = hub.machine_info(&session);
    assert_eq!(result["machine"]["kind"], "local");
    assert_eq!(result["secrets"], json!([{"name": "API_TOKEN", "status": "provided"}]));
    assert!(!result.to_string().contains("machine-info-secret-sentinel"));
}

fn row(id: &str, enabled: bool, status: Option<&str>) -> crate::store::ToolRow {
    crate::store::ToolRow {
        id: id.into(),
        name: id.into(),
        kind: "mcp".into(),
        source: "claude".into(),
        enabled,
        can_toggle: true,
        status: status.map(str::to_owned),
    }
}

#[test]
fn an_mcp_server_counts_only_when_its_harness_reports_it_connected() {
    let id = "mcp:cmux";
    assert_eq!(mcp_available(&[row(id, true, Some("connected"))], id), Some(true));
    for status in ["failed", "pending", "needs-auth", "disabled"] {
        assert_eq!(mcp_available(&[row(id, true, Some(status))], id), Some(false), "{status}");
    }
    assert_eq!(mcp_available(&[row(id, false, Some("connected"))], id), Some(false));
    assert_eq!(mcp_available(&[row(id, true, None)], id), None);
    assert_eq!(mcp_available(&[], id), Some(false));
}
