//! An adopted harness with a child process: the idle pass keeps it up, and a stop still ends it
//! and its child as it always did (`hub/idle_census.rs`).

use super::*;

#[tokio::test]
async fn an_adopted_harness_with_a_child_stays_up_idle_and_a_stop_still_ends_both() {
    let helper_file = std::env::temp_dir().join(format!("amd-idlead-{}", std::process::id()));
    let mut daemon = Daemon::with_env(
        "idlead",
        "approve-all",
        &[("FAKE_SETSID_CHILD", helper_file.to_str().unwrap()), ("ACPMUX_IDLE_CHILD_SECS", "1")],
    );
    let session = new_session(&daemon).await;
    let harness = daemon.host_record(&session)["harness_pid"].as_i64().unwrap();
    let helper_path = format!("{}.{harness}", helper_file.display());
    let helper: i64 = std::fs::read_to_string(&helper_path).unwrap().trim().parse().unwrap();
    let _ = std::fs::remove_file(&helper_path);
    // A restart: the next daemon adopts the host and knows nothing of how it started.
    daemon.sigterm();
    daemon.start();
    daemon.wait_event(&session, "host_adopted", |e| e["kind"] == "host_adopted");
    // Several idle periods pass: its child runs under it, so the harness stays up.
    std::thread::sleep(Duration::from_secs(5));
    let kept = alive(harness) && alive(helper);
    // A stop ends the harness and its child as before.
    daemon.rpc().await.call("_acpmux/kill", json!({"sessionId": session})).await;
    let ended = gone_within(harness, Duration::from_secs(10));
    let child_ended = gone_within(helper, Duration::from_secs(10));
    if !child_ended {
        // SAFETY: this test's agent started the helper; end it before failing.
        unsafe { libc::kill(helper as i32, libc::SIGKILL) };
    }
    assert!(kept, "the idle pass ended an adopted harness with a child running under it");
    assert!(ended, "a stop left the adopted harness running");
    assert!(child_ended, "a stop left the adopted harness's child running");
}

/// An app update restarts acpmux, and the next daemon adopts every agent host. An adopted harness
/// that is idle but for its own MCP server ends at the idle pass, and the server with it. Before,
/// the adopting daemon knew none of its servers, so every agent of an earlier daemon stayed up for
/// good (163 Claude Code harnesses idle for days on one Mac, load 125, 2026-10-30).
#[tokio::test]
async fn an_adopted_harness_idle_but_for_its_mcp_server_ends() {
    adopted_mcp_server_case("idlemcp", Case::Hello).await;
}

/// The update also moved the bundle the server runs from aside and put a new one at its path, as
/// the app's updater does: the kernel then names the moved file, which is no longer the file at
/// the server's configured path. The server still is the harness's own. A same-named program
/// started from another path with the server's exact argv (`exec -a`) is not, and keeps the
/// harness up.
#[cfg(target_os = "macos")]
#[tokio::test]
async fn an_adopted_harness_ends_when_an_update_moved_its_mcp_server_aside() {
    adopted_mcp_server_case("idlemv", Case::Moved).await;
}

