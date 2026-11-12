//! The machine that runs acpmux reboots under a live chat. Leo, 2026-11-12: "we're gonna need to
//! fix this situation: ... lawrence restarted this computer 1. we should not get into this state
//! 2. if we do the recovery needs to be a lot better and it shouldn't talk so much b******t".
//!
//! A reboot ends the daemon and every agent host at once, with no cleanup (SIGKILL here), and
//! leaves their files: `daemon.lock`, `daemon.pid`, the socket, the host records. After a reboot
//! pids start over, so the pid those files name may be some other live process. The next daemon
//! (what the app's launcher or any CLI command starts, `daemon run --ready-fd`) must come up on
//! those files, the chat must answer as before with a new agent, and a prompt the client sends
//! again under the same prompt id after it reconnects (the pane holds a send it never heard back
//! about, and sends it again once) must reach the agent once. A copy the agent service may have
//! taken goes again marked `resend` (the host's relay journal); the pane's own held send goes
//! again only after a refusal that never left the pane (`native.not_connected`), so an unmarked
//! id after a restart stays a new prompt (`hub_integration` `prompt_approval`).

use super::*;

/// Ends this test daemon and every agent host it started, as a reboot ends them, leaving every
/// file in place; then writes the pid of a live process that is no daemon (this test's) into
/// `daemon.lock` and `daemon.pid`, as a pid reused after the reboot reads.
fn reboot(daemon: &mut Daemon) {
    let mut pids = Vec::new();
    for path in std::fs::read_dir(daemon.home.join("hosts"))
        .map(|d| d.filter_map(|e| e.ok().map(|e| e.path())).collect::<Vec<_>>())
        .unwrap_or_default()
    {
        if path.extension().and_then(|e| e.to_str()) != Some("json") {
            continue;
        }
        let Ok(r) = serde_json::from_slice::<Value>(&std::fs::read(&path).unwrap_or_default())
        else {
            continue;
        };
        pids.extend([r["harness_pid"].as_i64(), r["host_pid"].as_i64()].into_iter().flatten());
    }
    daemon.sigkill();
    for pid in &pids {
        // SAFETY: process groups this test's daemon created.
        unsafe { libc::killpg(*pid as i32, libc::SIGKILL) };
    }
    for pid in &pids {
        assert!(
            gone_within(*pid, Duration::from_secs(10)),
            "agent process {pid} outlived the reboot"
        );
    }
    for left in ["daemon.lock", "daemon.pid"] {
        assert!(daemon.home.join(left).exists(), "the killed daemon left no {left}");
    }
    assert!(daemon.socket.exists(), "the killed daemon left no socket file");
    let reused = std::process::id();
    std::fs::write(
        daemon.home.join("daemon.lock"),
        format!("{reused}\n{}\n", daemon.socket.display()),
    )
    .unwrap();
    std::fs::write(daemon.home.join("daemon.pid"), reused.to_string()).unwrap();
}

/// `session/prompt` with prompt id `id`; `resend` as the host marks a copy it sent before.
async fn prompt(rpc: &mut Rpc, session: &str, text: &str, id: &str, resend: bool) -> Value {
    let mut acpmux = json!({"promptId": id});
    if resend {
        acpmux["resend"] = json!(true);
    }
    rpc.reply(
        "session/prompt",
        json!({"sessionId": session, "prompt": [{"type": "text", "text": text}], "_meta": {"acpmux": acpmux}}),
    )
    .await
}

fn echoes(daemon: &Daemon, session: &str, text: &str) -> usize {
    let echo = format!("echo: {text}");
    daemon.events(session).iter().filter(|e| chunk(e, &echo)).count()
}

fn turns_of(daemon: &Daemon, session: &str, id: &str) -> usize {
    daemon
        .events(session)
        .iter()
        .filter(|e| e["kind"] == "turn_started" && e["msg"]["promptId"] == id)
        .count()
}

