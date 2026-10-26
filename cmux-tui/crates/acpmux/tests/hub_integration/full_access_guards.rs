//! A chat in Full access (a mode the shared rule `spec/full-access-modes.json` names, which cmux
//! set itself) answers what its harness still asks with the request's one-time allow, unasked:
//! Claude Code in `bypassPermissions` still raises its own guards ("Dangerous rm operation on
//! statically-unresolvable target", classifier_approvable false). Each one is logged as a
//! `permission_auto` record with `fullAccess` (the mode), which the transcript shows as one quiet
//! line. Asking modes still ask, deny-all and deny rules still deny, a question or a lasting-only
//! allow still goes to the person, and the mode is the current one: a chat that leaves Full
//! access asks again from its next request (`hub/permissions.rs` `full_access_allow`).
//!
//! Leo (2026-10-25), asked whether Full access should also approve the requests Claude Code still
//! raises in bypass: "i think it should... idk like if it is on bypass permissions, that's not
//! auto".

use super::*;

/// A Claude Code chat (its modes: default, acceptEdits, plan, bypassPermissions) in `mode`, set
/// by the person through acpmux as the mode menu does.
async fn chat_in(c: &mut TestClient, mode: &str) -> String {
    let s = c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    // Set even when the chat starts in it (the start level is Full access here), so the person's
    // pick is the last mode set.
    c.request(method::SESSION_SET_MODE, json!({"sessionId": id, "modeId": mode})).await.unwrap();
    let info = c.request("_acpmux/info", json!({"sessionId": id})).await.unwrap();
    assert_eq!(info["modes"]["currentModeId"], mode, "{info}");
    id
}

async fn claude_hub() -> (Arc<Hub>, TestClient) {
    hub_with(&[("FAKE_PICKER", "1"), ("FAKE_PICKER_MODES", "claude")]).await
}

/// A hub whose one harness is the stand-in with `env`, under the daemon default policy `ask` and
/// the start level Full access (a new chat starts in the harness's full-access mode, set by cmux).
async fn hub_with(env: &[(&str, &str)]) -> (Arc<Hub>, TestClient) {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let env: BTreeMap<&str, &str> = env.iter().copied().collect();
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", fake], "env": env}},
        "defaultHarness": "fake",
        "permissionPolicy": "ask",
        "defaultPermissionMode": "fullAccess",
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    hold_person_key(&hub);
    let (in_tx, in_rx) = mpsc::channel(64);
    let (out_tx, out_rx) = mpsc::channel(4096);
    tokio::spawn(serve_connection(hub.clone(), in_rx, out_tx));
    let mut client = TestClient { tx: in_tx, rx: out_rx, next: 0 };
    client.become_person().await;
    (hub, client)
}

fn guard(id: &str) -> Value {
    prompt(id, "guard: rm -rf \"$TARGET\"", None)
}

/// The `permission_auto` records of `id`.
fn autos(hub: &Arc<Hub>, id: &str) -> Vec<Value> {
    hub.events(id, 0, 10_000)
        .unwrap()
        .into_iter()
        .filter(|e| e.kind == "permission_auto")
        .map(|e| e.msg)
        .collect()
}

/// The turn `rid` asks the person: its request is pending, nothing answered it; the person's
/// cancel ends the turn. Returns the pending record.
async fn asks_the_person(c: &mut TestClient, hub: &Arc<Hub>, id: &str, rid: i64) -> Value {
    let pending = c.wait_for(method::MUX_PERMISSION_PENDING, |p| p["sessionId"] == json!(id)).await;
    assert!(
        autos(hub, id).iter().all(|a| a.get("fullAccess").is_none()),
        "answered without the person: {:?}",
        autos(hub, id)
    );
    c.request(
        method::MUX_PERMISSION_RESPOND,
        json!({"sessionId": id, "permissionId": pending["permissionId"]}),
    )
    .await
    .unwrap();
    assert!(c.response(rid).await.0.is_ok());
    pending
}

