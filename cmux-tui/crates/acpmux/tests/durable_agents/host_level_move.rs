//! A chat whose adopted host is below this build's level moves onto the installed build at its
//! next idle point, long before the idle period, and its next prompt is answered by a new host
//! (`hub/host_level.rs`). One on this build's level stays up as before. Before, a daemon update
//! left every busy chat on the host it started from, and with it the translator fix that stops
//! next-prompt suggestions after agent turns (sr2 audit, 2026-11-21: about 1,100 an hour).

use super::*;

/// A daemon with a 10-minute idle period and one answered Claude chat, restarted so the next
/// daemon adopts its host; `older` first rewrites the host's record as a build before
/// `HOST_LEVEL` wrote it (no level, another build). Returns the daemon, the chat and its harness.
async fn adopted_chat(tag: &str, older: bool) -> (Daemon, String, i64) {
    let mut daemon = Daemon::claude_router(tag, &[]);
    let session = new_session(&daemon).await;
    let prompt = json!({"sessionId": session, "prompt": [{"type": "text", "text": "hello"}]});
    let answer = daemon.rpc().await.call("session/prompt", prompt).await;
    assert_eq!(answer["stopReason"], "end_turn", "the first prompt was not answered: {answer}");
    let record = daemon.host_record(&session);
    assert_eq!(
        record["host_level"],
        acpmux::agent_host::HOST_LEVEL,
        "this build's host says its level"
    );
    let harness = record["harness_pid"].as_i64().unwrap();
    daemon.sigterm();
    if older {
        let path = daemon.home.join("hosts").join(format!("{session}.json"));
        let mut old = record.clone();
        old.as_object_mut().unwrap().remove("host_level");
        old["host_build"] = json!("1.0.0 (70fdd225f 2026-11-20)");
        std::fs::write(&path, old.to_string()).unwrap();
    }
    daemon.env.push(("ACPMUX_IDLE_CHILD_SECS".into(), "600".into()));
    daemon.start();
    daemon.wait_event(&session, "host_adopted", |e| e["kind"] == "host_adopted");
    (daemon, session, harness)
}

#[tokio::test]
async fn an_adopted_host_below_the_level_moves_at_its_next_idle_point_and_its_chat_goes_on() {
    let (daemon, session, harness) = adopted_chat("hlmove", true).await;
    // Its idle period is 10 minutes: only the move ends the harness within half a minute.
    let moved = gone_within(harness, Duration::from_secs(30));
    if !moved {
        daemon.rpc().await.call("_acpmux/kill", json!({"sessionId": session})).await;
    }
    assert!(moved, "a host below the level kept its chat on the old build while idle");
    let prompt = json!({"sessionId": session, "prompt": [{"type": "text", "text": "again"}]});
    let answer = daemon.rpc().await.call("session/prompt", prompt).await;
    assert_eq!(answer["stopReason"], "end_turn", "the moved chat did not answer: {answer}");
    let record = daemon.host_record(&session);
    assert_ne!(record["harness_pid"].as_i64().unwrap(), harness, "no new harness answered");
    assert_eq!(
        record["host_level"],
        acpmux::agent_host::HOST_LEVEL,
        "the new host is not at the level"
    );
}

#[tokio::test]
async fn an_adopted_host_at_the_level_stays_up_until_its_idle_period() {
    let (daemon, session, harness) = adopted_chat("hlstay", false).await;
    // Longer than the move's 10 s, far shorter than the 10-minute idle period.
    std::thread::sleep(Duration::from_secs(20));
    let kept = alive(harness);
    daemon.rpc().await.call("_acpmux/kill", json!({"sessionId": session})).await;
    assert!(kept, "a host at the level was ended before its idle period");
}

