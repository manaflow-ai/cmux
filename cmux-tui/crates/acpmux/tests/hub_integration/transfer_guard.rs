//! The guarded receive (`_acpmux/transfer_receive {manifest, guard: {control, roots}}`): a chat
//! moved in from a daemon this one does not trust as itself (Move to Cloud). The guard is kept
//! with the receive, so `transfer_write` and `transfer_finish` cannot drop it:
//!
//! - its queue runs under the guard's control (`web` also gates on folder trust), also after a
//!   restart;
//! - its folder must be under a root, its policy, rules and mode must ask, and it starts without
//!   a preset, a session env, recorded store roots or cmux's MCP servers;
//! - only the bundle's own files and its agent's file for its exact session id come in, and no
//!   file here is overwritten;
//! - it never replaces a moved-away copy here whose folder is outside the roots.

use super::transfer::{copy_bundle, texts};
use super::*;
use acpmux::server::{Origin, serve_connection_with};
use base64::Engine;
use base64::engine::general_purpose::STANDARD as BASE64;
use std::path::{Path, PathBuf};

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");

/// A folder of one test, removed when dropped.
struct Scratch(PathBuf);

impl Scratch {
    /// Under the home directory: a guard's roots must be.
    fn home(tag: &str) -> Self {
        Self::under(&dirs::home_dir().expect("a home directory"), &format!("acpmux-guard-{tag}"))
    }

    /// Outside the home directory.
    fn temp(tag: &str) -> Self {
        Self::under(&std::env::temp_dir(), &format!("acpmux-guard-{tag}"))
    }

    fn under(parent: &Path, name: &str) -> Self {
        let dir = parent.join(format!("{name}-{}", uuid::Uuid::now_v7()));
        std::fs::create_dir_all(&dir).unwrap();
        Scratch(std::fs::canonicalize(&dir).unwrap())
    }

