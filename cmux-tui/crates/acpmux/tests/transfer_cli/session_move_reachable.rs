//! A moved chat is reachable from the machine it left the moment the move commits. Leo,
//! 2026-11-23: "if it can "move to cloud" in the BACKEND but i still am able to interact with
//! it with no percievable lag or whatever here ... that's gold."
//!
//! Both daemons are real; the source's ssh peer `target` is the stand-in `ssh` of
//! `session_move.rs`. A move keeps the chat's id, so the source holds two rows with it after
//! the commit: the closed one it keeps (`movedTo`) and the target's mirrored one, `target/ID`.
use super::*;

fn text_prompt(session: &str, prompt_id: &str, text: &str) -> Value {
    json!({"sessionId": session, "prompt": [{"type": "text", "text": text}],
        "_meta": {"acpmux": {"promptId": prompt_id}}})
}

fn acpmux(source: &Daemon) -> tokio::process::Command {
    let mut command = daemon_env::tokio_command(&source.home, daemon_env::Agents::Deny);
    command
        .env(
            "PATH",
            format!("{}:{}", source.home.join("bin").display(), daemon_env::bare_path(&[])),
        )
        .env("ACPMUX_HOME", &source.home)
        .env("ACPMUX_SOCKET", &source.socket)
        .kill_on_drop(true);
    command
}

/// A chat on `source` with one finished turn, and the folder it gets on `target`.
async fn chat(source: &Daemon, target: &Daemon, src: &mut Rpc) -> (String, PathBuf) {
    let cwd = source.home.join("project");
    std::fs::create_dir(&cwd).unwrap();
    let made = src.call("session/new", json!({"cwd": cwd, "mcpServers": []})).await;
    let id = made["sessionId"].as_str().unwrap().to_owned();
    src.call("session/prompt", text_prompt(&id, "p-hi", "hi")).await;
    (id, target.home.join("arrived"))
}

fn move_command(source: &Daemon, id: &str, to: &Path) -> tokio::process::Command {
    let mut command = acpmux(source);
    command.args(["--json", "session", "move", id, "--machine", "target", "--cwd"]).arg(to);
    command
}

/// The source's own row of `id` once the move committed: closed, with where it went.
async fn committed(src: &mut Rpc, id: &str) {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(45);
    loop {
        let info = src.call("_acpmux/info", json!({"sessionId": id})).await;
        if info["status"] == "closed" && info["movedTo"]["host"] == "target" {
            return;
        }
        assert!(tokio::time::Instant::now() < deadline, "the move never committed: {info}");
        tokio::time::sleep(Duration::from_millis(5)).await;
    }
}

async fn user_messages(rpc: &mut Rpc, id: &str) -> Vec<String> {
    let page =
        rpc.call("_acpmux/events", json!({"sessionId": id, "afterSeq": 0, "limit": 5000})).await;
    page["events"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|event| event["kind"] == "user_message")
        .filter_map(|event| event["msg"]["text"].as_str().map(str::to_owned))
        .collect()
}

