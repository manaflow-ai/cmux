//! A prompt sent while a turn runs interrupts it by default (user, 2026-10-20: "We want to
//! always interrupt, but it should have an option to queue and that should not be the
//! default"). The running turn stops and the new prompt runs next, for every harness kind:
//! ACP (OpenCode, codex-acp, the fake agent), Claude Code's stream-json and Codex's
//! app-server bridge. `_meta.acpmux.queue: true` (or the daemon's `busyPrompt: "queue"`)
//! keeps the old wait behind the running turn.
//!
//! A burst of prompts during one turn keeps every message, in the order they were sent:
//! prompts that wait behind an interrupt run in send order, and one that is overtaken
//! before its turn starts goes to the agent at the head of the next prompt.

use super::*;
use std::os::unix::fs::PermissionsExt;
use std::time::Instant;

/// How long an interrupting prompt may wait for the stopped turn: well under the 10 s an
/// agent that ignores the cancel is given (`hub/cancel.rs`), so a pass means it was stopped.
const PROMPT_STOP_BUDGET: Duration = Duration::from_secs(5);

fn text_prompt(id: &str, text: &str, prompt_id: &str, extra: Value) -> Value {
    let mut meta = json!({"promptId": prompt_id});
    if let (Some(m), Some(extra)) = (meta.as_object_mut(), extra.as_object()) {
        m.extend(extra.clone());
    }
    json!({"sessionId": id, "prompt": [{"type": "text", "text": text}], "_meta": {"acpmux": meta}})
}

fn hub_with(profile: HarnessProfile, edit: impl FnOnce(&mut Config)) -> Arc<Hub> {
    let mut cfg = Config {
        harnesses: BTreeMap::from([("h".to_owned(), profile)]),
        default_harness: Some("h".into()),
        ..Default::default()
    };
    cfg.store.mode = StoreMode::Memory;
    cfg.permission_policy = PermissionPolicy::ApproveAll;
    edit(&mut cfg);
    let store = acpmux::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    hold_person_key(&hub);
    hub
}

fn profile(
    kind: acpmux::config::HarnessKind,
    argv: Vec<String>,
    env: BTreeMap<String, String>,
) -> HarnessProfile {
    HarnessProfile {
        kind,
        argv,
        env,
        description: None,
        fallback: None,
        family: None,
        models: vec![],
        model: None,
        effort: None,
        policy: None,
    }
}

/// The three harness kinds: (name, profile, the prompt that runs until stopped).
fn harnesses() -> Vec<(&'static str, HarnessProfile, &'static str)> {
    let fake_agent = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let fake_claude = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_claude.py");
    let fake_codex = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_codex_app_server.py");
    let root = std::env::temp_dir().join(format!("acpmux-busy-{}", uuid::Uuid::now_v7()));
    let bin = root.join("bin");
    let home = root.join("codex-home");
    std::fs::create_dir_all(&bin).unwrap();
    std::fs::create_dir_all(&home).unwrap();
    let codex = bin.join("codex");
    std::fs::write(&codex, format!("#!/bin/sh\nexec python3 {fake_codex} \"$@\"\n")).unwrap();
    std::fs::set_permissions(&codex, std::fs::Permissions::from_mode(0o755)).unwrap();
    use acpmux::config::HarnessKind;
    vec![
        (
            "acp",
            profile(
                HarnessKind::default(),
                vec!["python3".into(), fake_agent.into()],
                BTreeMap::new(),
            ),
            "until-cancel",
        ),
        (
            "claude",
            profile(
                HarnessKind::ClaudeStdio,
                vec!["python3".into(), fake_claude.into()],
                BTreeMap::new(),
            ),
            "until-interrupt",
        ),
        (
            "codex",
            profile(
                HarnessKind::default(),
                vec![codex.to_string_lossy().into_owned(), "app-server".into()],
                BTreeMap::from([("CODEX_HOME".to_owned(), home.to_string_lossy().into_owned())]),
            ),
            "until-interrupt",
        ),
    ]
}

async fn client(hub: &Arc<Hub>) -> TestClient {
    connect(hub).await
}