#[tokio::test]
async fn full_access_approves_a_harness_guard_once_and_logs_it() {
    let (hub, mut c) = claude_hub().await;
    let id = chat_in(&mut c, "bypassPermissions").await;
    // Nobody answers: the turn ends on its own.
    c.request(method::SESSION_PROMPT, guard(&id)).await.unwrap();
    let session = hub.resolve(&id).unwrap();
    // The one-time allow, never the lasting one listed first.
    assert_eq!(hub.session_summary(&session)["preview"], "chose once");
    let autos = autos(&hub, &id);
    assert_eq!(autos.len(), 1, "{autos:?}");
    assert_eq!(autos[0]["fullAccess"], "bypassPermissions");
    assert_eq!(autos[0]["optionId"], "once");
    assert_eq!(autos[0]["request"]["toolCall"]["title"], "rm -rf \"$TARGET\"");
    let kinds: Vec<String> =
        hub.events(&id, 0, 10_000).unwrap().into_iter().map(|e| e.kind).collect();
    assert!(!kinds.iter().any(|k| k == "permission_request"), "{kinds:?}");
    // A plain tool approval in bypass is no prompt either.
    c.request(method::SESSION_PROMPT, prompt(&id, "ask: ls", None)).await.unwrap();
    assert_eq!(hub.session_summary(&session)["preview"], "chose yes");
}

#[tokio::test]
async fn asking_modes_still_ask_for_the_same_guard() {
    let (hub, mut c) = claude_hub().await;
    for mode in ["default", "acceptEdits"] {
        let id = chat_in(&mut c, mode).await;
        let rid = c.send(method::SESSION_PROMPT, guard(&id)).await;
        asks_the_person(&mut c, &hub, &id, rid).await;
    }
}

#[tokio::test]
async fn deny_all_and_deny_rules_still_deny_in_full_access() {
    let (hub, mut c) = claude_hub().await;
    // A deny rule leaves the mode as it is: the chat is in Full access when it asks.
    let id = chat_in(&mut c, "bypassPermissions").await;
    c.request(method::MUX_SET_RULES, json!({"sessionId": id, "rules": {"autoDeny": ["rm"]}}))
        .await
        .unwrap();
    c.request(method::SESSION_PROMPT, guard(&id)).await.unwrap();
    let session = hub.resolve(&id).unwrap();
    assert_eq!(hub.session_summary(&session)["preview"], "chose no");
    assert_eq!(hub.session_summary(&session)["currentModeId"], "bypassPermissions");
    // Deny-all, the person's explicit choice, denies the guard too (it also moves the chat to its
    // asking mode, `policy_mode.rs`; a request on its way meanwhile is denied all the same).
    let id = chat_in(&mut c, "bypassPermissions").await;
    c.request(method::MUX_SET_POLICY, json!({"sessionId": id, "policy": "deny-all"}))
        .await
        .unwrap();
    c.request(method::SESSION_PROMPT, guard(&id)).await.unwrap();
    let session = hub.resolve(&id).unwrap();
    assert_eq!(hub.session_summary(&session)["preview"], "chose no");
    assert!(
        autos(&hub, &id).iter().all(|a| a.get("fullAccess").is_none()),
        "{:?}",
        autos(&hub, &id)
    );
}

#[tokio::test]
async fn a_chat_that_leaves_full_access_mid_turn_asks_from_its_next_request() {
    let (hub, mut c) = claude_hub().await;
    let id = chat_in(&mut c, "bypassPermissions").await;
    let fifo = std::env::temp_dir().join(format!("acpmux-full-access-gate-{}", std::process::id()));
    let _ = std::fs::remove_file(&fifo);
    assert!(std::process::Command::new("mkfifo").arg(&fifo).status().unwrap().success());
    let rid = c
        .send(method::SESSION_PROMPT, prompt(&id, &format!("gate-ask: {}", fifo.display()), None))
        .await;
    c.collect_until(|m, p| m == method::SESSION_UPDATE && p.to_string().contains("before-gate"))
        .await;
    // The person switches the running chat to an asking mode, then the harness asks.
    c.request(method::SESSION_SET_MODE, json!({"sessionId": id, "modeId": "default"}))
        .await
        .unwrap();
    let gate = fifo.clone();
    tokio::task::spawn_blocking(move || std::fs::write(gate, "go")).await.unwrap().unwrap();
    asks_the_person(&mut c, &hub, &id, rid).await;
    let _ = std::fs::remove_file(&fifo);
}