/// A prompt that ran before the reboot, whose answer the client never heard, is sent again under
/// its id after the restart: it is answered from the log and never reaches the agent again. The
/// chat goes on with a new agent, and no step but starting the daemon (the launcher's) is taken.
#[tokio::test]
async fn after_a_reboot_the_chat_answers_and_a_prompt_sent_again_runs_once() {
    let mut daemon = Daemon::new("reboot", "approve-all");
    let session = new_session(&daemon).await;
    let first_agent = daemon.host_record(&session)["harness_pid"].as_i64();
    let mut client = daemon.rpc().await;
    let ran = prompt(&mut client, &session, "before the reboot", "p-reboot", false).await;
    assert_eq!(ran["result"]["stopReason"], "end_turn", "{ran:#}");
    drop(client);

    reboot(&mut daemon);
    let started = Instant::now();
    daemon.start();
    let ready_in = started.elapsed();
    let mut client = daemon.rpc().await;

    // The host's copy (`resend`), twice: both answer from the first run.
    for _ in 0..2 {
        let again = prompt(&mut client, &session, "before the reboot", "p-reboot", true).await;
        assert_eq!(again["result"]["stopReason"], "end_turn", "{again:#}");
    }
    assert_eq!(echoes(&daemon, &session, "before the reboot"), 1, "the prompt ran again");
    assert_eq!(turns_of(&daemon, &session, "p-reboot"), 1, "the prompt took a second turn");

    // The chat goes on, with a new agent, and a prompt sent twice in this daemon's life runs once.
    for _ in 0..2 {
        let next = prompt(&mut client, &session, "after the reboot", "p-after", false).await;
        assert_eq!(next["result"]["stopReason"], "end_turn", "{next:#}");
    }
    assert_eq!(echoes(&daemon, &session, "after the reboot"), 1);
    let agent = daemon.host_record(&session)["harness_pid"].as_i64();
    assert!(agent.is_some_and(alive), "no agent runs the chat after the reboot");
    assert_ne!(agent, first_agent, "the chat's agent is the one the reboot ended");
    eprintln!("reboot: the next daemon was ready in {} ms", ready_in.as_millis());
}

/// A prompt whose turn the reboot cut: the restarted daemon goes on with it by itself (its
/// continuation, `restart_resume.rs`), and the client's copy of the cut prompt, sent under its id
/// after it reconnects, does not run it a second time.
#[tokio::test]
async fn a_prompt_a_reboot_cut_goes_on_once_when_the_client_sends_it_again() {
    let mut daemon = Daemon::new("rebootcut", "approve-all");
    let session = new_session(&daemon).await;
    let gate = daemon.home.join("gate");
    make_fifo(&gate);
    let cut = format!("gate: {}", gate.display());
    let mut client = daemon.rpc().await;
    client
        .send(
            "session/prompt",
            json!({"sessionId": session, "prompt": [{"type": "text", "text": cut}], "_meta": {"acpmux": {"promptId": "p-cut"}}}),
        )
        .await;
    daemon.wait_event(&session, "before-gate chunk", |e| chunk(e, "before-gate"));
    drop(client);

    reboot(&mut daemon);
    daemon.start();
    let mut client = daemon.rpc().await;
    for _ in 0..2 {
        // Answered from the cut turn's record (its outcome, or that it was cut), never run.
        let again = prompt(&mut client, &session, &cut, "p-cut", true).await;
        eprintln!("reboot: the cut prompt sent again answered {again}");
    }
    // The continuation runs before a prompt sent after it: once this answers, it ran.
    let next = prompt(&mut client, &session, "after the cut", "p-next", false).await;
    assert_eq!(next["result"]["stopReason"], "end_turn", "{next:#}");
    let events = daemon.events(&session);
    assert!(
        events.iter().any(|e| e["kind"] == "turn_started"
            && e["msg"]["promptId"].as_str().is_some_and(|id| id.starts_with("p-cut~resume-"))),
        "the cut turn was not continued: {events:#?}"
    );
    assert_eq!(turns_of(&daemon, &session, "p-cut"), 1, "the cut prompt ran again");
    assert_eq!(events.iter().filter(|e| chunk(e, "before-gate")).count(), 1, "it ran again");
    assert_eq!(echoes(&daemon, &session, "after the cut"), 1);
}
