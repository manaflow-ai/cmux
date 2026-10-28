//! Moving a chat to another daemon (`_acpmux/transfer_*`, `acpmux.transfer.v1`). Two daemons in
//! one process stand for a sibling build or a remote machine; the test is the client that moves
//! the chat between them, as the app (or a Move to Cloud service) does:
//!
//! - source `transfer_begin` freezes the chat and describes its bundle; `transfer_read` pages it;
//! - target `transfer_receive`, `transfer_write` and `transfer_finish` rebuild it, its queue live;
//! - source `transfer_commit` retires it there (or `transfer_abort` gives it back).
//!
//! The chat arrives with its history, its queue (each queued prompt runs once, on the target)
//! and its draft; the source runs nothing once the move began.

use super::*;

/// The `text` of every record of `kind` in a session's log.
pub(super) async fn texts(c: &mut TestClient, id: &str, kind: &str) -> Vec<String> {
    let page = c
        .request(method::MUX_EVENTS, json!({"sessionId": id, "afterSeq": 0, "limit": 5000}))
        .await
        .unwrap();
    page["events"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|e| e["kind"] == kind)
        .filter_map(|e| e["msg"]["text"].as_str().map(str::to_owned))
        .collect()
}

/// Pages every file of the bundle `begin` describes from `src` into the target's `receive_id`.
pub(super) async fn copy_bundle(
    src: &mut TestClient,
    dst: &mut TestClient,
    begin: &Value,
    receive_id: &str,
) {
    let transfer_id = begin["transferId"].as_str().unwrap();
    for file in begin["files"].as_array().unwrap() {
        let path = file["path"].as_str().unwrap();
        let mut offset = 0u64;
        loop {
            let part = src
                .request(
                    "_acpmux/transfer_read",
                    json!({"transferId": transfer_id, "path": path, "offset": offset, "limit": 4096}),
                )
                .await
                .unwrap();
            let data = part["data"].as_str().unwrap();
            dst.request(
                "_acpmux/transfer_write",
                json!({"receiveId": receive_id, "path": path, "offset": offset, "data": data}),
            )
            .await
            .unwrap();
            offset = part["next"].as_u64().unwrap();
            if part["eof"] == true {
                break;
            }
        }
    }
}

/// A chat with a reply in its history, a draft, and a turn running with `queued` behind it.
async fn busy_chat(c: &mut TestClient, queued: &[(&str, &str)]) -> String {
    let s = c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    c.request(method::SESSION_PROMPT, prompt(&id, "p-hi", "hi")).await.unwrap();
    c.request(method::MUX_DRAFT_SET, json!({"sessionId": id, "text": "unsent words"}))
        .await
        .unwrap();
    c.send(method::SESSION_PROMPT, prompt(&id, "p-turn", "until-cancel")).await;
    c.wait_for(method::SESSION_UPDATE, |p| p["update"]["content"]["text"] == "running").await;
    for (prompt_id, text) in queued {
        c.send(method::SESSION_PROMPT, prompt(&id, prompt_id, text)).await;
        c.wait_for(method::MUX_PROMPT_ACCEPTED, |p| {
            p["promptId"] == *prompt_id && p["queued"] == true
        })
        .await;
    }
    id
}

fn prompt(id: &str, prompt_id: &str, text: &str) -> Value {
    json!({"sessionId": id, "prompt": [{"type": "text", "text": text}], "_meta": {"acpmux": {"promptId": prompt_id}}})
}

