//! Integration tests for the one-shot subcommands: `cmx ping`,
//! `cmx version`, `cmx list-workspaces`, `cmx list-spaces`,
//! `cmx list-tabs`, `cmx new-space`, `cmx new-tab`, etc. These
//! commands connect to the server, issue a single protocol `Command`,
//! print the reply, and exit.

use std::process::Stdio;
use std::time::Duration;

use tempfile::tempdir;
use tokio::process::Command as AsyncCmd;
use tokio::time::timeout;

fn cmx_bin() -> std::path::PathBuf {
    // CARGO_BIN_EXE_cmx is set by Cargo for integration tests that want
    // to exec a workspace binary.
    std::path::PathBuf::from(env!("CARGO_BIN_EXE_cmx"))
}

async fn start_server(socket: &std::path::Path) -> tokio::process::Child {
    AsyncCmd::new(cmx_bin())
        .arg("--socket")
        .arg(socket)
        .arg("server")
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .kill_on_drop(true)
        .spawn()
        .expect("spawn server")
}

async fn wait_for_socket(socket: &std::path::Path) {
    let end = tokio::time::Instant::now() + Duration::from_secs(10);
    while !socket.exists() {
        if tokio::time::Instant::now() > end {
            panic!("socket never appeared");
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
}

async fn run_cmx(socket: &std::path::Path, args: &[&str]) -> (i32, String, String) {
    let out = timeout(
        Duration::from_secs(10),
        AsyncCmd::new(cmx_bin())
            .arg("--socket")
            .arg(socket)
            .args(args)
            .output(),
    )
    .await
    .expect("cmx timeout")
    .expect("cmx spawn");
    let code = out.status.code().unwrap_or(-1);
    let stdout = String::from_utf8_lossy(&out.stdout).to_string();
    let stderr = String::from_utf8_lossy(&out.stderr).to_string();
    (code, stdout, stderr)
}

async fn current_tab_title(socket: &std::path::Path) -> String {
    let (_, stdout, _) = run_cmx(socket, &["list-tabs", "--json"]).await;
    let v: serde_json::Value = serde_json::from_str(&stdout).unwrap();
    v["tabs"][0]["title"].as_str().unwrap().to_string()
}

async fn current_workspace_title(socket: &std::path::Path) -> String {
    let (_, stdout, _) = run_cmx(socket, &["list-workspaces", "--json"]).await;
    let v: serde_json::Value = serde_json::from_str(&stdout).unwrap();
    v["workspaces"][0]["title"].as_str().unwrap().to_string()
}

async fn current_space_title(socket: &std::path::Path) -> String {
    let (_, stdout, _) = run_cmx(socket, &["list-spaces", "--json"]).await;
    let v: serde_json::Value = serde_json::from_str(&stdout).unwrap();
    v["spaces"][0]["title"].as_str().unwrap().to_string()
}

async fn wait_for_screen_marker(socket: &std::path::Path, marker: &str) {
    for _ in 0..30 {
        let (_, stdout, _) = run_cmx(socket, &["read-screen", "--json"]).await;
        if let Ok(v) = serde_json::from_str::<serde_json::Value>(&stdout)
            && let Some(text) = v.get("text").and_then(|x| x.as_str())
            && text.contains(marker)
        {
            return;
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    panic!("marker never appeared in read-screen output: {marker}");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn version_subcommand_prints_protocol_version() {
    let dir = tempdir().unwrap();
    let socket = dir.path().join("srv.sock");
    // `version` doesn't need a running server — it's pure client-side.
    let (code, stdout, _) = run_cmx(&socket, &["version"]).await;
    assert_eq!(code, 0);
    assert!(stdout.contains("cmx "), "got: {stdout}");
    assert!(stdout.contains("protocol v"), "got: {stdout}");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn attach_rejects_removed_grid_flag() {
    let dir = tempdir().unwrap();
    let socket = dir.path().join("srv.sock");

    let (code, _, stderr) = run_cmx(&socket, &["attach", "--grid"]).await;
    assert_ne!(code, 0);
    assert!(stderr.contains("--grid"), "got: {stderr}");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn ping_succeeds_when_server_is_up() {
    let dir = tempdir().unwrap();
    let socket = dir.path().join("srv.sock");
    let mut server = start_server(&socket).await;
    wait_for_socket(&socket).await;

    let (code, stdout, _) = run_cmx(&socket, &["ping"]).await;
    assert_eq!(code, 0, "ping exit code");
    assert!(stdout.trim() == "ok", "got: {stdout:?}");

    server.kill().await.ok();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn list_workspaces_emits_one_row_per_workspace_and_json_is_parseable() {
    let dir = tempdir().unwrap();
    let socket = dir.path().join("srv.sock");
    let mut server = start_server(&socket).await;
    wait_for_socket(&socket).await;

    // Pretty form.
    let (code, stdout, _) = run_cmx(&socket, &["list-workspaces"]).await;
    assert_eq!(code, 0);
    // One active workspace by default, marked with an asterisk.
    assert!(
        stdout.lines().any(|l| l.trim_start().starts_with('*')),
        "no active workspace marker in: {stdout}"
    );

    // JSON form must be valid JSON with a workspaces array.
    let (code, stdout, _) = run_cmx(&socket, &["list-workspaces", "--json"]).await;
    assert_eq!(code, 0);
    let v: serde_json::Value = serde_json::from_str(&stdout).expect("json parse");
    let workspaces = v.get("workspaces").and_then(|x| x.as_array()).unwrap();
    assert!(!workspaces.is_empty(), "no workspaces in json: {stdout}");

    server.kill().await.ok();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn new_tab_subcommand_adds_a_tab() {
    let dir = tempdir().unwrap();
    let socket = dir.path().join("srv.sock");
    let mut server = start_server(&socket).await;
    wait_for_socket(&socket).await;

    // Baseline: one tab.
    let (_, stdout, _) = run_cmx(&socket, &["list-tabs", "--json"]).await;
    let v: serde_json::Value = serde_json::from_str(&stdout).unwrap();
    let before = v["tabs"].as_array().unwrap().len();

    let (code, _, stderr) = run_cmx(&socket, &["new-tab"]).await;
    assert_eq!(code, 0, "new-tab failed: {stderr}");

    // Should now have N+1 tabs.
    let (_, stdout, _) = run_cmx(&socket, &["list-tabs", "--json"]).await;
    let v: serde_json::Value = serde_json::from_str(&stdout).unwrap();
    let after = v["tabs"].as_array().unwrap().len();
    assert_eq!(after, before + 1, "tab count should grow by 1");

    server.kill().await.ok();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn list_spaces_new_space_and_rename_space_work() {
    let dir = tempdir().unwrap();
    let socket = dir.path().join("srv.sock");
    let mut server = start_server(&socket).await;
    wait_for_socket(&socket).await;

    let (code, stdout, _) = run_cmx(&socket, &["list-spaces", "--json"]).await;
    assert_eq!(code, 0);
    let v: serde_json::Value = serde_json::from_str(&stdout).unwrap();
    let before = v["spaces"].as_array().unwrap().len();

    let (code, _, stderr) = run_cmx(&socket, &["new-space", "--title", "scratch"]).await;
    assert_eq!(code, 0, "new-space failed: {stderr}");

    let (code, stdout, _) = run_cmx(&socket, &["list-spaces", "--json"]).await;
    assert_eq!(code, 0);
    let v: serde_json::Value = serde_json::from_str(&stdout).unwrap();
    let after = v["spaces"].as_array().unwrap().len();
    assert_eq!(after, before + 1, "space count should grow by 1");

    let (code, _, stderr) = run_cmx(&socket, &["rename-space", "named-space"]).await;
    assert_eq!(code, 0, "{stderr}");
    assert_eq!(current_space_title(&socket).await, "named-space");

    let (code, _, stderr) = run_cmx(&socket, &["rename", "space", "renamed-space"]).await;
    assert_eq!(code, 0, "{stderr}");
    assert_eq!(current_space_title(&socket).await, "renamed-space");

    let unicode_dash_rename_space = "rename\u{2013}space";
    let (code, _, stderr) = run_cmx(&socket, &[unicode_dash_rename_space, "unicode-space"]).await;
    assert_eq!(code, 0, "{stderr}");
    assert_eq!(current_space_title(&socket).await, "unicode-space");

    server.kill().await.ok();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn send_and_read_screen_round_trip() {
    let dir = tempdir().unwrap();
    let socket = dir.path().join("srv.sock");
    let mut server = start_server(&socket).await;
    wait_for_socket(&socket).await;

    // Send a sentinel echo into the active tab. `send` adds a trailing
    // newline so the shell executes the command.
    let marker = "CMX_SEND_TEST_77B1";
    let (code, _, _) = run_cmx(&socket, &["send", &format!("echo {marker}")]).await;
    assert_eq!(code, 0);

    // read-screen should see the marker in the rendered text. Poll a
    // few times because PTY output is async.
    let mut saw = false;
    for _ in 0..20 {
        let (_, stdout, _) = run_cmx(&socket, &["read-screen", "--json"]).await;
        if let Ok(v) = serde_json::from_str::<serde_json::Value>(&stdout)
            && let Some(t) = v.get("text").and_then(|x| x.as_str())
            && t.contains(marker)
        {
            saw = true;
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(100)).await;
    }
    assert!(saw, "marker never appeared in read-screen output");

    server.kill().await.ok();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn select_tab_changes_active_index() {
    let dir = tempdir().unwrap();
    let socket = dir.path().join("srv.sock");
    let mut server = start_server(&socket).await;
    wait_for_socket(&socket).await;

    // Spin up two extra tabs so we have three to cycle through.
    let _ = run_cmx(&socket, &["new-tab"]).await;
    let _ = run_cmx(&socket, &["new-tab"]).await;

    // After two new-tabs the active index should be the last one.
    let (_, stdout, _) = run_cmx(&socket, &["list-tabs", "--json"]).await;
    let v: serde_json::Value = serde_json::from_str(&stdout).unwrap();
    assert_eq!(v["active"], serde_json::json!(2));

    // Jump back to tab 0.
    let (code, _, _) = run_cmx(&socket, &["select-tab", "0"]).await;
    assert_eq!(code, 0);
    let (_, stdout, _) = run_cmx(&socket, &["list-tabs", "--json"]).await;
    let v: serde_json::Value = serde_json::from_str(&stdout).unwrap();
    assert_eq!(v["active"], serde_json::json!(0));

    server.kill().await.ok();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn rename_tab_and_workspace_persist_across_list_queries() {
    let dir = tempdir().unwrap();
    let socket = dir.path().join("srv.sock");
    let mut server = start_server(&socket).await;
    wait_for_socket(&socket).await;

    let (code, _, stderr) = run_cmx(&socket, &["rename-tab", "kebab-shell"]).await;
    assert_eq!(code, 0, "{stderr}");
    assert_eq!(current_tab_title(&socket).await, "kebab-shell");

    let (code, _, stderr) = run_cmx(&socket, &["rename", "tab", "spaced-shell"]).await;
    assert_eq!(code, 0, "{stderr}");
    assert_eq!(current_tab_title(&socket).await, "spaced-shell");

    let unicode_dash_rename_tab = "rename\u{2013}tab";
    let (code, _, stderr) = run_cmx(&socket, &[unicode_dash_rename_tab, "named-shell"]).await;
    assert_eq!(code, 0, "{stderr}");
    assert_eq!(current_tab_title(&socket).await, "named-shell");

    let marker = "OSC_TITLE_DONE_49C";
    let (code, _, stderr) = run_cmx(
        &socket,
        &[
            "send",
            &format!("printf '\\033]0;osc-title\\007'; echo {marker}"),
        ],
    )
    .await;
    assert_eq!(code, 0, "{stderr}");
    wait_for_screen_marker(&socket, marker).await;
    assert_eq!(current_tab_title(&socket).await, "named-shell");

    let (code, _, stderr) = run_cmx(&socket, &["rename", "workspace", "named-ws"]).await;
    assert_eq!(code, 0, "{stderr}");
    assert_eq!(current_workspace_title(&socket).await, "named-ws");

    let unicode_dash_rename_workspace = "rename\u{2013}workspace";
    let (code, _, stderr) = run_cmx(&socket, &[unicode_dash_rename_workspace, "unicode-ws"]).await;
    assert_eq!(code, 0, "{stderr}");
    assert_eq!(current_workspace_title(&socket).await, "unicode-ws");

    server.kill().await.ok();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn send_key_interrupts_sleep_with_ctrl_c() {
    let dir = tempdir().unwrap();
    let socket = dir.path().join("srv.sock");
    let mut server = start_server(&socket).await;
    wait_for_socket(&socket).await;

    // Kick off a long sleep (doesn't have a newline so it wouldn't
    // execute — send the command separately and let the shell run it).
    let (code, _, _) = run_cmx(&socket, &["send", "sleep 30"]).await;
    assert_eq!(code, 0);
    tokio::time::sleep(std::time::Duration::from_millis(300)).await;

    // Ctrl-C kills the sleep; a sentinel echo should reach the screen
    // quickly rather than waiting 30 seconds.
    let (code, _, stderr) = run_cmx(&socket, &["send-key", "C-c"]).await;
    assert_eq!(code, 0, "{stderr}");
    let marker = "SENDKEY_INTERRUPT_OK_E3";
    let (_, _, _) = run_cmx(&socket, &["send", &format!("echo {marker}")]).await;

    let mut saw = false;
    for _ in 0..20 {
        let (_, stdout, _) = run_cmx(&socket, &["read-screen", "--json"]).await;
        if let Ok(v) = serde_json::from_str::<serde_json::Value>(&stdout)
            && let Some(t) = v.get("text").and_then(|x| x.as_str())
            && t.contains(marker)
        {
            saw = true;
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(100)).await;
    }
    assert!(saw, "marker never appeared after Ctrl-C + echo");

    server.kill().await.ok();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn capabilities_lists_every_subcommand_and_is_json_parseable() {
    let dir = tempdir().unwrap();
    let socket = dir.path().join("srv.sock");
    // capabilities doesn't touch the server — it's a pure client lookup.
    let (code, stdout, _) = run_cmx(&socket, &["capabilities", "--json"]).await;
    assert_eq!(code, 0);
    let v: serde_json::Value = serde_json::from_str(&stdout).expect("valid json");
    let arr = v.as_array().expect("array");
    // Sanity: every key subcommand we advertise must appear.
    for expected in [
        "attach",
        "server",
        "ping",
        "send",
        "send-key",
        "read-screen",
        "list-workspaces",
        "list-spaces",
        "list-tabs",
        "list-terminals",
        "close-tab",
        "close-terminal",
        "close-space",
        "identify",
        "rename",
        "rename-tab",
        "rename-terminal",
        "rename-space",
        "rename-workspace",
        "rename tab",
        "rename terminal",
        "rename space",
        "rename workspace",
    ] {
        assert!(
            arr.iter().any(|v| v.as_str() == Some(expected)),
            "capabilities missing: {expected}",
        );
    }
}
