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

#[test]
fn a_glob_waits_only_for_its_patterns_literal_folders_while_the_checkout_fills() {
    let root = tempfile::tempdir().unwrap();
    let repo = root.path().canonicalize().unwrap().join("repo");
    std::fs::create_dir_all(repo.join("docs/cloud")).unwrap();
    let mut sync = Sync::begin(&repo).unwrap();
    sync.head_ready();
    sync.filled(&["docs/cloud/**"]).unwrap();
    let glob =
        |input: serde_json::Value| json!({"cwd": repo, "tool_name": "Glob", "tool_input": input});
    let quick = Duration::from_millis(100);
    for held in [
        json!({"pattern": "docs/cloud/**/*.md"}),
        json!({"pattern": "./docs/cloud/*"}),
        json!({"pattern": "cloud/*.md", "path": "docs"}),
        json!({"pattern": format!("{}/docs/cloud/*", repo.display())}),
    ] {
        native_hook::wait("claude", "PreToolUse", &glob(held.clone()), quick)
            .unwrap_or_else(|error| panic!("{held}: {error}"));
    }
    // A pattern with no literal folder reads the whole checkout, as a folder not held yet
    // waits for its line (and is asked for).
    for waits in [json!({"pattern": "**/*.rs"}), json!({"pattern": "src/*.rs"})] {
        assert!(native_hook::wait("claude", "PreToolUse", &glob(waits.clone()), quick).is_err());
    }
    assert!(sync.wants().contains(&"src".to_owned()));
    sync.complete().unwrap();
}