#[tokio::test]
async fn a_moved_chat_keeps_its_history_queue_and_draft_and_each_queued_prompt_runs_once_there() {
    let (_a, mut src) = setup(PermissionPolicy::ApproveAll).await;
    let (_b, mut dst) = setup(PermissionPolicy::ApproveAll).await;
    let id = busy_chat(&mut src, &[("p-a", "a"), ("p-b", "b")]).await;

    // The running turn stops; nothing queued starts here once the move began.
    let begin = src
        .request("_acpmux/transfer_begin", json!({"sessionId": id, "interrupt": true}))
        .await
        .unwrap();
    assert_eq!(begin["schema"], "acpmux.transfer.v1", "{begin}");
    assert_eq!(begin["sessionId"], id.as_str(), "{begin}");
    let received =
        dst.request("_acpmux/transfer_receive", json!({"manifest": begin})).await.unwrap();
    let receive_id = received["receiveId"].as_str().unwrap().to_owned();
    copy_bundle(&mut src, &mut dst, &begin, &receive_id).await;
    let moved =
        dst.request("_acpmux/transfer_finish", json!({"receiveId": receive_id})).await.unwrap();
    assert_eq!(moved["sessionId"], id.as_str(), "{moved}");
    let committed = src
        .request(
            "_acpmux/transfer_commit",
            json!({"sessionId": id, "transferId": begin["transferId"], "to": {"sessionId": id}}),
        )
        .await
        .unwrap();
    assert_eq!(committed["committed"], true, "{committed}");

    // The queue runs on the target, in order, each prompt once.
    let deadline = tokio::time::Instant::now() + Duration::from_secs(20);
    while !texts(&mut dst, &id, "user_message").await.contains(&"b".to_owned()) {
        assert!(tokio::time::Instant::now() < deadline, "the moved queue never ran");
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    tokio::time::sleep(Duration::from_millis(500)).await;
    let ran_there = texts(&mut dst, &id, "user_message").await;
    assert_eq!(ran_there, ["hi", "until-cancel", "a", "b"], "history, then the queue once");
    let ran_here = texts(&mut src, &id, "user_message").await;
    assert_eq!(ran_here, ["hi", "until-cancel"], "the source ran nothing after the move began");

    let draft = dst.request(method::MUX_DRAFT_GET, json!({"sessionId": id})).await.unwrap();
    assert_eq!(draft["draft"], "unsent words", "{draft}");
    let left = src.request(method::MUX_INFO, json!({"sessionId": id})).await.unwrap();
    assert_eq!(left["status"], "closed", "{left}");
    let draft = src.request(method::MUX_DRAFT_GET, json!({"sessionId": id})).await.unwrap();
    assert!(draft["draft"].is_null(), "the source keeps no draft: {draft}");
}

#[tokio::test]
async fn a_chat_being_moved_takes_no_prompt_and_an_aborted_move_gives_it_back() {
    let (_a, mut src) = setup(PermissionPolicy::ApproveAll).await;
    let id = busy_chat(&mut src, &[("p-a", "a")]).await;

    // A running turn is not stopped unless the mover asks.
    let busy = src.request("_acpmux/transfer_begin", json!({"sessionId": id})).await;
    assert!(busy.as_ref().is_err_and(|e| e.contains("transfer.busy")), "{busy:?}");

    let begin = src
        .request("_acpmux/transfer_begin", json!({"sessionId": id, "interrupt": true}))
        .await
        .unwrap();
    let refused = src.request(method::SESSION_PROMPT, prompt(&id, "p-late", "late")).await;
    assert!(refused.as_ref().is_err_and(|e| e.contains("transfer.moving")), "{refused:?}");
    // Its queue and draft move as they are.
    let edit = json!({"sessionId": id, "promptId": "p-a", "op": "update", "text": "changed"});
    let edited = src.request("_acpmux/queue_edit", edit).await;
    assert!(edited.as_ref().is_err_and(|e| e.contains("transfer.moving")), "{edited:?}");
    let draft = src.request(method::MUX_DRAFT_SET, json!({"sessionId": id, "text": "later"})).await;
    assert!(draft.as_ref().is_err_and(|e| e.contains("transfer.moving")), "{draft:?}");
    tokio::time::sleep(Duration::from_millis(500)).await;
    assert_eq!(texts(&mut src, &id, "user_message").await, ["hi", "until-cancel"]);

    src.request(
        "_acpmux/transfer_abort",
        json!({"sessionId": id, "transferId": begin["transferId"]}),
    )
    .await
    .unwrap();
    // Given back: its queue runs, and it takes prompts again.
    src.wait_for(method::SESSION_UPDATE, |p| p["update"]["content"]["text"] == "echo: a").await;
    src.request(method::SESSION_PROMPT, prompt(&id, "p-again", "again")).await.unwrap();
    assert_eq!(texts(&mut src, &id, "user_message").await, ["hi", "until-cancel", "a", "again"]);
}

/// Records of `kind` in a session's log, their `msg`.
async fn records(c: &mut TestClient, id: &str, kind: &str) -> Vec<Value> {
    let page = c
        .request(method::MUX_EVENTS, json!({"sessionId": id, "afterSeq": 0, "kinds": [kind]}))
        .await
        .unwrap();
    page["events"].as_array().unwrap().iter().map(|e| e["msg"].clone()).collect()
}

/// `hub` on a unix socket of its own, as a sibling build's daemon listens; its path.
async fn listen(hub: &Arc<Hub>) -> std::path::PathBuf {
    static NEXT: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
    let n = NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    // `/tmp`, not the temp dir: a worker's can be too long for a socket path.
    let path = std::path::PathBuf::from("/tmp")
        .join(format!("acpmux-move-{}-{n}.sock", std::process::id()));
    let listener = acpmux::server::bind_unix(&path).await.unwrap();
    tokio::spawn(acpmux::server::serve_unix(hub.clone(), listener));
    path
}

/// Waits until `id`'s status on `c` is `status`.
async fn wait_status(c: &mut TestClient, id: &str, status: &str) {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(20);
    loop {
        let info = c.request(method::MUX_INFO, json!({"sessionId": id})).await.unwrap();
        if info["status"] == status {
            return;
        }
        assert!(tokio::time::Instant::now() < deadline, "never {status}: {info}");
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
}

#[tokio::test]
async fn a_move_whose_client_goes_away_before_the_bundle_is_read_gives_the_chat_back_on_its_own() {
    let (a, mut src) = setup(PermissionPolicy::ApproveAll).await;
    let id = busy_chat(&mut src, &[("p-a", "a")]).await;
    let begin = src
        .request("_acpmux/transfer_begin", json!({"sessionId": id, "interrupt": true}))
        .await
        .unwrap();
    // One small page, then the client is gone.
    let path = begin["files"][0]["path"].clone();
    let read = json!({"transferId": begin["transferId"], "path": path, "offset": 0, "limit": 1});
    src.request("_acpmux/transfer_read", read).await.unwrap();
    // The client is gone from here on: a short lease ends the move soon. Set
    // only now, so a slow request of the client before this point (2 s and
    // more while this binary runs its tests at once, cx-nx5mb) is not taken
    // for a client that went away.
    a.set_transfer_lease(Duration::from_secs(2));

    // No target can have the chat: it comes back here, runs its queue and takes prompts.
    src.wait_for(method::SESSION_UPDATE, |p| p["update"]["content"]["text"] == "echo: a").await;
    src.request(method::SESSION_PROMPT, prompt(&id, "p-again", "again")).await.unwrap();
    let aborted = records(&mut src, &id, "transfer_aborted").await;
    assert_eq!(aborted.len(), 1, "{aborted:?}");
    assert_eq!(aborted[0]["reason"], "stalled", "{aborted:?}");
}

#[tokio::test]
async fn a_move_whose_client_goes_away_after_the_target_took_the_chat_commits_on_its_own() {
    let (a, mut src) = setup(PermissionPolicy::ApproveAll).await;
    let (b, mut dst) = setup(PermissionPolicy::ApproveAll).await;
    let socket = listen(&b).await;
    let id = busy_chat(&mut src, &[("p-a", "a")]).await;
    let begin = src
        .request(
            "_acpmux/transfer_begin",
            json!({"sessionId": id, "interrupt": true, "to": {"socket": socket}}),
        )
        .await
        .unwrap();
    let received =
        dst.request("_acpmux/transfer_receive", json!({"manifest": begin})).await.unwrap();
    let receive_id = received["receiveId"].as_str().unwrap().to_owned();
    copy_bundle(&mut src, &mut dst, &begin, &receive_id).await;
    dst.request("_acpmux/transfer_finish", json!({"receiveId": receive_id})).await.unwrap();
    // The client is gone before its commit: the source asks the target, which has the chat.
    // The short lease only from here on, as in the test above (cx-nx5mb).
    a.set_transfer_lease(Duration::from_secs(2));

    wait_status(&mut src, &id, "closed").await;
    let deadline = tokio::time::Instant::now() + Duration::from_secs(20);
    while !texts(&mut dst, &id, "user_message").await.contains(&"a".to_owned()) {
        assert!(tokio::time::Instant::now() < deadline, "the moved queue never ran");
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    assert_eq!(texts(&mut src, &id, "user_message").await, ["hi", "until-cancel"]);
    let committed = records(&mut src, &id, "transferred").await;
    assert_eq!(committed.len(), 1, "{committed:?}");
}

#[tokio::test]
async fn a_move_whose_client_goes_away_before_the_target_finished_is_dropped_there_and_given_back()
{
    let (a, mut src) = setup(PermissionPolicy::ApproveAll).await;
    let (b, mut dst) = setup(PermissionPolicy::ApproveAll).await;
    let socket = listen(&b).await;
    let id = busy_chat(&mut src, &[("p-a", "a")]).await;
    let begin = src
        .request(
            "_acpmux/transfer_begin",
            json!({"sessionId": id, "interrupt": true, "to": {"socket": socket}}),
        )
        .await
        .unwrap();
    let received =
        dst.request("_acpmux/transfer_receive", json!({"manifest": begin})).await.unwrap();
    let receive_id = received["receiveId"].as_str().unwrap().to_owned();
    // Every page is copied, but the client is gone before its finish.
    copy_bundle(&mut src, &mut dst, &begin, &receive_id).await;
    // The short lease only from here on, as in the test above (cx-nx5mb).
    a.set_transfer_lease(Duration::from_secs(2));

    // The target drops the receive and the chat comes back here, its queue running.
    src.wait_for(method::SESSION_UPDATE, |p| p["update"]["content"]["text"] == "echo: a").await;
    let late = dst.request("_acpmux/transfer_finish", json!({"receiveId": receive_id})).await;
    assert!(late.as_ref().is_err_and(|e| e.contains("transfer.unknown")), "{late:?}");
    // A client that kept the bundle cannot start the move over there either.
    let again = dst.request("_acpmux/transfer_receive", json!({"manifest": begin})).await;
    assert!(again.as_ref().is_err_and(|e| e.contains("transfer.forgotten")), "{again:?}");
    let there = dst.request(method::MUX_INFO, json!({"sessionId": id})).await;
    assert!(there.is_err(), "the target has no copy: {there:?}");
}

/// A daemon whose store is on disk at `dir`, with `cmux-harness` among its agents: an import of a
/// durable session writes its recovery marker beside the sessions (`hub/transfer.rs`).
fn disk_hub(dir: &std::path::Path) -> Arc<Hub> {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let profile = HarnessProfile {
        kind: Default::default(),
        argv: vec!["python3".into(), fake.into()],
        env: BTreeMap::new(),
        description: None,
        fallback: None,
        family: None,
        models: vec![],
        model: None,
        effort: None,
        policy: None,
    };
    let harnesses = BTreeMap::from([("cmux-harness".to_owned(), profile)]);
    let mut cfg = Config { harnesses, ..Default::default() };
    cfg.store.mode = StoreMode::Local;
    let store = acpmux::store::open(&cfg.store, dir).unwrap();
    Hub::new(cfg, store)
}

/// A bundle of a cmux-harness chat whose agent session is `agent`, its log `events`, and no
/// durable journal in its manifest.
fn harness_bundle(dir: &std::path::Path, agent: &str, events: &str) -> std::path::PathBuf {
    let id = uuid::Uuid::now_v7().to_string();
    let bundle = dir.join(&id);
    std::fs::create_dir_all(bundle.join("events")).unwrap();
    let meta = json!({
        "schema": "acpmux.session.v1", "id": id, "name": "durable", "harness": "cmux-harness",
        "cwd": cwd(), "agentSessionId": agent, "status": "idle", "createdAt": 1, "updatedAt": 1,
    });
    std::fs::write(bundle.join("session.json"), meta.to_string()).unwrap();
    std::fs::write(bundle.join("events").join("000001.ndjson"), events).unwrap();
    let manifest = json!({"schema": "acpmux.bundle.v1", "id": id, "harness": null});
    std::fs::write(bundle.join("manifest.json"), manifest.to_string()).unwrap();
    bundle
}

#[tokio::test]
async fn a_failed_durable_import_leaves_no_recovery_marker_so_a_retry_runs_on_the_same_daemon() {
    let dir = std::env::temp_dir().join(format!("acpmux-test-{}", uuid::Uuid::now_v7()));
    let hub = disk_hub(&dir.join("daemon"));
    let marker = dir.join("daemon/sessions/.agent-0001.durable-transfer-state");
    // Its log does not parse; then its durable journal is missing.
    for (events, failure) in [("not a record\n", "import events"), ("", "import durable journal")] {
        let bundle = harness_bundle(&dir.join("bundles"), "agent-0001", events);
        for attempt in ["first", "retry"] {
            let failed = hub.import(&bundle, None).await.err().map(|e| e.message);
            assert!(
                failed.as_deref().is_some_and(|m| m.starts_with(failure)),
                "{attempt}: {failed:?}"
            );
            assert!(!marker.exists(), "{attempt} {failure} left its recovery marker");
        }
    }
    let _ = std::fs::remove_dir_all(&dir);
}
