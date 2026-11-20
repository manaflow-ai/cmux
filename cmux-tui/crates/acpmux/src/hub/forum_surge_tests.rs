//! Forum work posts (#47894) meet the receive-side surge inbox (#48220) through
//! `inbox_forum.rs`: real `session/prompt` sends from two hosts' agent connections, one durable
//! forum post with both sources, one held row under the forum thread's topic, routed by the
//! recipient's grant to the thread's subscribed owner; protected classes never stored or held.
use super::*;
use crate::surge_triage as triage;
use crate::surge_triage::PassEnd;

const TOPIC: &str = "topic:ops/runner-capacity/ubuntu-24";

async fn hub_with_forum(root: &std::path::Path) -> (Arc<Hub>, Arc<Session>) {
    use crate::config::{Config, StoreMode};
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let cfg = json!({"harnesses": {"fake": {"argv": ["python3", fake]}}, "defaultHarness": "fake"});
    let mut cfg: Config = serde_json::from_value(cfg).unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    hub.open_forum(root).unwrap();
    let s = hub.new_session(new_req()).await.unwrap();
    // The model's answer for the one ordinary held item: its thread's owner.
    hub.set_surge_triager(Some(Arc::new(|_| Some("1 owner".to_owned()))));
    (hub, s)
}

fn new_req() -> NewRequest {
    NewRequest { cwd: Some(std::env::temp_dir()), ..NewRequest::default() }
}

/// One request over a connection of session `id`'s own agent (its caller token).
async fn rpc_as(hub: &Arc<Hub>, id: &str, method: &str, params: Value) -> Value {
    let (in_tx, in_rx) = tokio::sync::mpsc::channel(8);
    let (out_tx, mut out_rx) = tokio::sync::mpsc::channel(256);
    hub.scope.spawn_named(
        "test-conn",
        crate::server::serve_connection_with(
            hub.clone(),
            in_rx,
            out_tx,
            crate::server::Origin::Local,
        ),
    );
    let token = crate::hub::person::caller_token(id);
    let init = json!({"protocolVersion": 1,
        "_meta": {"acpmux": {"callerSession": {"sessionId": id, "token": token}}}});
    for (n, m, p) in [(1i64, "initialize", init), (2, method, params)] {
        in_tx.send(crate::rpc::Message::request(n, m, p).to_line()).await.unwrap();
        loop {
            let line = tokio::time::timeout(std::time::Duration::from_secs(20), out_rx.recv())
                .await
                .expect("an answer in 20 s")
                .expect("the connection is open");
            let v: Value = serde_json::from_str(&line).unwrap();
            if v.get("id") == Some(&json!(n)) {
                if n == 2 {
                    return v;
                }
                break;
            }
        }
    }
    unreachable!()
}

fn work(kind: crate::forum::work::Kind, thread: &str, key: &str, host: &str, body: &str) -> String {
    crate::forum::work::Input {
        channel: "ops/runner-capacity".into(),
        thread: thread.into(),
        kind,
        key: key.into(),
        body: body.into(),
        source: host.into(),
    }
    .wire()
    .unwrap()
}

async fn send(
    hub: &Arc<Hub>,
    from: &Session,
    to: &Session,
    id: &str,
    text: &str,
    class: &str,
) -> Value {
    let params = json!({"sessionId": to.id, "prompt": [{"type": "text", "text": text}],
        "_meta": {"acpmux": {"promptId": id, "class": class}}});
    let reply = rpc_as(hub, &from.id, "session/prompt", params).await;
    assert!(reply.get("error").is_none(), "{reply}");
    reply["result"].clone()
}