/// An old host whose chat never moves (here idle hibernation is off, as for a chat always at
/// work): before an agent's turn the daemon turns the chat's `prompt-suggestions` option off
/// on it, so its translator pauses Claude Code's suggestions (`psp-` lines, not the newer host's
/// own `turnpsp-` ones), and before the person's next turn on again. The chat's saved option
/// still says on.
#[tokio::test]
async fn an_old_host_that_never_moves_pauses_suggestions_for_an_agents_turn_only() {
    let log = std::env::temp_dir().join(format!("amd-hlpause-log-{}", std::process::id()));
    let _ = std::fs::remove_file(&log);
    let mut daemon =
        Daemon::claude_router("hlpause", &[("FAKE_CLAUDE_PAUSE_LOG", log.to_str().unwrap())]);
    let session = new_session(&daemon).await;
    let prompt =
        |text: &str| json!({"sessionId": session, "prompt": [{"type": "text", "text": text}]});
    let answer = daemon.rpc().await.call("session/prompt", prompt("hello")).await;
    assert_eq!(answer["stopReason"], "end_turn", "the first prompt was not answered: {answer}");
    let record = daemon.host_record(&session);
    let harness = record["harness_pid"].as_i64().unwrap();
    daemon.sigterm();
    let path = daemon.home.join("hosts").join(format!("{session}.json"));
    let mut old = record.clone();
    old.as_object_mut().unwrap().remove("host_level");
    old["host_build"] = json!("1.0.0 (70fdd225f 2026-11-20)");
    std::fs::write(&path, old.to_string()).unwrap();
    // Another agent's message starts a turn of its own, not an inbox notice.
    let config_path = daemon.home.join("config.json");
    let mut config: Value = serde_json::from_slice(&std::fs::read(&config_path).unwrap()).unwrap();
    config["agentInbox"] = json!(false);
    std::fs::write(&config_path, config.to_string()).unwrap();
    daemon.env.push(("ACPMUX_IDLE_CHILD_SECS".into(), "0".into()));
    daemon.start();
    daemon.wait_event(&session, "host_adopted", |e| e["kind"] == "host_adopted");
    let _ = std::fs::remove_file(&log);
    // Another agent's message.
    let mut message = prompt("from an agent");
    message["_meta"] = json!({"acpmux": {"provenance": {
        "kind": "agent_message", "from": "acp:other", "fromName": "other",
        "to": format!("acp:{session}"), "msgId": "m-1", "threadId": "t-1"}}});
    let answer = daemon.rpc().await.call("session/prompt", message).await;
    assert_eq!(answer["stopReason"], "end_turn", "the agent's message was not answered: {answer}");
    let after_agent = std::fs::read_to_string(&log).unwrap_or_default();
    // A mode write: the host answers with its options, suggestions off among them.
    let _ = daemon
        .rpc()
        .await
        .reply("session/set_mode", json!({"sessionId": session, "modeId": "default"}))
        .await;
    let answer = daemon.rpc().await.call("session/prompt", prompt("the person again")).await;
    assert_eq!(answer["stopReason"], "end_turn", "the person's prompt was not answered: {answer}");
    let all = std::fs::read_to_string(&log).unwrap_or_default();
    assert_eq!(
        daemon.host_record(&session)["harness_pid"].as_i64().unwrap(),
        harness,
        "the host moved"
    );
    daemon.rpc().await.call("_acpmux/kill", json!({"sessionId": session})).await;
    daemon.sigterm();
    let _ = std::fs::remove_file(&log);
    assert!(
        after_agent.lines().any(|l| l == "psp true"),
        "no pause before the agent's turn: {after_agent:?}"
    );
    let lifted = all.lines().skip(after_agent.lines().count()).any(|l| l == "psp false");
    assert!(lifted, "the pause was not lifted before the person's turn: {all:?}");
    let meta_path = daemon.home.join("sessions").join(&session).join("session.json");
    let meta: Value = serde_json::from_slice(&std::fs::read(&meta_path).unwrap()).unwrap();
    let saved = meta["configOptions"]
        .as_array()
        .and_then(|a| a.iter().find(|o| o["id"] == "prompt-suggestions"))
        .map(|o| o["currentValue"].clone());
    assert_ne!(saved, Some(json!("off")), "the daemon's off was saved as the chat's pick");
}