async fn busy_session(c: &mut TestClient, busy: &str) -> (String, i64) {
    let s = c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    let first = c.send(method::SESSION_PROMPT, text_prompt(&id, busy, "p-busy", json!({}))).await;
    let sid = id.clone();
    c.wait_for(method::SESSION_UPDATE, move |p| {
        p["sessionId"] == sid.as_str() && p["update"]["sessionUpdate"] == "agent_message_chunk"
    })
    .await;
    (id, first)
}

#[tokio::test]
async fn a_prompt_sent_while_a_turn_runs_interrupts_it_by_default_for_every_harness() {
    for (name, profile, busy) in harnesses() {
        let hub = hub_with(profile, |_| {});
        let mut c = client(&hub).await;
        let (id, first) = busy_session(&mut c, busy).await;
        let began = Instant::now();
        let next =
            c.send(method::SESSION_PROMPT, text_prompt(&id, "hi", "p-next", json!({}))).await;
        let acc = c.wait_for(method::MUX_PROMPT_ACCEPTED, |p| p["promptId"] == "p-next").await;
        assert_eq!(acc["interrupt"], true, "{name}: accepted as an interrupt: {acc}");
        let (stopped, _) = c.response(first).await;
        let stopped = stopped.unwrap_or_else(|e| panic!("{name}: the busy turn failed: {e}"));
        assert_eq!(
            stopped["stopReason"], "cancelled",
            "{name}: the running turn stopped: {stopped}"
        );
        let (r, _) = c.response(next).await;
        let r = r.unwrap_or_else(|e| panic!("{name}: the new prompt failed: {e}"));
        assert_eq!(r["stopReason"], "end_turn", "{name}: {r}");
        assert!(
            began.elapsed() < PROMPT_STOP_BUDGET,
            "{name}: the new prompt waited {:?}: it queued behind the turn instead of stopping it",
            began.elapsed()
        );
        assert!(
            r["_meta"]["acpmux"].get("cancelForced").is_none(),
            "{name}: the agent took the stop"
        );
        let events = hub.events(&id, 0, 1000).unwrap();
        assert!(
            !events.iter().any(|e| e.kind == "queued" && e.msg["promptId"] == "p-next")
                || events.iter().any(|e| e.kind == "queued" && e.msg["interrupt"] == true),
            "{name}: recorded as an interrupt, not a plain queued prompt"
        );
    }
}

#[tokio::test]
async fn queue_true_waits_for_the_running_turn_for_every_harness() {
    for (name, profile, busy) in harnesses() {
        let hub = hub_with(profile, |_| {});
        let mut c = client(&hub).await;
        let (id, first) = busy_session(&mut c, busy).await;
        let next = c
            .send(method::SESSION_PROMPT, text_prompt(&id, "hi", "p-next", json!({"queue": true})))
            .await;
        let acc = c.wait_for(method::MUX_PROMPT_ACCEPTED, |p| p["promptId"] == "p-next").await;
        assert_eq!(acc["queued"], true, "{name}: {acc}");
        assert_ne!(acc["interrupt"], true, "{name}: {acc}");
        // The running turn is not stopped by the queued prompt: it still runs.
        assert!(hub.resolve(&id).unwrap().turn().is_some(), "{name}: the busy turn still runs");
        hub.cancel(&hub.resolve(&id).unwrap()).await.unwrap();
        assert_eq!(c.response(first).await.0.unwrap()["stopReason"], "cancelled", "{name}");
        assert_eq!(c.response(next).await.0.unwrap()["stopReason"], "end_turn", "{name}");
    }
}

