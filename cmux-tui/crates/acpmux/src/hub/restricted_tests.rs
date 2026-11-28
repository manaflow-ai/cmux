use super::*;

#[test]
fn requested_reads_a_boolean_only() {
    assert!(!requested(None).unwrap());
    assert!(!requested(Some(&json!({}))).unwrap());
    assert!(!requested(Some(&json!({"restricted": null}))).unwrap());
    assert!(!requested(Some(&json!({"restricted": false}))).unwrap());
    assert!(requested(Some(&json!({"restricted": true}))).unwrap());
    let e = requested(Some(&json!({"restricted": "yes"}))).unwrap_err();
    assert_eq!(e.data.unwrap()["reason"], "restricted.invalid");
}

#[test]
fn a_restricted_start_holds_review_or_narrower() {
    assert_eq!(start_policy(None).unwrap(), Some(PermissionPolicy::Review));
    assert_eq!(
        start_policy(Some(PermissionPolicy::DenyAll)).unwrap(),
        Some(PermissionPolicy::DenyAll)
    );
    for wide in [
        PermissionPolicy::Ask,
        PermissionPolicy::ApproveReads,
        PermissionPolicy::ApproveEdits,
        PermissionPolicy::ApproveAll,
    ] {
        let e = start_policy(Some(wide)).unwrap_err();
        assert_eq!(e.data.unwrap()["reason"], "restricted.policy", "{wide}");
    }
}

fn meta() -> crate::store::SessionMeta {
    serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": "r", "name": "r", "harness": "claude",
        "cwd": "/tmp", "status": "idle", "createdAt": 1, "updatedAt": 2
    }))
    .unwrap()
}

#[test]
fn a_restricted_chat_refuses_a_wider_policy() {
    let mut meta = meta();
    assert!(refuse_widening(&meta, PermissionPolicy::ApproveAll).is_ok());
    meta.restricted = true;
    assert!(refuse_widening(&meta, PermissionPolicy::ApproveAll).is_err());
    assert!(refuse_widening(&meta, PermissionPolicy::Ask).is_err());
    assert!(refuse_widening(&meta, PermissionPolicy::Review).is_ok());
    assert!(refuse_widening(&meta, PermissionPolicy::DenyAll).is_ok());
}

#[test]
fn only_a_restricted_chat_gets_the_args() {
    let mut meta = meta();
    assert!(claude_args(&meta).is_empty());
    meta.restricted = true;
    assert_eq!(claude_args(&meta), ["--setting-sources", "user", "--strict-mcp-config"]);
}