#[tokio::test]
async fn only_a_full_access_mode_cmux_set_approves() {
    let (hub, mut c) = claude_hub().await;
    // The harness leaves Full access on its own, then asks: the person answers.
    let id = chat_in(&mut c, "bypassPermissions").await;
    let rid = c.send(method::SESSION_PROMPT, prompt(&id, "drift-ask: default", None)).await;
    asks_the_person(&mut c, &hub, &id, rid).await;
    // The harness claims Full access on its own (cmux never set it), then asks: still the person.
    let id = chat_in(&mut c, "default").await;
    let rid =
        c.send(method::SESSION_PROMPT, prompt(&id, "drift-ask: bypassPermissions", None)).await;
    asks_the_person(&mut c, &hub, &id, rid).await;
}

#[tokio::test]
async fn questions_and_lasting_only_allows_still_ask_in_full_access() {
    let (hub, mut c) = claude_hub().await;
    let id = chat_in(&mut c, "bypassPermissions").await;
    // AskUserQuestion is a question for the person, not a permission.
    let rid = c.send(method::SESSION_PROMPT, prompt(&id, "question: Which one?", None)).await;
    asks_the_person(&mut c, &hub, &id, rid).await;
    // A question in a tool's own metadata (a Codex user-input request's shape after normalize).
    let rid = c.send(method::SESSION_PROMPT, prompt(&id, "meta-question: Go on?", None)).await;
    asks_the_person(&mut c, &hub, &id, rid).await;
    // Only an "always" allow (a lasting rule): Full access never writes one.
    let rid = c.send(method::SESSION_PROMPT, prompt(&id, "ask-always: deploy", None)).await;
    asks_the_person(&mut c, &hub, &id, rid).await;
}

#[tokio::test]
async fn another_familys_full_access_mode_approves_too() {
    // The stand-in's own `full-access` (the shared rule's "fullaccess" marker, as Codex's
    // `agent-full-access`), not Claude Code's bypassPermissions.
    let (hub, mut c) = hub_with(&[("FAKE_FULL_ACCESS", "1")]).await;
    let id = chat_in(&mut c, "full-access").await;
    c.request(method::SESSION_PROMPT, guard(&id)).await.unwrap();
    let session = hub.resolve(&id).unwrap();
    assert_eq!(hub.session_summary(&session)["preview"], "chose once");
    assert_eq!(autos(&hub, &id)[0]["fullAccess"], "full-access");
    // Its asking mode still asks.
    let id = chat_in(&mut c, "normal").await;
    let rid = c.send(method::SESSION_PROMPT, guard(&id)).await;
    asks_the_person(&mut c, &hub, &id, rid).await;
}

#[tokio::test]
async fn a_chat_that_starts_in_full_access_approves_without_a_pick() {
    let (hub, mut c) = claude_hub().await;
    let s = c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    let info = c.request("_acpmux/info", json!({"sessionId": id})).await.unwrap();
    assert_eq!(info["modes"]["currentModeId"], "bypassPermissions", "{info}");
    c.request(method::SESSION_PROMPT, guard(&id)).await.unwrap();
    let session = hub.resolve(&id).unwrap();
    assert_eq!(hub.session_summary(&session)["preview"], "chose once");
    assert_eq!(autos(&hub, &id)[0]["fullAccess"], "bypassPermissions");
}

#[tokio::test]
async fn a_fork_of_a_full_access_chat_approves_its_guards() {
    let (hub, mut c) = claude_hub().await;
    let id = chat_in(&mut c, "bypassPermissions").await;
    c.request(method::SESSION_PROMPT, prompt(&id, "hi", None)).await.unwrap();
    let f = c.request(method::SESSION_FORK, json!({"sessionId": id, "cwd": cwd()})).await.unwrap();
    let fid = f["sessionId"].as_str().unwrap().to_owned();
    c.request(method::SESSION_PROMPT, guard(&fid)).await.unwrap();
    let fork = hub.resolve(&fid).unwrap();
    assert_eq!(hub.session_summary(&fork)["currentModeId"], "bypassPermissions");
    assert_eq!(hub.session_summary(&fork)["preview"], "chose once");
    assert_eq!(autos(&hub, &fid)[0]["fullAccess"], "bypassPermissions");
}

