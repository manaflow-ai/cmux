use super::*;
use serde_json::json;

/// The detector for this class: every daemon method that executes, restarts or respawns on a
/// caller's behalf (the cmuxterm-hq#32166 audit) is refused to a sandboxed agent. A new such
/// method lands here or in `contain_start`.
#[test]
fn every_audited_execution_method_is_refused() {
    for m in [
        method::SESSION_FORK,
        method::SESSION_LOAD,
        method::SESSION_RESUME,
        method::MUX_DISPATCH,
        method::MUX_RACE_START,
        method::MUX_HARNESS_ADD,
        method::MUX_HARNESS_DOCTOR,
        method::MUX_HARNESS_UPDATE,
        method::MUX_SESSIONS_RESTART_HARNESS,
        method::MUX_SET_DIRECTORIES,
        method::MUX_MCP_RECONNECT,
        method::MUX_WORKTREE_CLEAN,
        method::MUX_PROCESS_KILL,
        method::MUX_MACHINE_FILES_CALL,
        method::MUX_COMPUTER_USE_CALL,
        method::MUX_MESH_CONTROL,
        method::MUX_KEYS_MINT,
        method::MUX_COMPLETE,
        method::MUX_HUNK_SUMMARY,
        method::CHAT_FIX_FROM_LINK,
        method::MUX_PROJECT_NEW,
        method::MUX_HANDOFF_START,
        method::MUX_PREWARM,
        method::MUX_SECRET_RUN,
        method::MUX_FILE_PUT_BEGIN,
        "_acpmux/transfer_begin",
    ] {
        assert!(denied(m), "{m} must be refused to a sandboxed agent");
    }
    // What the agent's own MCP server needs stays: its tasks run in its boundary.
    for m in [method::MUX_BG_START, method::MUX_BG_LIST, method::SESSION_PROMPT, method::MUX_ATTACH]
    {
        assert!(!denied(m), "{m}");
    }
}

#[test]
fn boundary_folders_are_cwd_and_dirs_only() {
    let prefix: Vec<String> =
        ["-p", "P", "-D", "CWD=/w", "-D", "HOME=/h", "-D", "DIR0=/x", "-D", "DIRX=/no"]
            .iter()
            .map(|s| (*s).to_owned())
            .collect();
    assert_eq!(prefix_folders(&prefix), vec![PathBuf::from("/w"), PathBuf::from("/x")]);
    assert!(inside(Path::new("/w/sub"), &[PathBuf::from("/w")]));
    assert!(!inside(Path::new("/wx"), &[PathBuf::from("/w")]));
}

fn dir() -> (tempfile::TempDir, PathBuf) {
    let d = tempfile::tempdir().unwrap();
    let c = std::fs::canonicalize(d.path()).unwrap();
    std::fs::create_dir(c.join("sub")).unwrap();
    (d, c)
}

#[tokio::test]
async fn a_contained_start_keeps_the_callers_folders_and_harness() {
    let (_d, root) = dir();
    let folders = vec![root.clone()];
    let sub = root.join("sub").to_string_lossy().into_owned();
    let got =
        contain_start(method::SESSION_NEW, json!({"cwd": sub}), "claude", &folders).await.unwrap();
    assert_eq!(got["_meta"]["acpmux"]["harness"], "claude");
    assert_eq!(got["cwd"], sub);
    let got =
        contain_start(method::MUX_SUBSESSION_START, json!({"prompt": "x"}), "claude", &folders)
            .await
            .unwrap();
    assert_eq!(got["harness"], "claude");
}

#[tokio::test]
async fn a_start_that_would_leave_the_boundary_is_refused() {
    let (_d, root) = dir();
    let (_o, other) = dir();
    let folders = vec![root.join("sub")];
    let code = |r: Result<Value, RpcError>| r.unwrap_err().code;
    let new = |p: Value| contain_start(method::SESSION_NEW, p, "claude", &folders);
    let sub = |p: Value| contain_start(method::MUX_SUBSESSION_START, p, "claude", &folders);
    let out = other.to_string_lossy().into_owned();
    let inn = root.join("sub").to_string_lossy().into_owned();
    assert_eq!(code(new(json!({"cwd": out})).await), SANDBOXED);
    assert_eq!(code(new(json!({})).await), SANDBOXED);
    assert_eq!(code(new(json!({"cwd": inn, "additionalDirectories": [out]})).await), SANDBOXED);
    assert_eq!(code(new(json!({"cwd": inn, "_meta": {"acpmux": {"peer": "m"}}})).await), SANDBOXED);
    assert_eq!(
        code(new(json!({"cwd": inn, "_meta": {"acpmux": {"preset": "p"}}})).await),
        SANDBOXED
    );
    assert_eq!(
        code(new(json!({"cwd": inn, "_meta": {"acpmux": {"harness": "codex"}}})).await),
        SANDBOXED
    );
    assert_eq!(code(new(json!({"cwd": inn, "mcpServers": [{"command": "x"}]})).await), SANDBOXED);
    assert_eq!(code(sub(json!({"worktree": true})).await), SANDBOXED);
    assert_eq!(code(sub(json!({"host": "big"})).await), SANDBOXED);
    assert_eq!(code(sub(json!({"harness": "codex"})).await), SANDBOXED);
    assert_eq!(code(sub(json!({"cwd": root.to_string_lossy()})).await), SANDBOXED);
    // A symlink out of the boundary resolves to where it points.
    let link = root.join("sub").join("out");
    std::os::unix::fs::symlink(&other, &link).unwrap();
    assert_eq!(code(sub(json!({"cwd": link.to_string_lossy()})).await), SANDBOXED);
}
