//! A renderer mint that the terminal host does not answer fails with a typed
//! code and its root cause. Before this, both the legacy commands and
//! `terminal.renderer_grant.create` returned only the outer context
//! "terminal host did not mint renderer grant" and no code, so a client
//! could not tell a stopped or lost host from a refused caller.

use super::*;

fn mint_by_terminal(socket: &Path, id: u64, terminal: &str) -> serde_json::Value {
    request_response(
        socket,
        serde_json::json!({
            "id": id,
            "cmd": "mint-terminal-renderer-by-terminal",
            "terminal": terminal,
            "ttl_ms": 10_000,
        }),
    )
}

#[test]
fn unanswered_renderer_mint_fails_with_a_typed_code_and_its_cause() {
    let harness = RecoveryHarness::start("mint-typed-errors");
    let workspace = resource_request(
        &harness.socket,
        "mint-errors-workspace",
        "workspace.create",
        serde_json::json!({
            "machine":"current",
            "session":"current",
            "name":"Mint errors",
            "initial_content":"empty",
        }),
        Some("mint-errors-workspace"),
    );
    let workspace = workspace["value"]["workspace_id"].as_str().unwrap();
    let run = resource_request(
        &harness.socket,
        "mint-errors-run",
        "workspace.run",
        serde_json::json!({
            "machine":"current",
            "session":"current",
            "workspace":workspace,
            "argv":["/bin/cat"],
        }),
        Some("mint-errors-run"),
    );
    let terminal = run["value"]["terminal_id"].as_str().unwrap().to_string();
    let (_, record) = wait_for_host_records(&harness.host_root(), 1).remove(0);
    let minted = mint_by_terminal(&harness.socket, 1, &terminal);
    assert_eq!(minted["ok"], true, "mint before the stop failed: {minted}");

    let host_pid = record.host_pid as libc::pid_t;
    // SAFETY: the durable record identifies this harness's live terminal host.
    assert_eq!(unsafe { libc::kill(host_pid, libc::SIGSTOP) }, 0);

    // The stopped host never answers MintCapability: the daemon's control
    // deadline expires.
    let legacy = mint_by_terminal(&harness.socket, 2, &terminal);
    assert_eq!(legacy["ok"], false, "a stopped host minted a grant: {legacy}");
    assert_eq!(legacy["error_code"], "terminal_host_unavailable", "{legacy}");
    assert_eq!(legacy["error_details"]["reason"], "timeout", "{legacy}");
    let message = legacy["error"].as_str().unwrap();
    assert!(
        message.starts_with("terminal host did not mint renderer grant: ")
            && message.contains("MintCapability"),
        "the message lost its root cause: {message}"
    );

    // The timeout ended the daemon's admin connection; the next mint either
    // times out again or finds the connection gone. Both are the same typed,
    // retryable error.
    let response = request_response(
        &harness.socket,
        serde_json::json!({
            "protocol":"cmux.protocol/2",
            "type":"request",
            "id":"mint-errors-v2",
            "operation":"terminal.renderer_grant.create",
            "params":{
                "machine":"current",
                "session":"current",
                "terminal":&terminal,
                "ttl_ms":10_000,
            },
        }),
    );
    assert_eq!(response["ok"], false, "a stopped host minted a grant: {response}");
    let error = &response["error"];
    assert_eq!(error["code"], "terminal_host.unavailable", "{response}");
    assert_eq!(error["retryable"], true, "{response}");
    assert_eq!(error["details"]["terminal_id"], terminal.as_str(), "{response}");
    let reason = error["details"]["reason"].as_str().unwrap();
    assert!(matches!(reason, "timeout" | "disconnected"), "{response}");
    assert!(
        error["message"]
            .as_str()
            .unwrap()
            .starts_with("terminal host did not mint renderer grant: "),
        "{response}"
    );

    // SAFETY: this resumes the same host stopped above.
    assert_eq!(unsafe { libc::kill(host_pid, libc::SIGCONT) }, 0);
    // The daemon reconnects to the resumed host; minting works again.
    let deadline = Instant::now() + test_timeout(Duration::from_secs(15));
    let mut id = 10;
    loop {
        let minted = mint_by_terminal(&harness.socket, id, &terminal);
        if minted["ok"] == true {
            break;
        }
        assert_eq!(minted["error_code"], "terminal_host_unavailable", "{minted}");
        assert!(Instant::now() < deadline, "mint never recovered after SIGCONT: {minted}");
        std::thread::sleep(Duration::from_millis(50));
        id += 1;
    }
}