/// A harness whose mode is only its `mode` config option: the person's pick through the option
/// approves; the harness moving the option away and back by itself does not.
#[tokio::test]
async fn full_access_picked_through_the_mode_option_and_its_drift() {
    let (hub, mut c) = hub_with(&[("FAKE_MODE_OPTION", "1"), ("FAKE_NO_MODES", "1")]).await;
    let s = c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    c.request(
        method::SESSION_SET_CONFIG_OPTION,
        json!({"sessionId": id, "configId": "mode", "value": "full-access"}),
    )
    .await
    .unwrap();
    c.request(method::SESSION_PROMPT, guard(&id)).await.unwrap();
    let session = hub.resolve(&id).unwrap();
    assert_eq!(hub.session_summary(&session)["preview"], "chose once");
    assert_eq!(autos(&hub, &id)[0]["fullAccess"], "full-access");
    c.request(method::SESSION_PROMPT, prompt(&id, "set-mode-option: normal", None)).await.unwrap();
    c.request(method::SESSION_PROMPT, prompt(&id, "set-mode-option: full-access", None))
        .await
        .unwrap();
    let rid = c.send(method::SESSION_PROMPT, guard(&id)).await;
    let pending = c.wait_for(method::MUX_PERMISSION_PENDING, |p| p["sessionId"] == json!(id)).await;
    assert_eq!(autos(&hub, &id).len(), 1, "{:?}", autos(&hub, &id));
    c.request(
        method::MUX_PERMISSION_RESPOND,
        json!({"sessionId": id, "permissionId": pending["permissionId"]}),
    )
    .await
    .unwrap();
    assert!(c.response(rid).await.0.is_ok());
}

/// A chat whose mode is only its `mode` option, picked Full access through it.
async fn option_chat(c: &mut TestClient) -> String {
    let s = c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    c.request(
        method::SESSION_SET_CONFIG_OPTION,
        json!({"sessionId": id, "configId": "mode", "value": "full-access"}),
    )
    .await
    .unwrap();
    id
}

async fn option_hub() -> (Arc<Hub>, TestClient) {
    hub_with(&[("FAKE_MODE_OPTION", "1"), ("FAKE_NO_MODES", "1")]).await
}

/// The harness leaves Full access through its option and comes straight back within one turn:
/// the mark went with the first write, so the guard asks.
#[tokio::test]
async fn a_mode_option_that_bounces_out_of_full_access_asks() {
    let (hub, mut c) = option_hub().await;
    let id = option_chat(&mut c).await;
    let rid = c.send(method::SESSION_PROMPT, prompt(&id, "bounce-guard: normal", None)).await;
    asks_the_person(&mut c, &hub, &id, rid).await;
}

/// A restarted agent whose mode is only its option gets Full access back by the replay, and with
/// it the approval, with no new pick.
#[tokio::test]
async fn a_restarted_mode_option_chat_keeps_approving() {
    let (hub, mut c) = option_hub().await;
    let id = option_chat(&mut c).await;
    let session = hub.resolve(&id).unwrap();
    hub.detach_child(&session).await;
    c.request(method::SESSION_PROMPT, guard(&id)).await.unwrap();
    assert_eq!(hub.session_summary(&session)["preview"], "chose once");
    assert_eq!(autos(&hub, &id)[0]["fullAccess"], "full-access");
}

#[tokio::test]
async fn a_fork_of_a_mode_option_chat_keeps_approving() {
    let (hub, mut c) = option_hub().await;
    let id = option_chat(&mut c).await;
    c.request(method::SESSION_PROMPT, prompt(&id, "hi", None)).await.unwrap();
    let f = c.request(method::SESSION_FORK, json!({"sessionId": id, "cwd": cwd()})).await.unwrap();
    let fid = f["sessionId"].as_str().unwrap().to_owned();
    c.request(method::SESSION_PROMPT, guard(&fid)).await.unwrap();
    let fork = hub.resolve(&fid).unwrap();
    assert_eq!(hub.session_summary(&fork)["preview"], "chose once");
    assert_eq!(autos(&hub, &fid)[0]["fullAccess"], "full-access");
}