fn triaged_item(events: &[EventRecord], id: &str) -> Value {
    events
        .iter()
        .filter(|e| e.kind == triage::RECORD_KIND)
        .flat_map(|e| e.msg["items"].as_array().cloned().unwrap_or_default())
        .find(|i| i["promptId"] == id)
        .unwrap_or_else(|| panic!("no triage decision for {id}"))
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn forum_work_posts_reach_one_held_row_the_owner_and_keep_every_source() {
    use crate::forum::work::Kind;
    let root = tempfile::tempdir().unwrap();
    let (hub, s) = hub_with_forum(root.path()).await;
    let owner = hub.new_session(new_req()).await.unwrap();
    let (host_a, host_b) =
        (hub.new_session(new_req()).await.unwrap(), hub.new_session(new_req()).await.unwrap());

    // The owner subscribes itself to the forum thread's topic; the recipient grants it.
    let sub = rpc_as(
        &hub,
        &owner.id,
        crate::rpc::method::MUX_INBOX_SUBSCRIPTION_SET,
        json!({"sessionId": owner.id, "threadId": TOPIC}),
    )
    .await;
    assert_eq!(sub["result"]["subscribed"], true, "{sub}");
    let grant = rpc_as(
        &hub,
        &s.id,
        crate::rpc::method::MUX_INBOX_SUBSCRIPTION_GRANT,
        json!({"sessionId": s.id, "threadId": TOPIC, "ownerSessionId": owner.id}),
    )
    .await;
    assert_eq!(grant["result"]["granted"], true, "{grant}");

    // Two hosts report the same runner condition under one key: one post, two sources.
    let a_body =
        "WARN glaeda-gh on vm-a: 7 job(s) on runner label ubuntu-24 queued with no runner past 8m";
    let b_body =
        "WARN glaeda-gh on vm-b: 9 job(s) on runner label ubuntu-24 queued with no runner past 9m";
    let first = send(
        &hub,
        &host_a,
        &s,
        "wa",
        &work(Kind::Warn, "ubuntu-24", "queued/1", "vm-a", a_body),
        "fyi",
    )
    .await;
    let meta = &first["_meta"]["acpmux"];
    assert_eq!(meta["forum"]["stored"], true, "{first}");
    assert_eq!(meta["forum"]["duplicate"], false, "{first}");
    assert_eq!(meta["surgeHeld"], true, "{first}");
    assert_eq!(meta["threadId"], TOPIC, "the forum thread's topic is the surge holder's key");
    let post_id = meta["forum"]["postId"].as_str().unwrap().to_owned();
    let held_id = super::inbox::forum_work::held_id(&post_id);
    assert_eq!(meta["heldId"], held_id.as_str());

    let second = send(
        &hub,
        &host_b,
        &s,
        "wb",
        &work(Kind::Warn, "ubuntu-24", "queued/1", "vm-b", b_body),
        "fyi",
    )
    .await;
    let meta = &second["_meta"]["acpmux"];
    assert_eq!(meta["forum"]["duplicate"], true, "{second}");
    assert_eq!(meta["forum"]["postId"], post_id.as_str());
    assert!(
        meta.get("surgeHeld").is_none(),
        "a repeat adds a source, never a second row: {second}"
    );

    // A blocker post is held as a blocker: triage sends it to the chat, never to an owner.
    let blocker = send(
        &hub,
        &host_a,
        &s,
        "wblk",
        &work(Kind::Blocker, "macos-15", "down/1", "vm-a", "macos-15 pool has no runner at all"),
        "fyi",
    )
    .await;
    let blocker_held = blocker["_meta"]["acpmux"]["heldId"].as_str().unwrap().to_owned();

    // Protected classes keep their immediate paths: a question and a blocker sent as one are
    // neither stored as forum work nor held, even when they carry a work post's wire.
    for (id, class) in [("wq", "question"), ("wbk", "block")] {
        let reply = send(
            &hub,
            &host_a,
            &s,
            id,
            &work(Kind::Status, "ubuntu-24", id, "vm-a", "is the pool back?"),
            class,
        )
        .await;
        assert!(reply["_meta"]["acpmux"].get("forum").is_none(), "{class}: {reply}");
        assert!(reply["_meta"]["acpmux"].get("surgeHeld").is_none(), "{class}: {reply}");
    }
    let person = PromptOptions {
        human_authenticated: true,
        agent: Some("lane".into()),
        ..Default::default()
    };
    assert!(super::inbox::forum_work::protected(&person));
    let fire = PromptOptions {
        provenance: Some(crate::prompt_provenance::notice(
            &json!({"sender": "watcher", "severity": "fire"}),
            &s.id,
        )),
        ..Default::default()
    };
    assert!(super::inbox::forum_work::protected(&fire));

    // One chat row: two held originals (the runner post once, the blocker), not three.
    assert_eq!(hub.surge_snapshot(&s)["held"], 2, "{}", hub.surge_snapshot(&s));
    {
        let inbox = s.inbox();
        let held: Vec<_> = inbox.items.iter().filter(|i| i.surge_held).collect();
        assert_eq!(held.len(), 2);
        let runner = held.iter().find(|i| i.prompt_id == held_id).unwrap();
        assert_eq!(runner.thread, TOPIC);
        assert_eq!(runner.text, a_body, "the held original is the parsed body, not the wire");
        assert_eq!(runner.from_session.as_deref(), Some(host_a.id.as_str()), "sender provenance");
    }
    let events = hub.events(&s.id, 0, 100_000).unwrap();
    let record = events
        .iter()
        .find(|e| e.kind == "inbox" && e.msg["promptId"] == held_id.as_str())
        .expect("the held original is journaled");
    assert_eq!(record.msg["transportPromptId"], "wa");
    assert_eq!(record.msg["forum"]["postId"], post_id.as_str());
    assert!(record.msg.pointer("/_meta/provenance").is_some(), "{}", record.msg);

    // The forum's receipt is durable: a fresh open of its journal has both hosts' sources,
    // each with its own transport provenance.
    let reopened = crate::forum::Forum::open(root.path()).unwrap();
    let rows = reopened.work_threads(&s.id, Some("ops/runner-capacity"), Some("ubuntu-24"));
    let posts = rows["threads"][0]["posts"].as_array().unwrap();
    assert_eq!(posts.len(), 1, "{rows}");
    let sources = posts[0]["sources"].as_object().unwrap();
    assert_eq!(sources.keys().collect::<Vec<_>>(), ["vm-a", "vm-b"]);
    assert!(sources.values().all(|v| !v["transport"].is_null()), "{rows}");

    // Owner triage: the runner post goes to the granted owner, the blocker to the chat.
    assert_eq!(hub.surge_triage_pass(&s).await.unwrap(), PassEnd::Done);
    let events = hub.events(&s.id, 0, 100_000).unwrap();
    let runner = triaged_item(&events, &held_id);
    assert_eq!(runner["category"], "needs_its_owner", "{runner}");
    assert_eq!(runner["owner"], owner.id.as_str());
    assert_eq!(triaged_item(&events, &blocker_held)["category"], "needs_this_session");
    let to_owner: Vec<String> = hub
        .events(&owner.id, 0, 100_000)
        .unwrap()
        .iter()
        .filter(|e| e.kind == "queued" || e.kind == "user_message")
        .map(|e| e.msg.to_string())
        .filter(|m| m.contains("vm-a: 7 job(s)"))
        .collect();
    assert!(!to_owner.is_empty(), "the owner got the runner post in its digest");
    assert!(to_owner.iter().all(|m| !m.contains("macos-15 pool")), "the blocker stays the chat's");
}
