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

/// Claude Code honours the per-turn pause only under a server-side flag of its own, off by
/// default, and reads `promptSuggestions` once, at `initialize`. So a start for another agent's
/// message asks for no suggestions at all, and the next start for the person's own prompt asks
/// for them again (`hub/host_level.rs` `start_params`).
#[tokio::test]
async fn a_start_for_an_agents_message_asks_for_no_suggestions_and_a_persons_does() {
    let log = std::env::temp_dir().join(format!("amd-hlinit-log-{}", std::process::id()));
    let _ = std::fs::remove_file(&log);
    let mut daemon =
        Daemon::claude_router("hlinit", &[("FAKE_CLAUDE_INIT_LOG", log.to_str().unwrap())]);
    daemon.sigterm();
    let config_path = daemon.home.join("config.json");
    let mut config: Value = serde_json::from_slice(&std::fs::read(&config_path).unwrap()).unwrap();
    config["agentInbox"] = json!(false);
    std::fs::write(&config_path, config.to_string()).unwrap();
    daemon.env.push(("ACPMUX_IDLE_CHILD_SECS".into(), "1".into()));
    daemon.start();
    let session = new_session(&daemon).await;
    let prompt =
        |text: &str| json!({"sessionId": session, "prompt": [{"type": "text", "text": text}]});
    let mut message = prompt("from an agent");
    message["_meta"] = json!({"acpmux": {"provenance": {
        "kind": "agent_message", "from": "acp:other", "fromName": "other",
        "to": format!("acp:{session}"), "msgId": "m-1", "threadId": "t-1"}}});
    let answer = daemon.rpc().await.call("session/prompt", message).await;
    assert_eq!(answer["stopReason"], "end_turn", "the agent's message was not answered: {answer}");
    let harness = daemon.host_record(&session)["harness_pid"].as_i64().unwrap();
    // It hibernates; the person's prompt starts it again.
    let slept = gone_within(harness, Duration::from_secs(20));
    let answer = daemon.rpc().await.call("session/prompt", prompt("the person")).await;
    let woken = daemon.host_record(&session)["harness_pid"].as_i64().unwrap();
    let all = std::fs::read_to_string(&log).unwrap_or_default();
    daemon.rpc().await.call("_acpmux/kill", json!({"sessionId": session})).await;
    let _ = std::fs::remove_file(&log);
    assert_eq!(answer["stopReason"], "end_turn", "the person's prompt was not answered: {answer}");
    assert!(slept, "the idle agent did not hibernate");
    assert_ne!(woken, harness, "the person's prompt was not answered by a new harness");
    // The chat's own processes only: a title or model probe starts one of its own.
    let asked = |pid: i64| {
        all.lines().find_map(|l| l.strip_prefix(&format!("init {pid} "))).map(str::to_owned)
    };
    assert_eq!(
        asked(harness).as_deref(),
        Some("false"),
        "the agent's start asked for suggestions: {all:?}"
    );
    assert_eq!(asked(woken).as_deref(), Some("true"), "the person's start asked for none: {all:?}");
}

/// One answered Claude chat on a daemon with a 10-minute idle period, restarted so the next
/// daemon adopts its host, after its meta is rewritten as an older daemon left it: no level it
/// started the host at (`SessionMeta::start_level`). The host itself is this build's. That is a
/// host started while an update waited out its restart window: the new binary in place, the old
/// daemon still running. `person`: the person creates the chat. Returns the daemon, the chat and
/// its harness.
async fn chat_an_older_daemon_started(tag: &str, person: bool) -> (Daemon, String, i64) {
    let mut daemon = Daemon::claude_router(tag, &[]);
    if person {
        daemon.sigterm();
        daemon.key = Some(PROVEN_KEY.to_owned());
        daemon.start();
    }
    let mut rpc = daemon.rpc().await;
    if person {
        prove(&mut rpc).await;
    }
    let created = rpc.call("session/new", json!({"cwd": daemon.home, "mcpServers": []})).await;
    let session = created["sessionId"].as_str().expect("session id").to_owned();
    let prompt = json!({"sessionId": session, "prompt": [{"type": "text", "text": "hello"}]});
    let answer = rpc.call("session/prompt", prompt).await;
    assert_eq!(answer["stopReason"], "end_turn", "the first prompt was not answered: {answer}");
    let record = daemon.host_record(&session);
    assert_eq!(record["host_level"], acpmux::agent_host::HOST_LEVEL, "the host is this build's");
    let harness = record["harness_pid"].as_i64().unwrap();
    drop(rpc);
    daemon.sigterm();
    let path = daemon.saved_meta_path(&session);
    let mut meta: Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
    meta.as_object_mut().unwrap().remove("startLevel");
    std::fs::write(&path, meta.to_string()).unwrap();
    daemon.env.push(("ACPMUX_IDLE_CHILD_SECS".into(), "600".into()));
    daemon.start();
    daemon.wait_event(&session, "host_adopted", |e| e["kind"] == "host_adopted");
    (daemon, session, harness)
}

/// Red on the base: a script's chat whose host an older daemon started kept it, and with it a
/// next-prompt suggestion after every turn, until its idle period: its host's record says this
/// build's level. On one lane every start until 20:37Z asked for suggestions, about 80 minutes
/// after its new binary came (sr2 audit, 2026-11-21). It moves at its next idle point and its next
/// start is this daemon's.
#[tokio::test]
async fn a_scripts_chat_on_a_host_an_older_daemon_started_moves_at_its_next_idle_point() {
    let (daemon, session, harness) = chat_an_older_daemon_started("hlstart", false).await;
    let moved = gone_within(harness, Duration::from_secs(30));
    if !moved {
        daemon.rpc().await.call("_acpmux/kill", json!({"sessionId": session})).await;
    }
    assert!(moved, "a host an older daemon started kept a script's chat while idle");
    let prompt = json!({"sessionId": session, "prompt": [{"type": "text", "text": "again"}]});
    let answer = daemon.rpc().await.call("session/prompt", prompt).await;
    assert_eq!(answer["stopReason"], "end_turn", "the moved chat did not answer: {answer}");
    let record = daemon.host_record(&session);
    assert_ne!(record["harness_pid"].as_i64().unwrap(), harness, "no new harness answered");
    daemon.rpc().await.call("_acpmux/kill", json!({"sessionId": session})).await;
}

/// A person's chat on such a host stays up until its idle period: its start asked for the
/// suggestions the person gets anyway, so a move would only cost them a cold start.
#[tokio::test]
async fn a_persons_chat_on_a_host_an_older_daemon_started_stays_up() {
    let (daemon, session, harness) = chat_an_older_daemon_started("hlstartp", true).await;
    // Longer than the move's 10 s, far shorter than the 10-minute idle period.
    std::thread::sleep(Duration::from_secs(20));
    let kept = alive(harness);
    daemon.rpc().await.call("_acpmux/kill", json!({"sessionId": session})).await;
    assert!(kept, "a person's chat was moved off a host of this build");
}
