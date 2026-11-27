//! The `review` policy (`config.rs` `PermissionPolicy::Review`): a reviewer's read-only shell.
//! Two review sessions in a row could not grep or compile, because every shell call waited for a
//! person who was not there (GAPS.md, "acpmux bugs seen live"). Under review a read, a search and
//! a read-only shell command are allowed at once, and anything else is denied at once: nothing
//! waits on a prompt. The read-only shell commands are judged in the agent's whole environment,
//! so they are tested with a stand-in agent in a hermetic process
//! (`tests/hub_integration/permission_groups.rs`, `review_policy_*`).
#![cfg(unix)]
use super::*;

fn fixture() -> (tempfile::TempDir, Arc<Hub>, Arc<Session>) {
    let dir = tempfile::tempdir().unwrap();
    let cwd = dir.path().canonicalize().unwrap().join("repo");
    std::fs::create_dir(&cwd).unwrap();
    std::fs::write(cwd.join("notes.txt"), "one\ntwo\n").unwrap();
    let mut config = Config { permission_policy: PermissionPolicy::Review, ..Default::default() };
    config.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&config.store, dir.path()).unwrap();
    let hub = Hub::new(config, store);
    let meta: SessionMeta = serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": "review-session", "name": "Review",
        "harness": "claude", "cwd": cwd, "status": "ready", "createdAt": 1, "updatedAt": 1
    }))
    .unwrap();
    hub.store.save(&meta).unwrap();
    let session = hub.make_session(meta);
    // The env this daemon started its agent with: the system's tools only.
    let env = [("PATH".to_owned(), "/usr/bin:/bin".to_owned())].into_iter().collect();
    *session.launch_env.lock().unwrap() = Some(env);
    (dir, hub, session)
}

fn request(kind: &str, title: &str, command: Option<&str>) -> Value {
    let mut call = json!({"toolCallId": format!("t-{title}"), "title": title, "kind": kind});
    if let Some(command) = command {
        call.set("rawInput", json!({"command": command}));
    }
    json!({"sessionId": "review-session", "toolCall": call, "options": [
        {"optionId": "allow_once", "name": "Allow", "kind": "allow_once"},
        {"optionId": "allow_always", "name": "Always", "kind": "allow_always"},
        {"optionId": "reject_once", "name": "Reject", "kind": "reject_once"}
    ]})
}

async fn answer(hub: &Arc<Hub>, session: &Arc<Session>, request: Value) -> Option<String> {
    let epoch = session.permission_epoch.load(Ordering::SeqCst);
    let ask = hub.handle_permission(session, request, epoch, None);
    let out = tokio::time::timeout(std::time::Duration::from_secs(10), ask)
        .await
        .expect("a review session answered at once, with no person to ask");
    out.pointer("/outcome/optionId").and_then(Value::as_str).map(str::to_owned)
}

#[test]
fn review_policy_parses_and_prints_as_review() {
    let parsed: PermissionPolicy = "review".parse().unwrap();
    assert_eq!(parsed, PermissionPolicy::Review);
    assert_eq!(parsed.to_string(), "review");
    assert_eq!(super::super::person::breadth(parsed), 2, "as wide as approve-reads");
    assert!(!super::super::person::asking_policy_value(Some(&json!("review"))));
}

#[tokio::test]
async fn review_policy_allows_reads_and_denies_the_rest_at_once() {
    let (_dir, hub, session) = fixture();
    let allowed = Some("allow_once".to_owned());
    for (kind, title, command) in [("read", "Read notes.txt", None), ("search", "Grep one", None)] {
        let got = answer(&hub, &session, request(kind, title, command)).await;
        assert_eq!(got, allowed, "{kind} {title}: never allow_always, never a prompt");
    }
    let rejected = Some("reject_once".to_owned());
    for (kind, title, command) in [
        ("execute", "rm", Some("rm notes.txt")),
        ("execute", "cargo", Some("cargo build")),
        ("execute", "redirect", Some("cat notes.txt > copy.txt")),
        ("edit", "Edit notes.txt", None),
        ("delete", "Delete notes.txt", None),
        ("other", "some_mcp_tool", None),
    ] {
        let got = answer(&hub, &session, request(kind, title, command)).await;
        assert_eq!(got, rejected, "{kind} {title}");
    }
    assert!(session.pending_permissions().is_empty(), "a review session waited for a person");
    assert!(session.meta().cwd.join("notes.txt").exists());
}