/// A host whose hello names no servers (an older build's; here one started while idle
/// hibernation was off): the servers of acpmux's own MCP config of the session, which the harness
/// was started with (`--mcp-config`), are its own. That is the `cmux mcp serve` of the incident.
#[tokio::test]
async fn an_adopted_harness_of_an_older_host_ends_idle_but_for_acpmuxs_own_server() {
    adopted_mcp_server_case("idleold", Case::OlderHost).await;
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Case {
    /// The host's hello names the harness's servers.
    Hello,
    /// The same, and the update moved the server's program aside.
    #[cfg_attr(not(target_os = "macos"), allow(dead_code))]
    Moved,
    /// The hello names none; acpmux's own `cmux mcp serve` runs under the harness.
    OlderHost,
}

async fn adopted_mcp_server_case(tag: &str, case: Case) {
    let pids_file = std::env::temp_dir().join(format!("amd-{tag}-mcp-{}", std::process::id()));
    let _ = std::fs::remove_file(&pids_file);
    let file = pids_file.to_str().unwrap();
    let home = std::env::temp_dir().join(format!("amd-{tag}-{}", std::process::id()));
    // A program of its own for each server (a copy of sleep; the older host's `cmux mcp serve` a
    // copy of yes, whose output nobody reads), in a folder with a space, as in an app bundle.
    let bin = home.join("app bin");
    let program = bin.join("side-mcp");
    let impostor = home.join("other bin").join("side-mcp");
    let mut harness_env = vec![("FAKE_CLAUDE_START_MCP", file)];
    let impostor_argv;
    if case == Case::OlderHost {
        harness_env.push(("FAKE_CLAUDE_START_MCP_CONFIG", "1"));
    }
    if case == Case::Moved {
        // The server's argv, run from another file of the same name.
        impostor_argv = json!({"argv": [program, "3599"], "exe": impostor}).to_string();
        harness_env.push(("FAKE_CLAUDE_START_ALSO", &impostor_argv));
    }
    let mut daemon = Daemon::claude_router(tag, &harness_env);
    assert_eq!(daemon.home, home);
    for dir in [&bin, &home.join("other bin")] {
        std::fs::create_dir_all(dir).unwrap();
    }
    std::fs::copy("/bin/sleep", &program).unwrap();
    std::fs::copy("/bin/sleep", &impostor).unwrap();
    if case == Case::OlderHost {
        // acpmux's own tools fold into one `cmux mcp serve` from its bin folder, as in the app.
        std::fs::copy("/usr/bin/yes", bin.join("cmux")).unwrap();
        daemon.sigterm();
        daemon.env.push(("CMUX_AGENT_TOOLS_BIN_DIR".into(), bin.to_string_lossy().into_owned()));
        // No idle hibernation: the host gets no servers to name in its hello.
        daemon.env.push(("ACPMUX_IDLE_CHILD_SECS".into(), "0".into()));
        daemon.start();
    } else {
        // The folder's .mcp.json names it, as a user or project server is named.
        let mcp = json!({"mcpServers": {"side": {"command": program, "args": ["3599"]}}});
        std::fs::write(home.join(".mcp.json"), mcp.to_string()).unwrap();
    }
    let session = new_session(&daemon).await;
    let mut rpc = daemon.rpc().await;
    let prompt = json!({"sessionId": session, "prompt": [{"type": "text", "text": "hello"}]});
    assert_eq!(rpc.call("session/prompt", prompt).await["stopReason"], "end_turn");
    drop(rpc);
    let harness = daemon.host_record(&session)["harness_pid"].as_i64().unwrap();
    let deadline = Instant::now() + Duration::from_secs(20);
    let pids: Value = loop {
        if let Ok(text) = std::fs::read_to_string(&pids_file) {
            break serde_json::from_str(&text).unwrap();
        }
        assert!(Instant::now() < deadline, "the harness did not start its MCP servers");
        std::thread::sleep(Duration::from_millis(50));
    };
    let _ = std::fs::remove_file(&pids_file);
    let name = if case == Case::OlderHost { "cmux" } else { "side" };
    let server = pids[name].as_i64().unwrap_or_else(|| panic!("no {name} server in {pids}"));
    let also = pids["also"].as_i64();
    // The update restart, with a one-second idle period for the next daemon.
    daemon.sigterm();
    assert!(alive(harness) && alive(server), "the restart ended the agent or its server");
    if case == Case::Moved {
        let aside = home.join("updater cache");
        std::fs::create_dir_all(&aside).unwrap();
        std::fs::rename(&program, aside.join("side-mcp")).unwrap();
        std::fs::copy("/bin/sleep", &program).unwrap();
    }
    daemon.env.retain(|(k, _)| k != "ACPMUX_IDLE_CHILD_SECS");
    daemon.env.push(("ACPMUX_IDLE_CHILD_SECS".into(), "1".into()));
    daemon.start();
    daemon.wait_event(&session, "host_adopted", |e| e["kind"] == "host_adopted");
    let mut kept_by_impostor = true;
    if let Some(also) = also {
        // Several idle periods pass: the server's argv run from another file is work, not a
        // server, though that file has the server's name.
        std::thread::sleep(Duration::from_secs(5));
        kept_by_impostor = alive(harness);
        // SAFETY: the program this test's harness started; its end leaves only the server.
        unsafe { libc::kill(also as i32, libc::SIGKILL) };
    }
    let ended = gone_within(harness, Duration::from_secs(20));
    let server_ended = gone_within(server, Duration::from_secs(10));
    for pid in [Some(harness), Some(server), also].into_iter().flatten() {
        if alive(pid) {
            // SAFETY: this test's harness and what it started; end them before failing.
            unsafe { libc::kill(pid as i32, libc::SIGKILL) };
        }
    }
    assert!(kept_by_impostor, "a program run from another path passed for the moved server");
    assert!(ended, "the idle adopted harness stayed up with only its own MCP server under it");
    assert!(server_ended, "the MCP server outlived its ended harness");
}
