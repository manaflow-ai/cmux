//! What the target can refuse without the chat's bytes, `session move` reports before it freezes
//! or copies anything, and `--dry-run` reports instead of "would move": two real daemons, the
//! stand-in ssh of `session_move.rs`.
use super::*;

/// Runs `acpmux --json session move ID --machine target --cwd DEST` (plus `extra`) against
/// `source`; returns whether it exited zero, and its receipt's row for the chat.
async fn run_move(source: &Daemon, id: &str, dest: &Path, extra: &[&str]) -> (bool, Value) {
    let mut command = daemon_env::tokio_command(&source.home, daemon_env::Agents::Deny);
    command
        .args(["--json", "session", "move", id, "--machine", "target"])
        .args(extra)
        .arg("--cwd")
        .arg(dest)
        .env(
            "PATH",
            format!("{}:{}", source.home.join("bin").display(), daemon_env::bare_path(&[])),
        )
        .env("ACPMUX_HOME", &source.home)
        .env("ACPMUX_SOCKET", &source.socket)
        .kill_on_drop(true);
    let out = tokio::time::timeout(Duration::from_secs(45), command.output())
        .await
        .expect("session move ended")
        .expect("run session move");
    let stdout = String::from_utf8_lossy(&out.stdout);
    let stderr = String::from_utf8_lossy(&out.stderr);
    let receipt: Value = serde_json::from_str(stdout.trim())
        .unwrap_or_else(|_| panic!("no receipt: stdout={stdout} stderr={stderr}"));
    (out.status.success(), receipt["moves"][0].clone())
}

/// The chat on `source` is as it was: open, not frozen, and no move of it ever began.
async fn assert_untouched(src: &mut Rpc, id: &str) {
    let info = src.call("_acpmux/info", json!({"sessionId": id})).await;
    assert_ne!(info["status"], "closed", "{info}");
    assert_eq!(info["moving"], false, "{info}");
    let page =
        src.call("_acpmux/events", json!({"sessionId": id, "afterSeq": 0, "limit": 5000})).await;
    let kinds: Vec<&str> =
        page["events"].as_array().unwrap().iter().filter_map(|e| e["kind"].as_str()).collect();
    assert!(!kinds.is_empty(), "the chat has a log");
    assert!(!kinds.iter().any(|k| k.starts_with("transfer")), "no move began: {kinds:?}");
}

#[tokio::test]
async fn a_target_without_the_chats_harness_refuses_the_dry_run_and_the_move_before_the_freeze() {
    let target = Daemon::start("pfh-target").await;
    let source = Daemon::with_harness("pfh-source", Some(&target), "fake-sr2").await;
    let cwd = source.home.join("project");
    std::fs::create_dir(&cwd).unwrap();
    let mut src = Rpc::connect(&source.socket).await;
    let made = src.call("session/new", json!({"cwd": cwd, "mcpServers": []})).await;
    let id = made["sessionId"].as_str().unwrap();
    src.call("session/prompt", prompt(id, "p-hi", "hi")).await;
    let dest = target.home.join("arrived");

    let (ok, dry) = run_move(&source, id, &dest, &["--dry-run"]).await;
    assert!(!ok, "a dry run of a move the target refuses exits non-zero: {dry}");
    assert_eq!(dry["errorCode"], "transfer.harness", "{dry}");
    let said = dry["error"].as_str().unwrap_or_default();
    assert!(said.contains("transfer.harness: agent \"fake-sr2\" is not configured here"), "{dry}");
    assert!(said.contains("needs a harness profile named \"fake-sr2\""), "what to do: {dry}");
    assert_ne!(dry["moved"], true, "{dry}");
    assert_untouched(&mut src, id).await;

    let (ok, real) = run_move(&source, id, &dest, &[]).await;
    assert!(!ok, "{real}");
    assert_eq!(real["errorCode"], "transfer.harness", "{real}");
    assert_eq!(real["error"], dry["error"], "the dry run says what the move says");
    assert_untouched(&mut src, id).await;
    assert!(!dest.exists(), "nothing was made on the target");
    // The chat still answers here.
    src.call("session/prompt", prompt(id, "p-again", "again")).await;
}

#[tokio::test]
async fn a_chat_the_target_already_has_refuses_the_dry_run() {
    let target = Daemon::start("pfe-target").await;
    let source = Daemon::with_peer("pfe-source", Some(&target)).await;
    let cwd = source.home.join("project");
    std::fs::create_dir(&cwd).unwrap();
    let mut src = Rpc::connect(&source.socket).await;
    let made = src.call("session/new", json!({"cwd": cwd, "mcpServers": []})).await;
    let id = made["sessionId"].as_str().unwrap();
    src.call("session/prompt", prompt(id, "p-hi", "hi")).await;

    // A copy of it lands on the target, and the source then keeps its own (the move's commit
    // never came): the chat is live on both.
    let there = target.home.join("there");
    std::fs::create_dir(&there).unwrap();
    let mut dst = Rpc::connect(&target.socket).await;
    let begin = src.call("_acpmux/transfer_begin", json!({"sessionId": id})).await;
    let epoch = begin["epoch"].clone();
    let receive = dst.call("_acpmux/transfer_receive", json!({"manifest": begin})).await;
    for file in begin["files"].as_array().unwrap() {
        let mut offset = 0u64;
        loop {
            let at = json!({"transferId": begin["transferId"], "path": file["path"],
                "offset": offset, "epoch": epoch});
            let page = src.call("_acpmux/transfer_read", at).await;
            let write = json!({"receiveId": receive["receiveId"], "path": file["path"],
                "offset": offset, "data": page["data"], "epoch": epoch});
            dst.call("_acpmux/transfer_write", write).await;
            offset = page["next"].as_u64().unwrap();
            if page["eof"] == true {
                break;
            }
        }
    }
    let finish = json!({"receiveId": receive["receiveId"], "from": {"sessionId": id},
        "epoch": epoch, "cwd": there});
    dst.call("_acpmux/transfer_finish", finish).await;
    let abort = json!({"sessionId": id, "transferId": begin["transferId"], "epoch": epoch});
    src.call("_acpmux/transfer_abort", abort).await;
    let info = src.call("_acpmux/info", json!({"sessionId": id})).await;
    assert_eq!(info["moving"], false, "{info}");

    let dest = target.home.join("arrived");
    let (ok, dry) = run_move(&source, id, &dest, &["--dry-run"]).await;
    assert!(!ok, "{dry}");
    assert_eq!(dry["errorCode"], "transfer.exists", "{dry}");
    let said = dry["error"].as_str().unwrap_or_default();
    assert!(said.contains(&format!("transfer.exists: chat {id} is here already")), "{dry}");
    let after = src.call("_acpmux/info", json!({"sessionId": id})).await;
    assert_eq!(after["moving"], false, "{after}");
    assert_ne!(after["status"], "closed", "{after}");
}
