use std::cell::Cell;

use serde_json::{Value, json};

use super::*;

fn code(e: &RpcError) -> String {
    e.data.as_ref().and_then(|d| d["code"].as_str()).unwrap_or_default().to_owned()
}

fn cfg_for(root: &std::path::Path) -> HandConfig {
    HandConfig { roots: vec![root.to_path_buf()], ..config() }
}

#[test]
fn machine_files_parse_takes_listed_actions_and_no_policy_inputs() {
    let (action, params) =
        parse(&json!({"action": "fs.read", "params": {"path": "/tmp/a"}})).unwrap();
    assert_eq!(action, "fs.read");
    assert_eq!(params, json!({"path": "/tmp/a"}));
    assert_eq!(parse(&json!({"action": "exec"})).unwrap().1, json!({}));
    // Nothing but the listed actions: no agent sessions, no unknown names.
    for action in ["agent.start", "agent.send", "agent.events", "fs.delete", "", "EXEC"] {
        let e = parse(&json!({"action": action, "params": {}})).unwrap_err();
        assert_eq!(code(&e), "unknown_action", "{action}");
    }
    // The policy's own inputs are never the caller's.
    for key in ["_level", "_verdict", "_anything"] {
        let e = parse(&json!({"action": "exec", "params": {"argv": ["true"], key: "full"}}))
            .unwrap_err();
        assert_eq!(code(&e), "machine_call_denied", "{key}");
    }
    let e = parse(&json!({"action": "exec", "params": ["true"]})).unwrap_err();
    assert_eq!(code(&e), "invalid_arguments");
}

#[tokio::test]
async fn machine_files_write_read_edit_and_run_inside_the_roots() {
    let dir = tempfile::tempdir().unwrap();
    let root = std::fs::canonicalize(dir.path()).unwrap();
    let cfg = cfg_for(&root);
    let file = root.join("note.txt").to_string_lossy().into_owned();
    let ok = || Ok(());
    let wrote =
        run_with(&cfg, "fs.write", json!({"path": file, "text": "one\ntwo\n"}), ok).await.unwrap();
    let read = run_with(&cfg, "fs.read", json!({"path": file}), ok).await.unwrap();
    assert_eq!(read["text"], "one\ntwo\n");
    assert_eq!(read["sha256"], wrote["sha256"]);
    run_with(
        &cfg,
        "fs.edit",
        json!({"path": file, "edits": [{"old": "two", "new": "three"}], "expect_sha256": read["sha256"]}),
        ok,
    )
    .await
    .unwrap();
    let ran = run_with(
        &cfg,
        "exec",
        json!({"argv": ["cat", "note.txt"], "cwd": root.to_string_lossy()}),
        ok,
    )
    .await
    .unwrap();
    assert_eq!(ran["exit"], 0, "{ran}");
    assert_eq!(ran["stdout"], "one\nthree\n");
    let listed =
        run_with(&cfg, "fs.list", json!({"path": root.to_string_lossy()}), ok).await.unwrap();
    assert!(listed["entries"].to_string().contains("note.txt"), "{listed}");
}

#[tokio::test]
async fn machine_files_refuse_outside_the_roots_and_what_the_hand_never_does() {
    let dir = tempfile::tempdir().unwrap();
    let root = std::fs::canonicalize(dir.path()).unwrap();
    let other = tempfile::tempdir().unwrap();
    let outside = std::fs::canonicalize(other.path()).unwrap().join("x.txt");
    let cfg = cfg_for(&root);
    let ok = || Ok(());
    // A path outside every root, for a read and for a write; nothing is written.
    for (action, params) in [
        ("fs.read", json!({"path": outside.to_string_lossy()})),
        ("fs.write", json!({"path": outside.to_string_lossy(), "text": "x"})),
        ("exec", json!({"argv": ["true"], "cwd": other.path().to_string_lossy()})),
    ] {
        let e = run_with(&cfg, action, params, ok).await.unwrap_err();
        assert_eq!(code(&e), "policy.denied", "{action}: {e:?}");
    }
    assert!(!outside.exists());
    // A `..` out of the root is resolved before the policy sees it.
    let dotted = format!("{}/../{}", root.display(), "escape.txt");
    let e = run_with(&cfg, "fs.write", json!({"path": dotted, "text": "x"}), ok).await.unwrap_err();
    assert_eq!(code(&e), "policy.denied");
    // The hand's hard denies hold although the asking side allowed the call.
    let e = run_with(
        &cfg,
        "exec",
        json!({"argv": ["sh", "-c", "rm -rf /"], "cwd": root.to_string_lossy()}),
        ok,
    )
    .await
    .unwrap_err();
    assert_eq!(code(&e), "policy.denied", "{e:?}");
    // Run-time callers cannot name actions past the list either.
    let e = run_with(&cfg, "agent.start", json!({"harness": "claude", "prompt": "x"}), ok)
        .await
        .unwrap_err();
    assert_eq!(code(&e), "unknown_action");
}

#[tokio::test]
async fn machine_files_leave_credentials_to_the_owner() {
    let dir = tempfile::tempdir().unwrap();
    let root = std::fs::canonicalize(dir.path()).unwrap();
    let cfg = cfg_for(&root);
    // A command that names a credentials folder asks the owner; here that is a refusal, and
    // the command does not run.
    let marker = root.join("ran");
    let line = format!("touch {} && cat ~/.ssh/id_ed25519", marker.display());
    let e = run_with(
        &cfg,
        "exec",
        json!({"argv": ["sh", "-c", line], "cwd": root.to_string_lossy()}),
        || Ok(()),
    )
    .await
    .unwrap_err();
    assert_eq!(code(&e), NEEDS_OWNER, "{e:?}");
    assert!(!marker.exists());
}

#[tokio::test]
async fn machine_files_read_consent_for_every_call() {
    let dir = tempfile::tempdir().unwrap();
    let root = std::fs::canonicalize(dir.path()).unwrap();
    let cfg = cfg_for(&root);
    let file = root.join("a.txt").to_string_lossy().into_owned();
    // No consent: refused with its reason before the policy or the file system is touched.
    let e = run_with(&cfg, "fs.write", json!({"path": file, "text": "x"}), || {
        Err(HandError::new("consent_declined", "not allowed"))
    })
    .await
    .unwrap_err();
    assert_eq!(code(&e), "consent_declined");
    assert!(!root.join("a.txt").exists());
    // Consent is read before the decision and again after it.
    let reads = Cell::new(0);
    let counted = || {
        reads.set(reads.get() + 1);
        Ok(())
    };
    let done: Value =
        run_with(&cfg, "fs.write", json!({"path": file, "text": "x"}), counted).await.unwrap();
    assert!(done["sha256"].is_string());
    assert_eq!(reads.get(), 2);
}
