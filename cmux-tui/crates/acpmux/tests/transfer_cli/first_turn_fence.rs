//! A Mac-first turn runs once (Leo, 2026-11-25: "cuz the startup speed like we can assist in the
//! startup locally too"; "potentially multiple orders at once deduplicated"). The Mac runs a
//! chat's first prompts while its Cloud machine boots, the session move carries the chat to the
//! machine, and a client that sends the same prompt id there (a retry, a second path racing the
//! first) gets the Mac's run back as a duplicate: no second model call (`moved_prompt_fence.rs`).

use super::session_move::prompt;
use super::*;
use std::time::Instant;

/// Turns the Mac runs before the move: a long session, so the move and the fence's log read are
/// measured on a chat with history, not an empty one.
const TURNS: usize = 120;

#[tokio::test]
async fn a_prompt_the_mac_ran_is_answered_on_the_machine_without_running_again() {
    let target = Daemon::start("fence-target").await;
    let source = Daemon::with_peer("fence-source", Some(&target)).await;
    let cwd = source.home.join("project");
    std::fs::create_dir(&cwd).unwrap();
    let mut src = Rpc::connect(&source.socket).await;
    let made = src.call("session/new", json!({"cwd": cwd, "mcpServers": []})).await;
    let id = made["sessionId"].as_str().unwrap().to_owned();
    let id = id.as_str();
    src.call("session/prompt", prompt(id, "p-first", "first")).await;
    for turn in 1..TURNS {
        src.call("session/prompt", prompt(id, &format!("p-{turn}"), &format!("t{turn}"))).await;
    }
    assert_eq!(src.texts(id, "user_message").await.len(), TURNS);

    let destination = target.home.join("arrived");
    let mut command = daemon_env::tokio_command(&source.home, daemon_env::Agents::Deny);
    command
        .args(["--json", "session", "move", id, "--machine", "target", "--interrupt", "--cwd"])
        .arg(&destination)
        .env(
            "PATH",
            format!("{}:{}", source.home.join("bin").display(), daemon_env::bare_path(&[])),
        )
        .env("ACPMUX_HOME", &source.home)
        .env("ACPMUX_SOCKET", &source.socket)
        .kill_on_drop(true);
    let moved_at = Instant::now();
    let out = tokio::time::timeout(Duration::from_secs(60), command.output())
        .await
        .expect("session move completed")
        .expect("run session move");
    assert!(
        out.status.success(),
        "stdout={} stderr={}",
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr)
    );
    let mut dst = Rpc::connect(&target.socket).await;
    let ready = dst
        .call(
            "_acpmux/wait",
            json!({"sessions": [id], "until": ["ready"], "all": true, "timeoutMs": 20000}),
        )
        .await;
    assert_eq!(ready["timedOut"], false, "{ready}");
    let move_ms = moved_at.elapsed().as_millis();
    let before = dst.texts(id, "user_message").await;
    assert_eq!(before.len(), TURNS, "the machine has every turn the Mac ran");

    // The same ids again, not marked resend: the first and the last turn the Mac ran.
    let mut fence_ms = Vec::new();
    for prompt_id in ["p-first", &format!("p-{}", TURNS - 1)] {
        let at = Instant::now();
        let answer = dst.call("session/prompt", prompt(id, prompt_id, "again")).await;
        fence_ms.push(at.elapsed().as_millis());
        assert!(answer.to_string().contains("\"duplicate\":true"), "{prompt_id}: {answer}");
    }
    let after = dst.texts(id, "user_message").await;
    let duplicates = after.len() - before.len();
    assert_eq!(duplicates, 0, "no turn ran twice: {:?}", &after[before.len()..]);

    // A new id runs on the machine as usual.
    let fresh = dst.call("session/prompt", prompt(id, "p-new", "new")).await;
    assert!(!fresh.to_string().contains("\"duplicate\":true"), "{fresh}");
    assert_eq!(dst.texts(id, "user_message").await.last().map(String::as_str), Some("new"));
    println!(
        "DURESS turns={TURNS} moves=1 move_ms={move_ms} fence_ms={fence_ms:?} duplicate_model_calls={duplicates}"
    );
}