    fn path(&self) -> &Path {
        &self.0
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// Two fake profiles and a Claude-named one, asking mode `normal` for the fake family, and a
/// Codex-family one (a family the Web never drives). `extra` adds or replaces config keys.
fn config(policy: &str, extra: Value) -> Config {
    let env = json!({"FAKE_SESSION_PREFIX": "fake-session-"});
    let mut v = json!({
        "harnesses": {
            "fake": {"argv": ["python3", FAKE], "env": env},
            "claude": {"argv": ["python3", FAKE], "env": env},
            "fcodex": {"argv": ["python3", FAKE], "env": env, "family": "codex"},
            "plain": {"argv": ["python3", FAKE], "env": env, "family": "plain"},
        },
        "defaultHarness": "fake",
        "permissionPolicy": policy,
        "webAskingModes": {"fake": ["normal"]},
    });
    for (k, x) in extra.as_object().cloned().unwrap_or_default() {
        v[k] = x;
    }
    serde_json::from_value(v).unwrap()
}

/// A daemon on `cfg`, its log in memory or under `store`, and a client that is the person.
async fn daemon(mut cfg: Config, store: Option<&Path>) -> (Arc<Hub>, TestClient) {
    cfg.store.mode = if store.is_some() { StoreMode::Local } else { StoreMode::Memory };
    // The queue path before the inbox (`hub/inbox.rs`), which these tests cover.
    cfg.agent_inbox = Some(false);
    let dir = store.unwrap_or(Path::new("/nonexistent"));
    let hub = Hub::new(cfg.clone(), acpmux::store::open(&cfg.store, dir).unwrap());
    let client = connect(&hub).await;
    (hub, client)
}

fn guard(control: &str, roots: &[&Path]) -> Value {
    json!({"control": control, "roots": roots})
}

fn ask(id: &str, prompt_id: &str, text: &str) -> Value {
    json!({"sessionId": id, "prompt": [{"type": "text", "text": text}], "_meta": {"acpmux": {"promptId": prompt_id}}})
}

/// A hand-made `session.json` for a chat in `cwd`, with `extra` fields.
fn meta(cwd: &Path, extra: Value) -> Value {
    let id = uuid::Uuid::now_v7().to_string();
    let name = format!("guard-{}", &id[id.len() - 12..]);
    let mut m = json!({
        "schema": "acpmux.session.v1", "id": id, "name": name, "harness": "fake",
        "cwd": cwd, "status": "idle", "createdAt": 0, "updatedAt": 0,
    });
    for (k, x) in extra.as_object().cloned().unwrap_or_default() {
        m[k] = x;
    }
    m
}

/// The manifest of a bundle made of `meta` as `session.json` and `files`, and its files.
fn bundle_manifest(meta: &Value, files: &[(&str, &[u8])]) -> (Value, Vec<(String, Vec<u8>)>) {
    let mut all = vec![("session.json".to_owned(), serde_json::to_vec_pretty(meta).unwrap())];
    all.extend(files.iter().map(|(p, d)| (p.to_string(), d.to_vec())));
    let listed: Vec<Value> = all.iter().map(|(p, d)| json!({"path": p, "size": d.len()})).collect();
    let manifest = json!({
        "schema": "acpmux.transfer.v1",
        "transferId": uuid::Uuid::now_v7().to_string(),
        "sessionId": meta["id"],
        "session": {"harness": meta["harness"]},
        "files": listed,
    });
    (manifest, all)
}

/// Receives the bundle of `meta` and `files` under `guard` and writes all of it.
async fn receive(
    c: &mut TestClient,
    guard: Value,
    meta: &Value,
    files: &[(&str, &[u8])],
) -> Result<String, String> {
    let (manifest, all) = bundle_manifest(meta, files);
    let r = c
        .request("_acpmux/transfer_receive", json!({"manifest": manifest, "guard": guard}))
        .await?;
    assert_eq!(r["guarded"], true, "a guarded receive says so: {r}");
    let receive_id = r["receiveId"].as_str().unwrap().to_owned();
    for (path, data) in &all {
        let page = json!({"receiveId": receive_id, "path": path, "offset": 0, "data": BASE64.encode(data)});
        c.request("_acpmux/transfer_write", page).await?;
    }
    Ok(receive_id)
}

async fn finish(c: &mut TestClient, receive_id: &str, extra: Value) -> Result<Value, String> {
    let mut params = json!({"receiveId": receive_id});
    for (k, x) in extra.as_object().cloned().unwrap_or_default() {
        params[k] = x;
    }
    c.request("_acpmux/transfer_finish", params).await
}

/// The `msg` of every record of `kind` in a session's log.
async fn records(c: &mut TestClient, id: &str, kind: &str) -> Vec<Value> {
    let page = c
        .request(method::MUX_EVENTS, json!({"sessionId": id, "afterSeq": 0, "limit": 5000}))
        .await
        .unwrap();
    page["events"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|e| e["kind"] == kind)
        .map(|e| e["msg"].clone())
        .collect()
}

/// Waits for a record of `kind` that `pred` takes.
async fn wait_record(
    c: &mut TestClient,
    id: &str,
    kind: &str,
    pred: impl Fn(&Value) -> bool,
) -> Value {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(20);
    loop {
        if let Some(m) = records(c, id, kind).await.into_iter().find(|m| pred(m)) {
            return m;
        }
        assert!(tokio::time::Instant::now() < deadline, "no {kind} record came");
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
}

/// A chat in `cwd` whose last turn failed: `p-a` and `p-b` wait behind it, held.
async fn held_chat(c: &mut TestClient, cwd: &Path) -> String {
    held_chat_with(c, cwd, json!({})).await
}

/// `held_chat`, created with `_meta.acpmux` fields `acpmux` (a harness, a policy).
async fn held_chat_with(c: &mut TestClient, cwd: &Path, acpmux: Value) -> String {
    let new = json!({"cwd": cwd, "mcpServers": [], "_meta": {"acpmux": acpmux}});
    let s = c.request(method::SESSION_NEW, new).await.unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    c.request(method::SESSION_PROMPT, ask(&id, "p-hi", "hi")).await.unwrap();
    c.send(method::SESSION_PROMPT, ask(&id, "p-slow", "slow")).await;
    c.wait_for(method::SESSION_UPDATE, |p| p["update"]["content"]["text"] == "tick0 ").await;
    for (prompt_id, text) in [("p-f", "fail-streamed: boom"), ("p-a", "a"), ("p-b", "b")] {
        c.send(method::SESSION_PROMPT, ask(&id, prompt_id, text)).await;
        c.wait_for(method::MUX_PROMPT_ACCEPTED, |p| {
            p["promptId"] == prompt_id && p["queued"] == true
        })
        .await;
    }
    wait_record(c, &id, "queue_paused", |m| m["held"].as_array().is_some_and(|h| h.len() == 2))
        .await;
    id
}

/// Moves chat `id` from `src` to `dst` (under `guard` when given) and commits it.
async fn move_chat(
    src: &mut TestClient,
    dst: &mut TestClient,
    id: &str,
    guard: Option<Value>,
    extra: Value,
) -> Result<Value, String> {
    let begin = src.request("_acpmux/transfer_begin", json!({"sessionId": id})).await.unwrap();
    let mut params = json!({"manifest": begin});
    if let Some(g) = guard {
        params["guard"] = g;
    }
    let received = dst.request("_acpmux/transfer_receive", params).await?;
    let receive_id = received["receiveId"].as_str().unwrap().to_owned();
    copy_bundle(src, dst, &begin, &receive_id).await;
    let moved = match finish(dst, &receive_id, extra).await {
        Ok(moved) => moved,
        Err(e) => {
            let abort = json!({"sessionId": id, "transferId": begin["transferId"]});
            src.request("_acpmux/transfer_abort", abort).await.unwrap();
            return Err(e);
        }
    };
    let commit = json!({"sessionId": id, "transferId": begin["transferId"]});
    src.request("_acpmux/transfer_commit", commit).await.unwrap();
    Ok(moved)
}

#[tokio::test]
async fn a_guarded_move_queues_under_the_guards_control_also_after_a_restart() {
    let root = Scratch::home("queue");
    let store = Scratch::temp("queue-store");
    let (_a, mut src) = daemon(config("approve-all", json!({})), None).await;
    let (b, mut dst) = daemon(config("approve-all", json!({})), Some(store.path())).await;
    let id = held_chat(&mut src, root.path()).await;

    let moved = move_chat(&mut src, &mut dst, &id, Some(guard("web", &[root.path()])), json!({}))
        .await
        .unwrap();
    assert_eq!(moved["policy"], "ask", "a guarded chat with no policy asks: {moved}");
    for q in records(&mut dst, &id, "queued").await {
        assert_eq!(q["control"], "web", "{q}");
        assert_eq!(q["trustGate"], true, "a web guard gates on folder trust: {q}");
    }
    let guarded = records(&mut dst, &id, "transfer_guarded").await;
    assert_eq!(guarded.len(), 1, "{guarded:?}");
    assert_eq!(guarded[0]["control"], "web");
    assert_eq!(guarded[0]["roots"], json!([root.path()]));

    // The person here lets it approve everything: a held prompt sent by the Web may not run.
    dst.request(method::MUX_SET_POLICY, json!({"sessionId": id, "policy": "approve-all"}))
        .await
        .unwrap();
    let send_now = |p: &str| json!({"sessionId": id, "promptId": p, "op": "send_now"});
    dst.request("_acpmux/queue_edit", send_now("p-a")).await.unwrap();
    let refused = wait_record(&mut dst, &id, "prompt_refused", |m| m["promptId"] == "p-a").await;
    assert_eq!(refused["data"]["reason"], "remote.policy_not_asking", "{refused}");
    assert!(!texts(&mut dst, &id, "user_message").await.contains(&"a".to_owned()));

    // A restart rebuilds the queue from the log: still the Web's.
    b.shutdown_all().await;
    drop(dst);
    drop(b);
    let (b, mut dst) = daemon(config("approve-all", json!({})), Some(store.path())).await;
    b.resume_queues();
    dst.request("_acpmux/queue_edit", send_now("p-b")).await.unwrap();
    let refused = wait_record(&mut dst, &id, "prompt_refused", |m| m["promptId"] == "p-b").await;
    assert_eq!(refused["data"]["reason"], "remote.policy_not_asking", "{refused}");
    assert!(!texts(&mut dst, &id, "user_message").await.contains(&"b".to_owned()));
    b.shutdown_all().await;
}

#[tokio::test]
async fn an_unguarded_move_keeps_the_control_each_prompt_was_queued_with() {
    let root = Scratch::home("unguarded");
    let (_a, mut src) = daemon(config("approve-all", json!({})), None).await;
    let (_b, mut dst) = daemon(config("approve-all", json!({})), None).await;
    let id = held_chat(&mut src, root.path()).await;
    move_chat(&mut src, &mut dst, &id, None, json!({})).await.unwrap();
    assert!(records(&mut dst, &id, "transfer_guarded").await.is_empty());
    dst.request(method::MUX_SET_POLICY, json!({"sessionId": id, "policy": "approve-all"}))
        .await
        .unwrap();
    let send_now = json!({"sessionId": id, "promptId": "p-a", "op": "send_now"});
    dst.request("_acpmux/queue_edit", send_now).await.unwrap();
    let deadline = tokio::time::Instant::now() + Duration::from_secs(20);
    while !texts(&mut dst, &id, "user_message").await.contains(&"a".to_owned()) {
        assert!(tokio::time::Instant::now() < deadline, "the held prompt never ran");
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    assert!(records(&mut dst, &id, "prompt_refused").await.is_empty());
}

#[tokio::test]
async fn a_guarded_finish_refuses_a_folder_outside_the_roots_and_the_source_stays_frozen() {
    let root = Scratch::home("cwd");
    let outside = Scratch::temp("cwd-outside");
    let (_a, mut src) = daemon(config("approve-all", json!({})), None).await;
    let (_b, mut dst) = daemon(config("approve-all", json!({})), None).await;
    let s = src
        .request(method::SESSION_NEW, json!({"cwd": outside.path(), "mcpServers": []}))
        .await
        .unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    src.request(method::SESSION_PROMPT, ask(&id, "p-hi", "hi")).await.unwrap();

    let begin = src.request("_acpmux/transfer_begin", json!({"sessionId": id})).await.unwrap();
    let received = dst
        .request(
            "_acpmux/transfer_receive",
            json!({"manifest": begin, "guard": guard("peer", &[root.path()])}),
        )
        .await
        .unwrap();
    assert_eq!(received["guarded"], true, "{received}");
    let receive_id = received["receiveId"].as_str().unwrap().to_owned();
    copy_bundle(&mut src, &mut dst, &begin, &receive_id).await;

    // Its own folder is outside the roots; so is a missing one, a relative one, and a link out.
    let missing = root.path().join("missing");
    let mut tries = vec![json!({}), json!({"cwd": missing}), json!({"cwd": "relative/dir"})];
    #[cfg(unix)]
    {
        let link = root.path().join("link");
        std::os::unix::fs::symlink(outside.path(), &link).unwrap();
        tries.push(json!({"cwd": link}));
    }
    for extra in tries {
        let r = finish(&mut dst, &receive_id, extra.clone()).await;
        assert!(r.as_ref().is_err_and(|e| e.contains("transfer.cwd")), "{extra}: {r:?}");
    }
    let here = dst.request(method::MUX_INFO, json!({"sessionId": id})).await;
    assert!(here.is_err(), "a refused finish imports nothing: {here:?}");

    // The source still holds the chat, frozen, until the mover aborts.
    let late = src.request(method::SESSION_PROMPT, ask(&id, "p-late", "late")).await;
    assert!(late.as_ref().is_err_and(|e| e.contains("transfer.moving")), "{late:?}");
    let abort = json!({"sessionId": id, "transferId": begin["transferId"]});
    src.request("_acpmux/transfer_abort", abort).await.unwrap();
    src.request(method::SESSION_PROMPT, ask(&id, "p-again", "again")).await.unwrap();
}

#[tokio::test]
async fn a_web_guarded_chat_asks_and_rules_or_policies_that_approve_are_refused() {
    let root = Scratch::home("policy");
    let (_b, mut dst) = daemon(config("approve-all", json!({})), None).await;
    let g = || guard("web", &[root.path()]);
    let normal = json!({"currentModeId": "normal", "availableModes": []});

    let m = meta(root.path(), json!({"modes": normal}));
    let rid = receive(&mut dst, g(), &m, &[]).await.unwrap();
    let s = finish(&mut dst, &rid, json!({})).await.unwrap();
    assert_eq!(s["policy"], "ask", "no policy is ask, not this daemon's approve-all: {s}");

    let m = meta(root.path(), json!({"permissionPolicy": "deny-all", "modes": normal}));
    let rid = receive(&mut dst, g(), &m, &[]).await.unwrap();
    assert_eq!(finish(&mut dst, &rid, json!({})).await.unwrap()["policy"], "deny-all");

    for extra in [
        // Its owner's (an approve-all with no source asks here, `hub/policy_source.rs`).
        json!({"permissionPolicy": "approve-all", "policySource": "set"}),
        json!({"permissionPolicy": "approve-edits"}),
        json!({"permissionRules": {"autoApprove": ["Bash"]}}),
        json!({"permissionRules": {"default": "approve"}}),
    ] {
        let m = meta(root.path(), extra.clone());
        let rid = receive(&mut dst, g(), &m, &[]).await.unwrap();
        let r = finish(&mut dst, &rid, json!({})).await;
        assert!(r.as_ref().is_err_and(|e| e.contains("transfer.policy")), "{extra}: {r:?}");
        // Toward the person's own machine (peer), the chat keeps its policy and rules.
        let m = meta(root.path(), extra.clone());
        let rid = receive(&mut dst, guard("peer", &[root.path()]), &m, &[]).await.unwrap();
        let s = finish(&mut dst, &rid, json!({})).await.unwrap();
        if let Some(policy) = extra.get("permissionPolicy") {
            assert_eq!(&s["policy"], policy, "{s}");
        }
        assert_eq!(s["rules"], extra.get("permissionRules").is_some(), "{s}");
    }
}

/// A chat moved in with an approve-all an older daemon saved with no source (the approve-all
/// vmHost gave, or one that could be), or with vmHost's, asks (`hub/policy_source.rs`); one whose
/// source says its owner set it keeps its approve-all.
#[tokio::test]
async fn a_moved_in_approve_all_with_no_owner_source_asks() {
    let root = Scratch::home("vmhost-grant");
    let (_b, mut dst) = daemon(config("ask", json!({})), None).await;
    for (extra, policy) in [
        (json!({"remoteOrigin": true}), "ask"),
        (json!({"remoteOrigin": false}), "ask"),
        (json!({"remoteOrigin": true, "policySource": "vmHost"}), "ask"),
        (json!({"remoteOrigin": true, "policySource": "set"}), "approve-all"),
    ] {
        let mut m = meta(root.path(), extra.clone());
        m["permissionPolicy"] = json!("approve-all");
        let rid = receive(&mut dst, guard("peer", &[root.path()]), &m, &[]).await.unwrap();
        let s = finish(&mut dst, &rid, json!({})).await.unwrap();
        assert_eq!(s["policy"], policy, "{extra}: {s}");
    }
}

#[tokio::test]
async fn a_guarded_chat_takes_its_family_from_here_and_a_web_one_must_ask() {
    let root = Scratch::home("mode");
    let (_b, mut dst) = daemon(config("ask", json!({})), None).await;
    let modes = |current: &str| json!({"currentModeId": current, "availableModes": []});

    // `default` asks for Claude, but this chat runs the fake profile: its family is fake here.
    for extra in [
        json!({"family": "claude", "modes": modes("default")}),
        json!({"modes": modes("strict")}),
        json!({"modes": modes("normal"), "configOptions": [{"id": "mode", "currentValue": "strict"}]}),
        json!({"modes": modes("normal"), "configOptions": [{"id": "sandbox", "currentValue": "off"}]}),
    ] {
        let m = meta(root.path(), extra.clone());
        let rid = receive(&mut dst, guard("web", &[root.path()]), &m, &[]).await.unwrap();
        let r = finish(&mut dst, &rid, json!({})).await;
        assert!(r.as_ref().is_err_and(|e| e.contains("transfer.mode")), "{extra}: {r:?}");
        // A peer guard has no mode rule: the chat moves in its mode, its family still from here.
        let m = meta(root.path(), extra.clone());
        let rid = receive(&mut dst, guard("peer", &[root.path()]), &m, &[]).await.unwrap();
        let s = finish(&mut dst, &rid, json!({})).await.unwrap();
        assert_eq!(s["family"], "fake", "{extra}: {s}");
    }
    let m = meta(root.path(), json!({"family": "claude", "modes": modes("normal")}));
    let rid = receive(&mut dst, guard("web", &[root.path()]), &m, &[]).await.unwrap();
    let s = finish(&mut dst, &rid, json!({})).await.unwrap();
    assert_eq!(s["family"], "fake", "{s}");
    // A Claude chat's speed and effort options never decide what runs without asking: a chat
    // in an asking mode that has them comes back (Bring Back Local refused every Claude chat
    // as `transfer.mode` for its Ultracode and Fast mode options).
    let options = json!([
        {"id": "model", "currentValue": "default"},
        {"id": "mode", "currentValue": "normal"},
        {"id": "effort", "currentValue": "high"},
        {"id": "ultracode", "currentValue": "on"},
        {"id": "fast-mode", "currentValue": "on"},
    ]);
    let m = meta(root.path(), json!({"modes": modes("normal"), "configOptions": options}));
    let rid = receive(&mut dst, guard("web", &[root.path()]), &m, &[]).await.unwrap();
    let s = finish(&mut dst, &rid, json!({})).await;
    assert!(s.is_ok(), "a chat's speed and effort options were refused: {s:?}");

    // Under the Web a chat with no recorded mode is refused when its family has asking modes
    // (dispatch would let it through on its policy alone), and taken when its family has none.
    let m = meta(root.path(), json!({}));
    let rid = receive(&mut dst, guard("web", &[root.path()]), &m, &[]).await.unwrap();
    let r = finish(&mut dst, &rid, json!({})).await;
    assert!(r.as_ref().is_err_and(|e| e.contains("transfer.mode")), "{r:?}");
    let m = meta(root.path(), json!({"harness": "plain"}));
    let rid = receive(&mut dst, guard("web", &[root.path()]), &m, &[]).await.unwrap();
    let s = finish(&mut dst, &rid, json!({})).await.unwrap();
    assert_eq!(s["family"], "plain", "{s}");

    // A family the Web never drives is refused for a web guard at once.
    let m = meta(root.path(), json!({"harness": "fcodex"}));
    let r = receive(&mut dst, guard("web", &[root.path()]), &m, &[]).await;
    assert!(r.as_ref().is_err_and(|e| e.contains("transfer.family")), "{r:?}");
}

#[tokio::test]
async fn a_guarded_chat_starts_without_its_preset_session_env_store_roots_or_cmux_tools() {
    let root = Scratch::home("env");
    let presets =
        json!({"presets": {"p1": {"harness": "fake", "env": {"GUARD_PRESET_KEY": "set"}}}});
    let (hub, mut dst) = daemon(config("ask", presets), None).await;
    let m = meta(
        root.path(),
        json!({
            "preset": "p1",
            "sessionEnv": {"CMUX_WORKSPACE_ID": "ws-guard"},
            "harnessRoots": [{"harness": "fake", "path": root.path()}],
            "harnessArgv": ["python3", "elsewhere.py"],
            "tags": {"k": {"value": "v"}},
            "modelRequest": "undeclared-model",
        }),
    );
    let id = m["id"].as_str().unwrap().to_owned();
    let rid = receive(&mut dst, guard("peer", &[root.path()]), &m, &[]).await.unwrap();
    finish(&mut dst, &rid, json!({})).await.unwrap();

    for (text, reply) in [
        ("env: GUARD_PRESET_KEY", "GUARD_PRESET_KEY="),
        ("env: CMUX_WORKSPACE_ID", "CMUX_WORKSPACE_ID="),
        ("mcp", "[]"),
    ] {
        let p = json!({"sessionId": id, "prompt": [{"type": "text", "text": text}]});
        dst.request(method::SESSION_PROMPT, p).await.unwrap();
        let preview = hub.session_summary(&hub.resolve(&id).unwrap())["preview"].clone();
        assert_eq!(preview, reply, "{text}");
    }
    let meta = hub.resolve(&id).unwrap().meta();
    assert!(meta.remote_origin, "a guarded chat is a remote chain");
    assert_eq!(meta.preset, None);
    assert!(meta.session_env.is_empty(), "{:?}", meta.session_env);
    assert!(meta.harness_roots.is_empty(), "{:?}", meta.harness_roots);
    assert!(meta.harness_argv.is_empty(), "{:?}", meta.harness_argv);
    assert!(meta.tags.is_empty(), "{:?}", meta.tags);
    assert_eq!(meta.model_request, None);
}

/// Claude Code's project directory name for `cwd` (`native.rs`).
fn claude_project_dir(cwd: &Path) -> String {
    cwd.to_string_lossy().chars().map(|c| if c.is_ascii_alphanumeric() { c } else { '-' }).collect()
}

#[tokio::test]
async fn a_guarded_finish_restores_only_the_chats_own_agent_file_without_its_mode() {
    let root = Scratch::home("native");
    let home = dirs::home_dir().unwrap();
    let project = home.join(".claude/projects").join(claude_project_dir(root.path()));
    // Removed however the test ends: the project folder is this test's alone.
    let _project = Scratch(project.clone());
    let (_b, mut dst) = daemon(config("ask", json!({})), None).await;
    let g = || guard("peer", &[root.path()]);
    let claude = |sid: &str| json!({"harness": "claude", "agentSessionId": sid});
    let transcript = concat!(
        r#"{"type":"user","permissionMode":"bypassPermissions","message":{"content":"hi"}}"#,
        "\n",
        r#"{"type":"permission-mode","permissionMode":"acceptEdits"}"#,
        "\n",
        r#"{"type":"assistant","message":{"content":"done"}}"#,
        "\n",
    );

    let sid = uuid::Uuid::now_v7().to_string();
    let file = format!("native/claude-project/.claude/projects/-elsewhere/{sid}.jsonl");
    let m = meta(root.path(), claude(&sid));
    let rid = receive(&mut dst, g(), &m, &[(file.as_str(), transcript.as_bytes())]).await.unwrap();
    let s = finish(&mut dst, &rid, json!({})).await.unwrap();
    assert_eq!(s["agentSessionId"], sid.as_str(), "its own restored file resumes: {s}");
    let restored = std::fs::read_to_string(project.join(format!("{sid}.jsonl"))).unwrap();
    assert!(!restored.contains("permissionMode"), "a resumed chat takes no mode: {restored}");
    assert!(restored.contains("\"hi\"") && restored.contains("\"done\""), "{restored}");
    assert_eq!(restored.lines().count(), 2, "{restored}");

    // An agent session that is here already is not this chat's to resume: refused, and the
    // file here is kept.
    let sid = uuid::Uuid::now_v7().to_string();
    std::fs::create_dir_all(&project).unwrap();
    std::fs::write(project.join(format!("{sid}.jsonl")), "mine\n").unwrap();
    let file = format!("native/claude-project/.claude/projects/-elsewhere/{sid}.jsonl");
    let m = meta(root.path(), claude(&sid));
    let id = m["id"].as_str().unwrap().to_owned();
    let rid = receive(&mut dst, g(), &m, &[(file.as_str(), transcript.as_bytes())]).await.unwrap();
    let r = finish(&mut dst, &rid, json!({})).await;
    assert!(r.as_ref().is_err_and(|e| e.contains("transfer.session")), "{r:?}");
    assert_eq!(std::fs::read_to_string(project.join(format!("{sid}.jsonl"))).unwrap(), "mine\n");
    assert!(dst.request(method::MUX_INFO, json!({"sessionId": id})).await.is_err());

    // With no agent file in the bundle, the chat starts its agent fresh: an agent session here
    // with that id (the one above) is never resumed.
    let m = meta(root.path(), claude(&sid));
    let rid = receive(&mut dst, g(), &m, &[]).await.unwrap();
    let s = finish(&mut dst, &rid, json!({})).await.unwrap();
    assert!(s["agentSessionId"].is_null(), "{s}");

    // A file that cannot be written fails the finish, imports nothing and leaves no part file.
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let sid = uuid::Uuid::now_v7().to_string();
        let file = format!("native/claude-project/.claude/projects/-elsewhere/{sid}.jsonl");
        let m = meta(root.path(), claude(&sid));
        let id = m["id"].as_str().unwrap().to_owned();
        let rid =
            receive(&mut dst, g(), &m, &[(file.as_str(), transcript.as_bytes())]).await.unwrap();
        let before: Vec<_> = std::fs::read_dir(&project).unwrap().flatten().collect();
        std::fs::set_permissions(&project, std::fs::Permissions::from_mode(0o500)).unwrap();
        let r = finish(&mut dst, &rid, json!({})).await;
        std::fs::set_permissions(&project, std::fs::Permissions::from_mode(0o700)).unwrap();
        assert!(r.as_ref().is_err_and(|e| e.contains("transfer.native")), "{r:?}");
        assert!(dst.request(method::MUX_INFO, json!({"sessionId": id})).await.is_err());
        let after: Vec<_> = std::fs::read_dir(&project).unwrap().flatten().collect();
        assert_eq!(after.len(), before.len(), "no part file is left");
    }

    // An agent session id that is not one, or a file of another agent, is refused at finish.
    let sid = uuid::Uuid::now_v7().to_string();
    for (agent_session, file) in [
        (".".to_owned(), "native/claude-project/.claude/projects/x/..jsonl".to_owned()),
        (
            sid.clone(),
            format!("native/codex-rollout/.codex/sessions/2026/10/11/rollout-1-{sid}.jsonl"),
        ),
        (sid.clone(), format!("native/claude-project/.claude/projects/x/other-{sid}.jsonl")),
    ] {
        let m = meta(root.path(), claude(&agent_session));
        let rid = receive(&mut dst, g(), &m, &[(file.as_str(), &b"{}\n"[..])]).await.unwrap();
        let r = finish(&mut dst, &rid, json!({})).await;
        assert!(r.as_ref().is_err_and(|e| e.contains("transfer.native")), "{file}: {r:?}");
    }

    // A file that is not the bundle's or an agent store's is refused at receive, as is a ninth
    // agent file.
    let m = meta(root.path(), claude(&sid));
    for file in ["native/claude-project/.claude/settings.json", "notes.txt", "events/x.json"] {
        let r = receive(&mut dst, g(), &m, &[(file, &b"{}"[..])]).await;
        assert!(r.as_ref().is_err_and(|e| e.contains("transfer.path")), "{file}: {r:?}");
    }
    let many: Vec<String> = (0..9)
        .map(|n| format!("native/claude-project/.claude/projects/p{n}/{sid}.jsonl"))
        .collect();
    let files: Vec<(&str, &[u8])> = many.iter().map(|f| (f.as_str(), &b"{}\n"[..])).collect();
    let r = receive(&mut dst, g(), &m, &files).await;
    assert!(r.as_ref().is_err_and(|e| e.contains("transfer.native")), "{r:?}");
}

#[tokio::test]
async fn a_chat_with_no_asking_mode_moves_under_peer_control_but_not_under_web() {
    let root = Scratch::home("codex");
    let (_a, mut src) = daemon(config("ask", json!({})), None).await;
    let (_b, mut dst) = daemon(config("ask", json!({})), None).await;
    // A Codex-family chat (no mode of it asks; the fake's `normal` is not listed for codex)
    // that approves everything.
    let acpmux = json!({"harness": "fcodex", "policy": "approve-all"});
    let id = held_chat_with(&mut src, root.path(), acpmux.clone()).await;

    // Toward the Web's control it is refused before a page is sent.
    let begin = src.request("_acpmux/transfer_begin", json!({"sessionId": id})).await.unwrap();
    let params = json!({"manifest": begin, "guard": guard("web", &[root.path()])});
    let r = dst.request("_acpmux/transfer_receive", params).await;
    assert!(r.as_ref().is_err_and(|e| e.contains("transfer.family")), "{r:?}");
    let abort = json!({"sessionId": id, "transferId": begin["transferId"]});
    src.request("_acpmux/transfer_abort", abort).await.unwrap();

    // Toward the person's own machine (peer) it moves as it is, and its queue runs as peer.
    let moved = move_chat(&mut src, &mut dst, &id, Some(guard("peer", &[root.path()])), json!({}))
        .await
        .unwrap();
    assert_eq!(moved["policy"], "approve-all", "{moved}");
    assert_eq!(moved["family"], "codex", "{moved}");
    for q in records(&mut dst, &id, "queued").await {
        assert_eq!(q["control"], "peer", "{q}");
        assert_ne!(q["trustGate"], true, "{q}");
    }
    // Its agent may not start under peer control (its family has no asking mode, 307889914b9):
    // each held prompt ends refused and names why, never left waiting with no word.
    for prompt_id in ["p-a", "p-b"] {
        let refused =
            wait_record(&mut dst, &id, "prompt_refused", |m| m["promptId"] == prompt_id).await;
        assert_eq!(refused["data"]["reason"], "remote.mode_not_asking", "{refused}");
        assert!(refused["error"].as_str().is_some_and(|e| e.contains("asking mode")), "{refused}");
    }
    assert!(!texts(&mut dst, &id, "user_message").await.contains(&"a".to_owned()));

    // The same kind of chat in a family the Web drives is refused for its mode and policy.
    let modes = json!({"currentModeId": "strict", "availableModes": []});
    for (extra, error) in [
        (json!({"modes": modes}), "transfer.mode"),
        (json!({"permissionPolicy": "approve-all", "policySource": "set"}), "transfer.policy"),
    ] {
        let m = meta(root.path(), extra.clone());
        let rid = receive(&mut dst, guard("web", &[root.path()]), &m, &[]).await.unwrap();
        let r = finish(&mut dst, &rid, json!({})).await;
        assert!(r.as_ref().is_err_and(|e| e.contains(error)), "{extra}: {r:?}");
    }
}

/// Receives an unguarded hand-made bundle and finishes it.
async fn receive_unguarded(c: &mut TestClient, meta: &Value) -> Value {
    let (manifest, all) = bundle_manifest(meta, &[]);
    let r = c.request("_acpmux/transfer_receive", json!({"manifest": manifest})).await.unwrap();
    let rid = r["receiveId"].as_str().unwrap().to_owned();
    for (path, data) in &all {
        let page =
            json!({"receiveId": rid, "path": path, "offset": 0, "data": BASE64.encode(data)});
        c.request("_acpmux/transfer_write", page).await.unwrap();
    }
    finish(c, &rid, json!({})).await.unwrap()
}

#[tokio::test]
async fn a_guarded_move_back_replaces_its_own_moved_away_agent_file() {
    let root = Scratch::home("back");
    let home = dirs::home_dir().unwrap();
    let project = home.join(".claude/projects").join(claude_project_dir(root.path()));
    let _project = Scratch(project.clone());
    let (_a, mut a) = daemon(config("ask", json!({})), None).await;
    let (_b, mut b) = daemon(config("ask", json!({})), None).await;
    let sid = uuid::Uuid::now_v7().to_string();

    // A Claude chat here moves away; its transcript stays here.
    let m = meta(root.path(), json!({"harness": "claude", "agentSessionId": sid}));
    let id = m["id"].as_str().unwrap().to_owned();
    receive_unguarded(&mut a, &m).await;
    move_chat(&mut a, &mut b, &id, None, json!({})).await.unwrap();
    std::fs::create_dir_all(&project).unwrap();
    std::fs::write(project.join(format!("{sid}.jsonl")), "before the move\n").unwrap();

    // It comes back guarded with its newer transcript: the moved-away copy's file gives way.
    let newer = "{\"type\":\"assistant\",\"message\":{\"content\":\"later\"}}\n";
    let file = format!("native/claude-project/.claude/projects/-elsewhere/{sid}.jsonl");
    let rid =
        receive(&mut a, guard("peer", &[root.path()]), &m, &[(file.as_str(), newer.as_bytes())])
            .await
            .unwrap();
    let s = finish(&mut a, &rid, json!({})).await.unwrap();
    assert_eq!(s["agentSessionId"], sid.as_str(), "{s}");
    assert_ne!(s["status"], "closed", "{s}");
    assert_eq!(std::fs::read_to_string(project.join(format!("{sid}.jsonl"))).unwrap(), newer);
    let parts: Vec<_> = std::fs::read_dir(&project).unwrap().flatten().collect();
    assert_eq!(parts.len(), 1, "no part file is left: {parts:?}");
}

/// A client of `hub` from `origin`, without the person's handshake.
fn remote_client(hub: &Arc<Hub>, origin: Origin) -> TestClient {
    let (in_tx, in_rx) = mpsc::channel(64);
    let (out_tx, out_rx) = mpsc::channel(4096);
    tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, origin));
    TestClient { tx: in_tx, rx: out_rx, next: 0 }
}

#[tokio::test]
async fn a_guard_is_checked_kept_by_the_receive_and_taken_only_on_the_local_socket() {
    let root = Scratch::home("roots");
    let dotdir = Scratch::under(&dirs::home_dir().unwrap(), ".acpmux-guard-dot");
    let outside = Scratch::temp("roots-outside");
    let home = std::fs::canonicalize(dirs::home_dir().unwrap()).unwrap();
    let (hub, mut dst) = daemon(config("ask", json!({})), None).await;
    let m = meta(root.path(), json!({}));
    let (manifest, _) = bundle_manifest(&m, &[]);

    for bad in [
        json!({"control": "web", "roots": [home]}),
        json!({"control": "web", "roots": [dotdir.path()]}),
        json!({"control": "web", "roots": [outside.path()]}),
        json!({"control": "web", "roots": [root.path().join("missing")]}),
        json!({"control": "web", "roots": ["relative"]}),
        json!({"control": "web", "roots": []}),
        json!({"control": "local", "roots": [root.path()]}),
        json!({"roots": [root.path()]}),
        json!({"control": "web", "roots": [root.path()], "env": {"A": "b"}}),
        json!("web"),
        Value::Null,
    ] {
        let r = dst
            .request(
                "_acpmux/transfer_receive",
                json!({"manifest": manifest, "guard": bad.clone()}),
            )
            .await;
        assert!(r.as_ref().is_err_and(|e| e.contains("transfer.guard")), "{bad}: {r:?}");
    }

    // The receive keeps its guard: a later call without one, or with a null one, is still held
    // to it.
    let m = meta(outside.path(), json!({}));
    let rid = receive(&mut dst, guard("peer", &[root.path()]), &m, &[]).await.unwrap();
    let r = finish(&mut dst, &rid, json!({"guard": null})).await;
    assert!(r.as_ref().is_err_and(|e| e.contains("transfer.cwd")), "{r:?}");
    let s = finish(&mut dst, &rid, json!({"cwd": root.path()})).await.unwrap();
    assert_eq!(s["cwd"], json!(root.path()), "{s}");
    let from = "x".repeat(5000);
    let m = meta(root.path(), json!({}));
    let rid = receive(&mut dst, guard("peer", &[root.path()]), &m, &[]).await.unwrap();
    let r = finish(&mut dst, &rid, json!({"from": from})).await;
    assert!(r.as_ref().is_err_and(|e| e.contains("transfer.from")), "{r:?}");

    // The bundle's session.json must be the chat the receive was checked for.
    let m = meta(root.path(), json!({}));
    let (mut manifest, all) = bundle_manifest(&m, &[]);
    manifest["sessionId"] = json!(uuid::Uuid::now_v7().to_string());
    let params = json!({"manifest": manifest, "guard": guard("peer", &[root.path()])});
    let r = dst.request("_acpmux/transfer_receive", params).await.unwrap();
    let rid = r["receiveId"].as_str().unwrap().to_owned();
    for (path, data) in &all {
        let page =
            json!({"receiveId": rid, "path": path, "offset": 0, "data": BASE64.encode(data)});
        dst.request("_acpmux/transfer_write", page).await.unwrap();
    }
    let r = finish(&mut dst, &rid, json!({})).await;
    assert!(r.as_ref().is_err_and(|e| e.contains("transfer.schema")), "{r:?}");

    // Only the local socket moves a chat, guarded or not.
    for origin in [Origin::Web, Origin::LocalApp, Origin::Peer] {
        let mut c = remote_client(&hub, origin);
        let m = meta(root.path(), json!({}));
        let (manifest, _) = bundle_manifest(&m, &[]);
        let params = json!({"manifest": manifest, "guard": guard("web", &[root.path()])});
        let r = c.request("_acpmux/transfer_receive", params).await;
        assert!(r.as_ref().is_err_and(|e| e.contains("Method not found")), "{origin:?}: {r:?}");
    }
}

#[tokio::test]
async fn a_guarded_move_never_replaces_a_moved_away_copy_outside_the_roots() {
    let root = Scratch::home("replace");
    let outside = Scratch::temp("replace-outside");
    let (_a, mut a) = daemon(config("ask", json!({})), None).await;
    let (_b, mut b) = daemon(config("ask", json!({})), None).await;
    let g = || Some(guard("peer", &[root.path()]));
    let chat = |cwd: &Path| json!({"cwd": cwd, "mcpServers": []});

    // Moved away from a folder outside the roots: coming back guarded, it does not replace it.
    let s = a.request(method::SESSION_NEW, chat(outside.path())).await.unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    a.request(method::SESSION_PROMPT, ask(&id, "p-hi", "hi")).await.unwrap();
    move_chat(&mut a, &mut b, &id, None, json!({})).await.unwrap();
    let back = move_chat(&mut b, &mut a, &id, g(), json!({"cwd": root.path()})).await;
    assert!(back.as_ref().is_err_and(|e| e.contains("transfer.exists")), "{back:?}");
    let left = a.request(method::MUX_INFO, json!({"sessionId": id})).await.unwrap();
    assert_eq!(left["status"], "closed", "{left}");

    // Moved away from a folder under a root: it comes back in its place.
    let s = a.request(method::SESSION_NEW, chat(root.path())).await.unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    a.request(method::SESSION_PROMPT, ask(&id, "p-hi", "hi")).await.unwrap();
    move_chat(&mut a, &mut b, &id, None, json!({})).await.unwrap();
    let back = move_chat(&mut b, &mut a, &id, g(), json!({})).await.unwrap();
    assert_eq!(back["sessionId"], id.as_str(), "{back}");
    assert_ne!(back["status"], "closed", "{back}");
    let returned = a.request(method::MUX_INFO, json!({"sessionId": id})).await.unwrap();
    assert_eq!(
        returned["transferBlocked"], false,
        "returning import clears revocation: {returned}"
    );
}

/// A moved-in chat cannot say an agent here sent its prompts: a guarded move drops the
/// provenance (`_meta.provenance`, cx-55d27) from the queue and the transcript it brings, as
/// only this daemon's unix socket may set it.
#[tokio::test]
async fn a_guarded_move_drops_the_bundles_prompt_provenance() {
    let root = Scratch::home("provenance");
    let (_a, mut src) = daemon(config("approve-all", json!({})), None).await;
    let (_b, mut dst) = daemon(config("approve-all", json!({})), None).await;
    let from = json!({"kind": "agent_message", "from": "acp:sender-1", "to": "acp:receiver-1",
        "msgId": "m-1", "threadId": "t-1"});
    let sent = |id: &str, prompt_id: &str, text: &str| {
        let mut p = ask(id, prompt_id, text);
        p["_meta"]["acpmux"]["provenance"] = from.clone();
        p
    };
    let new = json!({"cwd": root.path(), "mcpServers": [], "_meta": {"acpmux": {}}});
    let s = src.request(method::SESSION_NEW, new).await.unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    src.request(method::SESSION_PROMPT, sent(&id, "p-hi", "hi")).await.unwrap();
    src.send(method::SESSION_PROMPT, ask(&id, "p-slow", "slow")).await;
    src.wait_for(method::SESSION_UPDATE, |p| p["update"]["content"]["text"] == "tick0 ").await;
    src.send(method::SESSION_PROMPT, ask(&id, "p-f", "fail-streamed: boom")).await;
    src.wait_for(method::MUX_PROMPT_ACCEPTED, |p| p["promptId"] == "p-f" && p["queued"] == true)
        .await;
    src.send(method::SESSION_PROMPT, sent(&id, "p-a", "a")).await;
    src.wait_for(method::MUX_PROMPT_ACCEPTED, |p| p["promptId"] == "p-a" && p["queued"] == true)
        .await;
    wait_record(&mut src, &id, "queue_paused", |m| {
        m["held"].as_array().is_some_and(|h| h.len() == 1)
    })
    .await;
    let carried = |r: &Value| r.pointer("/_meta/provenance").is_some();
    assert!(records(&mut src, &id, "queued").await.iter().any(carried), "the source queue has it");

    move_chat(&mut src, &mut dst, &id, Some(guard("web", &[root.path()])), json!({}))
        .await
        .unwrap();
    for kind in ["queued", "user_message"] {
        let recs = records(&mut dst, &id, kind).await;
        assert!(!recs.is_empty(), "no {kind} record came over");
        assert!(!recs.iter().any(carried), "a moved {kind} record kept its provenance: {recs:?}");
    }
}
