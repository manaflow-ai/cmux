//! Person-facing restore using the daemon's durable detector evidence.
use super::{Conn, Origin};
use crate::hub::{EventFilter, Hub};
use crate::rpc::RpcError;
use serde_json::Value;
use std::sync::Arc;

pub(super) const METHOD: &str = crate::rpc::method::MUX_TEST_TAMPERING_RESTORE;

fn authorized(person: bool, origin: Origin, authenticated: bool) -> bool {
    authenticated && (person || origin == Origin::LocalApp)
}

pub(super) async fn handle(hub: &Arc<Hub>, conn: &Conn, params: &Value) -> Result<Value, RpcError> {
    // A client-supplied `via: app` or personVerified is not proof. Remote connections need
    // a dedicated signed restore intent before this operation can be forwarded safely.
    if !authorized(conn.is_person(), conn.origin, conn.auth.authenticated()) {
        return Err(crate::hub::person::person_required("restoring test changes"));
    }
    let session = hub.resolve(super::session_key(params)?)?;
    let integer = |name| {
        params
            .get(name)
            .and_then(Value::as_u64)
            .ok_or_else(|| RpcError::invalid_params(format!("{name} is required")))
    };
    let seq = integer("eventSeq")?;
    let file = usize::try_from(integer("fileIndex")?)
        .map_err(|_| RpcError::invalid_params("fileIndex is too large"))?;
    let finding = usize::try_from(integer("findingIndex")?)
        .map_err(|_| RpcError::invalid_params("findingIndex is too large"))?;
    if seq == 0 {
        return Err(RpcError::invalid_params("eventSeq must be positive"));
    }
    let hub = Arc::clone(hub);
    tokio::task::spawn_blocking(move || {
        let page = hub
            .events_page(
                &session.id,
                seq - 1,
                seq.checked_add(1),
                1,
                Some(4 * 1024 * 1024),
                false,
                &EventFilter::all(),
            )
            .map_err(|e| RpcError::internal(e.to_string()))?;
        let record = page
            .events
            .first()
            .ok_or_else(|| RpcError::invalid_params("test_tampering.missing_event"))?;
        restore_record(&session.meta().cwd, record, seq, file, finding)
    })
    .await
    .map_err(|e| RpcError::internal(format!("test restore stopped: {e}")))?
}

/// Re-derive from the edit itself: a harness-supplied `tampering` member, an old detector
/// version, or a forged path/replacement is never authority for a filesystem write.
fn restore_record(
    root: &std::path::Path,
    record: &crate::store::EventRecord,
    seq: u64,
    file: usize,
    finding: usize,
) -> Result<Value, RpcError> {
    if record.seq != seq || record.dir != "in" {
        return Err(RpcError::invalid_params("test_tampering.missing_event"));
    }
    let update = record
        .msg
        .pointer("/params/update")
        .filter(|u| {
            matches!(
                u.get("sessionUpdate").and_then(Value::as_str),
                Some("tool_call" | "tool_call_update")
            )
        })
        .ok_or_else(|| RpcError::invalid_params("test_tampering.missing_tool"))?;
    if update.get("status").and_then(Value::as_str) != Some("completed") {
        return Err(RpcError::invalid_params("test_tampering.unsettled_tool"));
    }
    let detected = update
        .get("content")
        .and_then(crate::test_tampering::detect_diffs)
        .ok_or_else(|| RpcError::invalid_params("test_tampering.missing_evidence"))?;
    if update.get("tampering") != Some(&detected) {
        return Err(RpcError::invalid_params("test_tampering.evidence_changed"));
    }
    crate::test_tampering_restore::restore(root, &detected, file, finding)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn evidence() -> crate::store::EventRecord {
        let content = json!([{"type":"diff", "path":"a.test.ts", "oldText":"expect(n).toEqual(3);", "newText":"expect(n).toBeTruthy();"}]);
        let tampering = crate::test_tampering::detect_diffs(&content).unwrap();
        crate::store::EventRecord {
            seq: 7,
            at: 1,
            dir: "in".into(),
            kind: "tool_call".into(),
            host_seq: None,
            msg: json!({"params":{"update":{"sessionUpdate":"tool_call","status":"completed","content":content,"tampering":tampering}}}),
        }
    }

    #[cfg(unix)]
    #[test]
    fn durable_event_restores_and_forged_report_cannot_write() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("a.test.ts");
        std::fs::write(&path, "expect(n).toBeTruthy();\n").unwrap();
        let mut record = evidence();
        record.msg["params"]["update"]["tampering"]["files"][0]["findings"][0]["old"] =
            json!("arbitrary write");
        assert!(restore_record(dir.path(), &record, 7, 0, 0).is_err());
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "expect(n).toBeTruthy();\n");
        restore_record(dir.path(), &evidence(), 7, 0, 0).unwrap();
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "expect(n).toEqual(3);\n");
        assert_eq!(
            restore_record(dir.path(), &evidence(), 7, 0, 0).unwrap()["alreadyRestored"],
            true
        );
    }

    #[test]
    fn wrong_event_failed_call_and_forged_alarm_on_normal_edit_are_refused() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("a.test.ts");
        std::fs::write(&path, "expect(n).toBeTruthy();\n").unwrap();
        let mut record = evidence();
        assert!(restore_record(dir.path(), &record, 8, 0, 0).is_err());
        assert!(restore_record(dir.path(), &record, 7, 9, 0).is_err());
        record.msg["params"]["update"]["status"] = json!("failed");
        assert!(restore_record(dir.path(), &record, 7, 0, 0).is_err());
        record.msg["params"]["update"]["status"] = json!("completed");
        record.msg["params"]["update"]["content"] = json!([]);
        assert!(restore_record(dir.path(), &record, 7, 0, 0).is_err());
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "expect(n).toBeTruthy();\n");
    }

    #[test]
    fn pending_or_failed_durable_evidence_cannot_restore_even_if_file_matches() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("a.test.ts");
        std::fs::write(&path, "expect(n).toBeTruthy();\n").unwrap();
        for status in [
            json!("pending"),
            json!("in_progress"),
            json!("failed"),
            json!("cancelled"),
            Value::Null,
        ] {
            let mut record = evidence();
            record.msg["params"]["update"]["status"] = status;
            let error = restore_record(dir.path(), &record, 7, 0, 0).unwrap_err();
            assert_eq!(error.message, "test_tampering.unsettled_tool");
            assert_eq!(std::fs::read_to_string(&path).unwrap(), "expect(n).toBeTruthy();\n");
        }
    }

    #[test]
    fn only_proven_person_or_authenticated_local_app_can_restore() {
        for origin in [Origin::Local, Origin::Web, Origin::Peer] {
            assert!(!authorized(false, origin, true));
        }
        assert!(authorized(true, Origin::Local, true));
        assert!(authorized(false, Origin::LocalApp, true));
        assert!(!authorized(false, Origin::LocalApp, false));
        assert!(!authorized(true, Origin::Local, false));
    }
}