#[tokio::test]
async fn the_busy_prompt_setting_queues_and_a_prompt_can_still_ask_to_interrupt() {
    let (_, profile, busy) = harnesses().remove(0);
    let hub = hub_with(profile, |cfg| cfg.busy_prompt = Some(acpmux::config::BusyPrompt::Queue));
    let mut c = client(&hub).await;
    let (id, first) = busy_session(&mut c, busy).await;
    let queued = c.send(method::SESSION_PROMPT, text_prompt(&id, "one", "p-q", json!({}))).await;
    let acc = c.wait_for(method::MUX_PROMPT_ACCEPTED, |p| p["promptId"] == "p-q").await;
    assert_eq!(acc["queued"], true, "{acc}");
    assert_ne!(acc["interrupt"], true, "{acc}");
    assert!(hub.resolve(&id).unwrap().turn().is_some(), "busyPrompt queue: the turn still runs");
    // `queue: false` on the prompt wins over the setting.
    let now = c
        .send(method::SESSION_PROMPT, text_prompt(&id, "two", "p-now", json!({"queue": false})))
        .await;
    let acc = c.wait_for(method::MUX_PROMPT_ACCEPTED, |p| p["promptId"] == "p-now").await;
    assert_eq!(acc["interrupt"], true, "{acc}");
    assert_eq!(c.response(first).await.0.unwrap()["stopReason"], "cancelled");
    assert_eq!(c.response(now).await.0.unwrap()["stopReason"], "end_turn");
    assert_eq!(c.response(queued).await.0.unwrap()["stopReason"], "end_turn");
    // The interrupt ran before the prompt that queued.
    let events = hub.events(&id, 0, 1000).unwrap();
    let order: Vec<&str> = events
        .iter()
        .filter(|e| e.kind == "user_message")
        .filter_map(|e| e.msg["promptId"].as_str())
        .collect();
    assert_eq!(order, ["p-busy", "p-now", "p-q"]);
}

/// Twenty prompts sent while one turn streams, each after the daemon took the one before
/// (as a composer sends): none waits behind a turn, none is lost, and the agent reads them
/// in the order they were sent.
#[tokio::test]
async fn a_burst_of_prompts_during_a_turn_never_queues_loses_or_reorders_one() {
    for (name, profile, busy) in harnesses() {
        let hub = hub_with(profile, |_| {});
        let mut c = client(&hub).await;
        let (id, first) = busy_session(&mut c, busy).await;
        let began = Instant::now();
        let mut sent = Vec::new();
        for k in 0..20 {
            let pid = format!("p-{k:02}");
            let rid = c
                .send(
                    method::SESSION_PROMPT,
                    text_prompt(&id, &format!("<m{k:02}>"), &pid, json!({})),
                )
                .await;
            let p2 = pid.clone();
            let acc = c
                .wait_for(method::MUX_PROMPT_ACCEPTED, move |p| p["promptId"] == p2.as_str())
                .await;
            assert_ne!(
                acc["queued"].as_bool() == Some(true) && acc["interrupt"] != true,
                true,
                "{name} {pid}: {acc}"
            );
            sent.push((pid, rid));
        }
        assert!(c.response(first).await.0.is_ok(), "{name}: busy turn answered");
        for (pid, rid) in &sent {
            let (r, _) = c.response(*rid).await;
            assert!(r.is_ok(), "{name} {pid}: every prompt is answered: {r:?}");
        }
        assert!(
            began.elapsed() < Duration::from_secs(15),
            "{name}: the burst took {:?}",
            began.elapsed()
        );
        // Every message reached the agent once, in send order: the prompts its turns ran.
        let events = hub.events(&id, 0, 5000).unwrap();
        // `turn_started` names what its turn sent: prompts it carried (overtaken before their
        // own turn), then its own.
        let started: Vec<String> = events
            .iter()
            .filter(|e| e.kind == "turn_started")
            .map(|e| {
                let carried = e.msg["carried"].as_str().unwrap_or_default();
                format!("{carried}{}", e.msg["prompt"].as_str().unwrap_or_default())
            })
            .collect();
        let seen: Vec<String> = started
            .iter()
            .skip(1)
            .flat_map(|t| {
                t.match_indices("<m").map(|(i, _)| t[i..i + 5].to_owned()).collect::<Vec<_>>()
            })
            .collect();
        let want: Vec<String> = (0..20).map(|k| format!("<m{k:02}")).collect();
        assert_eq!(seen, want, "{name}: the agent read every message once, in order");
        // The transcript shows every message too, in order.
        let shown: Vec<&str> = events
            .iter()
            .filter(|e| e.kind == "user_message")
            .filter_map(|e| e.msg["promptId"].as_str())
            .filter(|p| *p != "p-busy")
            .collect();
        let sent_ids: Vec<&str> = sent.iter().map(|(p, _)| p.as_str()).collect();
        assert_eq!(shown, sent_ids, "{name}: the transcript keeps send order");
    }
}
