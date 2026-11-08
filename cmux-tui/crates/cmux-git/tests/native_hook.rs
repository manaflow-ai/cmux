#![cfg(unix)]
use cmux_git::{native_hook, sync_barrier::Sync};
use serde_json::json;
use std::{sync::mpsc, time::Duration};

#[test]
fn native_tools_wait_for_active_sync_at_cwd_or_explicit_file_target() {
    for source in ["claude", "codex"] {
        for target in [false, true] {
            let root = tempfile::tempdir().unwrap();
            let parent = root.path().canonicalize().unwrap();
            let repo = parent.join("repo");
            let sync = Sync::begin(&repo).unwrap();
            let native = if target {
                json!({"cwd": parent, "tool_input": {"file_path": "repo/file"}})
            } else {
                json!({"cwd": repo, "tool_input": {"command": "write files"}})
            };
            let (send, receive) = mpsc::channel();
            let waiter = std::thread::spawn(move || {
                send.send(native_hook::wait(source, "PreToolUse", &native, Duration::from_secs(2)))
                    .unwrap();
            });
            assert!(receive.recv_timeout(Duration::from_millis(50)).is_err());
            sync.complete().unwrap();
            receive.recv_timeout(Duration::from_secs(1)).unwrap().unwrap();
            waiter.join().unwrap();
        }
    }
}

#[test]
fn active_timeout_and_abandoned_sync_deny_instead_of_allowing_the_tool() {
    let root = tempfile::tempdir().unwrap();
    let repo = root.path().canonicalize().unwrap().join("repo");
    let sync = Sync::begin(&repo).unwrap();
    let native = json!({"cwd": repo});
    let error = native_hook::wait("codex", "PreToolUse", &native, Duration::ZERO).unwrap_err();
    assert_eq!(error.kind(), std::io::ErrorKind::TimedOut);
    assert_eq!(
        native_hook::denial(&error.to_string())["hookSpecificOutput"]["permissionDecision"],
        "deny"
    );
    drop(sync);
    assert!(native_hook::wait("claude", "PreToolUse", &native, Duration::ZERO).is_err());
    native_hook::wait("claude", "PostToolUse", &native, Duration::ZERO).unwrap();
}

#[test]
fn native_pre_tool_retention_measurement() {
    let root = tempfile::tempdir().unwrap();
    let repo = root.path().canonicalize().unwrap().join("repo");
    std::fs::create_dir(&repo).unwrap();
    let file = repo.join("file");
    let mut retained = [0, 0];
    for gated in [false, true] {
        for _ in 0..100 {
            let sync = Sync::begin(&repo).unwrap();
            if !gated {
                std::fs::write(&file, "agent edit").unwrap();
            }
            let ready = if gated {
                let native = json!({"cwd": repo});
                Some(std::thread::spawn(move || {
                    native_hook::wait("claude", "PreToolUse", &native, Duration::from_secs(2))
                }))
            } else {
                None
            };
            std::fs::write(&file, "repo sync").unwrap();
            sync.complete().unwrap();
            if let Some(ready) = ready {
                ready.join().unwrap().unwrap();
                std::fs::write(&file, "agent edit").unwrap();
            }
            retained[usize::from(gated)] +=
                usize::from(std::fs::read_to_string(&file).unwrap() == "agent edit");
        }
    }
    println!("native_pre_tool_retention: before={}/100 after={}/100", retained[0], retained[1]);
    assert_eq!(retained, [0, 100]);
}