/// The move ends when this machine lists the chat reachable on the target, and says so in its
/// receipt. It asked for the bare id before, which names the closed row the source keeps: every
/// move then waited out the whole 20 s bound and warned "not listed here yet".
#[tokio::test]
async fn a_move_ends_as_soon_as_the_source_lists_the_chat_on_the_target() {
    let target = Daemon::start("mr-t1").await;
    let source = Daemon::with_peer("mr-s1", Some(&target)).await;
    let mut src = Rpc::connect(&source.socket).await;
    let (id, to) = chat(&source, &target, &mut src).await;

    let started = std::time::Instant::now();
    let moving = tokio::spawn(move_command(&source, &id, &to).output());
    committed(&mut src, &id).await;
    let at_commit = std::time::Instant::now();
    let out = tokio::time::timeout(Duration::from_secs(45), moving)
        .await
        .expect("session move completed")
        .unwrap()
        .expect("run session move");
    let (took, after_commit) = (started.elapsed(), at_commit.elapsed());
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(
        out.status.success(),
        "stdout={} stderr={stderr}",
        String::from_utf8_lossy(&out.stdout)
    );
    let receipt: Value = serde_json::from_slice(&out.stdout).unwrap();
    assert_eq!(receipt["moves"][0]["moved"], true, "{receipt}");
    assert_eq!(receipt["moves"][0]["reachable"], true, "{receipt} stderr={stderr}");
    assert!(!stderr.contains("does not list it reachable"), "{stderr}");

    // What the receipt says is what this machine lists: the target's row, its link up.
    let key = format!("target/{id}");
    let listed = src.call("_acpmux/info", json!({"sessionIds": [key], "row": true})).await;
    let row = &listed["rows"][0];
    assert_eq!(row["peer"], "target", "{listed}");
    assert_ne!(row["stale"], true, "{listed}");
    assert_ne!(row["status"], "closed", "{listed}");
    // The bare id is the row this machine keeps, which no wait turns into the target's.
    let kept = src.call("_acpmux/info", json!({"sessionIds": [id], "row": true})).await;
    assert_eq!(kept["rows"][0]["status"], "closed", "{kept}");

    eprintln!("session move: {took:?} in all, receipt {after_commit:?} after the commit");
    assert!(
        after_commit < Duration::from_secs(3),
        "the receipt came {after_commit:?} after the commit ({took:?} in all): {stderr}"
    );
}

/// A prompt sent through the source the moment the move commits starts a turn on the target:
/// by the peer's row key over the daemon's link, and by the CLI, with no "queued here" detour.
#[tokio::test]
async fn a_prompt_sent_through_the_source_at_the_commit_runs_on_the_target_at_once() {
    let target = Daemon::start("mr-t2").await;
    let source = Daemon::with_peer("mr-s2", Some(&target)).await;
    let mut src = Rpc::connect(&source.socket).await;
    let (id, to) = chat(&source, &target, &mut src).await;
    let key = format!("target/{id}");

    let moving = tokio::spawn(move_command(&source, &id, &to).output());
    committed(&mut src, &id).await;
    // Within the 5 ms poll of the commit, while the move's own client is still up.
    let sent = std::time::Instant::now();
    let done = src.call("session/prompt", text_prompt(&key, "p-at-commit", "at commit")).await;
    let first = sent.elapsed();
    assert_eq!(done["stopReason"], "end_turn", "{done}");

    let out = tokio::time::timeout(Duration::from_secs(45), moving)
        .await
        .expect("session move completed")
        .unwrap()
        .expect("run session move");
    assert!(out.status.success(), "stderr={}", String::from_utf8_lossy(&out.stderr));

    // And straight after the move's client has gone, as a person's send from the source.
    let sent = std::time::Instant::now();
    let out = tokio::time::timeout(
        Duration::from_secs(45),
        acpmux(&source).args(["send", &key, "--quiet", "after the move"]).output(),
    )
    .await
    .expect("send completed")
    .expect("run send");
    let second = sent.elapsed();
    let (stdout, stderr) =
        (String::from_utf8_lossy(&out.stdout), String::from_utf8_lossy(&out.stderr));
    assert!(out.status.success(), "stdout={stdout} stderr={stderr}");
    assert!(!stderr.contains("queued here"), "{stderr}");
    assert!(!stderr.contains("unreachable"), "{stderr}");
    assert!(stdout.contains("echo: after the move"), "the reply is streamed: {stdout}");

    let mut dst = Rpc::connect(&target.socket).await;
    let prompts = user_messages(&mut dst, &id).await;
    let ran: Vec<&str> =
        prompts.iter().map(String::as_str).filter(|p| !p.starts_with("This chat moved")).collect();
    assert_eq!(ran, ["hi", "at commit", "after the move"], "{prompts:?}");
    eprintln!("after a move: the prompt at the commit took {first:?}, the send after {second:?}");
    for took in [first, second] {
        assert!(took < Duration::from_secs(5), "a send after a move took {took:?}");
    }
}
