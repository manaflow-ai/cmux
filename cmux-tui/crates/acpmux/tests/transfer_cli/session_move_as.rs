//! `session move --as HARNESS`: a chat on a harness name the target lacks (`claude-sr2`, Claude
//! Code through a router profile) lands on the target's own harness for the same agent.
use super::session_move::prompt;
use super::*;

/// `acpmux --json session move ID --machine target [--as NAME]` from `source`: its exit, stdout
/// and stderr.
async fn move_as(
    source: &Daemon,
    id: &str,
    cwd: &Path,
    as_harness: Option<&str>,
) -> (bool, String) {
    let mut command = daemon_env::tokio_command(&source.home, daemon_env::Agents::Deny);
    command.args(["--json", "session", "move", id, "--machine", "target", "--cwd"]).arg(cwd);
    if let Some(name) = as_harness {
        command.args(["--as", name]);
    }
    command
        .env(
            "PATH",
            format!("{}:{}", source.home.join("bin").display(), daemon_env::bare_path(&[])),
        )
        .env("ACPMUX_HOME", &source.home)
        .env("ACPMUX_SOCKET", &source.socket)
        .kill_on_drop(true);
    let out = tokio::time::timeout(Duration::from_secs(45), command.output())
        .await
        .expect("session move completed")
        .expect("run session move");
    let text = format!(
        "stdout={} stderr={}",
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr)
    );
    (out.status.success(), text)
}

#[tokio::test]
async fn session_move_as_lands_a_chat_on_the_targets_harness_for_the_same_agent() {
    let target = Daemon::start("as-target").await;
    // The source also has the test agent under a routed profile's name the target lacks.
    let source = Daemon::with_peer_also("as-source", Some(&target), &["fake-routed"]).await;
    let mut src = Rpc::connect(&source.socket).await;

    let cwd = source.home.join("project");
    std::fs::create_dir(&cwd).unwrap();
    let made = src
        .call(
            "session/new",
            json!({"cwd": cwd, "mcpServers": [], "_meta": {"acpmux": {"harness": "fake-routed"}}}),
        )
        .await;
    let id = made["sessionId"].as_str().unwrap().to_owned();
    src.call("session/prompt", prompt(&id, "p-hi", "hi")).await;
    let original_replies = src.texts(&id, "agent_message_chunk").await;
    assert!(!original_replies.is_empty(), "the source conversation has an agent reply");
    let destination = target.home.join("arrived");

    // (a) No --as: refused, and the refusal names the target's harness for the same agent.
    let (moved, text) = move_as(&source, &id, &destination, None).await;
    assert!(!moved, "a harness the target lacks must be refused: {text}");
    assert!(text.contains(r#"agent \"fake-routed\" is not configured here"#), "{text}");
    assert!(text.contains("move with --as fake"), "{text}");
    let info = src.call("_acpmux/info", json!({"sessionId": id})).await;
    assert_ne!(info["status"], "closed", "the refused chat stays here: {info}");
    assert_eq!(info["moving"], false, "{info}");

    // (c) --as a harness the target does not have: refused too, the chat still here.
    let (moved, text) = move_as(&source, &id, &destination, Some("nope")).await;
    assert!(!moved, "--as an unconfigured harness must be refused: {text}");
    assert!(text.contains(r#"agent \"nope\" is not configured here"#), "{text}");
    let info = src.call("_acpmux/info", json!({"sessionId": id})).await;
    assert_ne!(info["status"], "closed", "{info}");
    assert_eq!(info["moving"], false, "{info}");

    // (b) --as fake: moved, on the target's `fake`, history intact, and it answers there.
    let (moved, text) = move_as(&source, &id, &destination, Some("fake")).await;
    assert!(moved, "{text}");
    let mut dst = Rpc::connect(&target.socket).await;
    let info = dst.call("_acpmux/info", json!({"sessionId": id})).await;
    assert_eq!(info["harness"], "fake", "{info}");
    assert_eq!(dst.texts(&id, "user_message").await, ["hi"]);
    let replies = dst.texts(&id, "agent_message_chunk").await;
    assert_eq!(replies, original_replies, "the history came whole");
    dst.call("session/prompt", prompt(&id, "p-after", "after the move")).await;
    assert_eq!(dst.texts(&id, "user_message").await, ["hi", "after the move"]);
    let replies = dst.texts(&id, "agent_message_chunk").await;
    assert!(replies.len() > original_replies.len(), "the moved chat answered: {replies:?}");
    let rows = dst.call("_acpmux/sessions", json!({})).await;
    let row = rows["sessions"]
        .as_array()
        .and_then(|rows| rows.iter().find(|r| r["sessionId"] == id.as_str()))
        .cloned()
        .unwrap_or_else(|| panic!("the target lists the chat: {rows}"));
    assert_eq!(row["harness"], "fake", "{row}");
    let left = src.call("_acpmux/info", json!({"sessionId": id})).await;
    assert_eq!(left["status"], "closed", "{left}");
}
