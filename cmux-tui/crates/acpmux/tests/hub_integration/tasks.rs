//! A task (`hub/tasks.rs`): one chat gives a session on this daemon a brief with
//! `_acpmux/task_new`, the lane ends it in one call with a typed result (`_acpmux/report`
//! `done|blocked|failed`), and the result comes back to the giver once, as the lane's card.
//! Leo, 2026-10-24: "shouldn't you be able to tell more metadata regarding... when things are
//! completed, when things are not completed?"

use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::Message;
use acpmux::server::{Origin, serve_connection_with};
use serde_json::{Value, json};
use std::path::Path;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");

fn hub() -> Arc<Hub> {
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", FAKE], "family": "codex"}},
        "defaultHarness": "fake",
        "permissionPolicy": "approve-all"
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

struct Client(mpsc::Sender<String>, mpsc::Receiver<String>, i64);

impl Client {
    fn open(hub: &Arc<Hub>) -> Self {
        Self::from(hub, Origin::Local)
    }

    fn from(hub: &Arc<Hub>, origin: Origin) -> Self {
        let (in_tx, in_rx) = mpsc::channel(64);
        let (out_tx, out_rx) = mpsc::channel(4096);
        tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, origin));
        Self(in_tx, out_rx, 0)
    }

    /// A connection that proved it runs inside session `id` (`hub/person.rs` (a)): the agent
    /// there running `acpmux task …`.
    async fn in_session(hub: &Arc<Hub>, id: &str) -> Self {
        let mut c = Self::open(hub);
        let token = acpmux::hub::person::caller_token(id);
        let caller = json!({"callerSession": {"sessionId": id, "token": token}});
        c.call("initialize", json!({"protocolVersion": 1, "_meta": {"acpmux": caller}})).await;
        c
    }

    /// The reply to `method` (an error is returned, not asserted).
    async fn reply(&mut self, method: &str, params: Value) -> Value {
        self.2 += 1;
        let id = self.2;
        self.0.send(Message::request(id, method, params).to_line()).await.unwrap();
        loop {
            let line = tokio::time::timeout(Duration::from_secs(30), self.1.recv())
                .await
                .expect("timed out")
                .expect("connection closed");
            let value: Value = serde_json::from_str(&line).unwrap();
            if value.get("id") == Some(&json!(id)) {
                return value;
            }
        }
    }

    async fn call(&mut self, method: &str, params: Value) -> Value {
        let value = self.reply(method, params).await;
        assert!(value.get("error").is_none(), "{method}: {value}");
        value["result"].clone()
    }

    async fn new_session(&mut self) -> String {
        let params = json!({"cwd": std::env::temp_dir(), "mcpServers": [], "_meta": {"acpmux": {"harness": "fake"}}});
        self.call("session/new", params).await["sessionId"].as_str().unwrap().to_owned()
    }

    /// The session's `user_message` records whose prompt id starts with `prefix`, once there
    /// are `count` of them (each is sent off the request's path).
    async fn prompts(&mut self, session: &str, prefix: &str, count: usize) -> Vec<Value> {
        for _ in 0..300 {
            let page = self
                .call("_acpmux/events", json!({"sessionId": session, "kinds": ["user_message"]}))
                .await;
            let found: Vec<Value> = page["events"]
                .as_array()
                .unwrap()
                .iter()
                .map(|e| e["msg"].clone())
                .filter(|m| m["promptId"].as_str().is_some_and(|id| id.starts_with(prefix)))
                .collect();
            if found.len() >= count {
                return found;
            }
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
        panic!("{session} never got {count} prompt(s) {prefix}*");
    }
}

#[tokio::test]
async fn a_task_brings_its_typed_result_back_to_the_chat_that_gave_it_once() {
    let hub = hub();
    let mut person = Client::open(&hub);
    let coordinator = person.new_session().await;
    let lane = person.new_session().await;
    let other = person.new_session().await;
    let giver = hub.resolve(&coordinator).unwrap().meta().name;
    let worker = hub.resolve(&lane).unwrap().meta().name;
    let mut from_coordinator = Client::in_session(&hub, &coordinator).await;
    let given = from_coordinator
        .call(
            "_acpmux/task_new",
            json!({"sessionId": lane, "title": "Land #24961", "stopCondition": "#24961 is merged"}),
        )
        .await;
    let task = &given["task"];
    let id = task["taskId"].as_str().unwrap().to_owned();
    assert_eq!(task["status"], "running", "{given}");
    assert_eq!(task["fromSession"], coordinator.as_str(), "{given}");

    // The lane gets the brief as the giver's message, the task id and the one call first.
    let brief = person.prompts(&lane, &format!("task-{id}"), 1).await.remove(0);
    let text = brief["text"].as_str().unwrap();
    assert!(text.starts_with(&format!("Task {id} from {giver}: Land #24961")), "{text}");
    assert!(text.contains(&format!("acpmux task done {id} --summary")), "{text}");
    let sent =
        json!({"kind": "session_message", "from": coordinator, "fromName": giver, "to": lane});
    assert_eq!(brief.pointer("/_meta/provenance"), Some(&sent), "{brief}");

    // Only the task's own session, or the chat that gave it, ends it; a result is checked.
    let done = json!({"briefId": id, "status": "done", "summary": "Merged at squash 3d17019",
                      "prs": ["https://github.com/manaflow-ai/cmux/pull/24961"], "shas": ["3d17019"]});
    let mut from_other = Client::in_session(&hub, &other).await;
    let refused = from_other.reply("_acpmux/report", done.clone()).await;
    assert_eq!(refused.pointer("/error/data/reason"), Some(&json!("task.not_yours")), "{refused}");
    let mut from_lane = Client::in_session(&hub, &lane).await;
    let mut bad = done.clone();
    bad["shas"] = json!(["3d17"]);
    let refused = from_lane.reply("_acpmux/report", bad).await;
    assert_eq!(refused.pointer("/error/data/reason"), Some(&json!("task.result_invalid")));

    let reported = from_lane.call("_acpmux/report", done.clone()).await;
    assert_eq!(reported["brief"]["status"], "done", "{reported}");
    assert_eq!(reported["brief"]["result"]["by"], worker.as_str(), "{reported}");
    // The same call again (a retry) is a replay: still one result, one card.
    let again = from_lane.call("_acpmux/report", done).await;
    assert_eq!(again["replayed"], true, "{again}");

    let card = person.prompts(&coordinator, &format!("task-result-{id}"), 1).await;
    tokio::time::sleep(Duration::from_millis(300)).await;
    let cards = person.prompts(&coordinator, &format!("task-result-{id}"), 1).await;
    assert_eq!(cards.len(), 1, "{cards:?}");
    let card = &card[0];
    let from_lane_card = json!({"kind": "task_result", "from": lane, "fromName": worker,
                                "to": coordinator, "taskId": id, "state": "done"});
    assert_eq!(card.pointer("/_meta/provenance"), Some(&from_lane_card), "{card}");
    assert_eq!(
        card["text"],
        format!(
            "Task {id} \"Land #24961\" done: Merged at squash 3d17019\n\
             PR: https://github.com/manaflow-ai/cmux/pull/24961\nSHA: 3d17019"
        ),
    );

    // The giver's list has it, ended, with its result; the open list does not.
    let listed = from_coordinator.call("_acpmux/tasks", json!({})).await;
    let rows = listed["tasks"].as_array().unwrap();
    assert_eq!(rows.len(), 1, "{listed}");
    assert_eq!(rows[0]["taskId"], id.as_str());
    assert_eq!(rows[0]["result"]["summary"], "Merged at squash 3d17019");
    assert!(rows[0]["lane"]["state"].is_string(), "{listed}");
    let open = from_coordinator.call("_acpmux/tasks", json!({"open": true})).await;
    assert_eq!(open["tasks"], json!([]), "{open}");
    // Another chat gave none.
    let theirs = from_other.call("_acpmux/tasks", json!({})).await;
    assert_eq!(theirs["tasks"], json!([]), "{theirs}");
}

#[tokio::test]
async fn a_blocked_task_says_why_and_a_task_is_given_only_to_a_session_here() {
    let hub = hub();
    let mut person = Client::open(&hub);
    let coordinator = person.new_session().await;
    let lane = person.new_session().await;
    let mut from_coordinator = Client::in_session(&hub, &coordinator).await;
    let missing = from_coordinator
        .reply("_acpmux/task_new", json!({"sessionId": "build-box/codex-lane", "title": "x"}))
        .await;
    assert!(missing.get("error").is_some(), "{missing}");
    let given = from_coordinator
        .call("_acpmux/task_new", json!({"sessionId": lane, "title": "Fix the flaky test"}))
        .await;
    let id = given["task"]["taskId"].as_str().unwrap().to_owned();
    let mut from_lane = Client::in_session(&hub, &lane).await;
    let blocked = json!({"briefId": id, "status": "blocked", "summary": "CI is down"});
    let refused = from_lane.reply("_acpmux/report", blocked.clone()).await;
    assert_eq!(refused.pointer("/error/data/reason"), Some(&json!("task.result_invalid")));
    let mut blocked = blocked;
    blocked["why"] = json!("every runner is offline");
    // A Web or peer connection proves no session: its result would read as the lane's.
    for origin in [Origin::Web, Origin::Peer] {
        let refused = Client::from(&hub, origin).reply("_acpmux/report", blocked.clone()).await;
        assert_eq!(refused.pointer("/error/data/reason"), Some(&json!("task.not_yours")));
    }
    from_lane.call("_acpmux/report", blocked).await;
    let card = person.prompts(&coordinator, &format!("task-result-{id}"), 1).await.remove(0);
    assert_eq!(
        card["text"],
        format!(
            "Task {id} \"Fix the flaky test\" blocked: CI is down\nWhy: every runner is offline"
        )
    );
    // A blocked task is still open, and the giver may end it once it is unblocked.
    let open = from_coordinator.call("_acpmux/tasks", json!({"open": true})).await;
    assert_eq!(open["tasks"][0]["status"], "blocked", "{open}");
    let done = json!({"briefId": id, "status": "done", "summary": "Fixed after CI came back"});
    from_coordinator.call("_acpmux/report", done).await;
    // The giver ended it itself: no card to itself.
    tokio::time::sleep(Duration::from_millis(300)).await;
    let cards = person.prompts(&coordinator, &format!("task-result-{id}"), 1).await;
    assert_eq!(cards.len(), 1, "{cards:?}");

    // The person at this machine's terminal may end a task; the card says it was not the lane.
    let given = from_coordinator
        .call("_acpmux/task_new", json!({"sessionId": lane, "title": "Rerun the nightly"}))
        .await;
    let id = given["task"]["taskId"].as_str().unwrap().to_owned();
    let done = json!({"briefId": id, "status": "done", "summary": "Reran it by hand"});
    person.call("_acpmux/report", done).await;
    let card = person.prompts(&coordinator, &format!("task-result-{id}"), 1).await.remove(0);
    let text = card["text"].as_str().unwrap();
    assert!(
        text.starts_with(&format!(
            "Task {id} \"Rerun the nightly\" done: Reran it by hand\nEnded by: "
        )),
        "{text}"
    );
}

#[tokio::test]
async fn two_reports_at_once_send_one_card_and_a_card_not_delivered_is_kept_and_sent_again() {
    let hub = hub();
    let mut person = Client::open(&hub);
    let coordinator = person.new_session().await;
    let lane = person.new_session().await;
    let mut from_coordinator = Client::in_session(&hub, &coordinator).await;

    // A bad sender name is refused before the task is claimed: no row is left behind.
    let bad = json!({"sessionId": lane, "title": "x", "idempotencyKey": "k1",
                     "_meta": {"acpmux": {"fromAgent": "two\nlines"}}});
    let refused = person.reply("_acpmux/task_new", bad).await;
    assert!(refused.get("error").is_some(), "{refused}");
    let all = person.call("_acpmux/tasks", json!({"all": true})).await;
    assert_eq!(all["tasks"], json!([]), "{all}");

    let given = from_coordinator
        .call("_acpmux/task_new", json!({"sessionId": lane, "title": "Land it"}))
        .await;
    let id = given["task"]["taskId"].as_str().unwrap().to_owned();
    let done = json!({"briefId": id, "status": "done", "summary": "Landed"});
    let (mut a, mut b) =
        (Client::in_session(&hub, &lane).await, Client::in_session(&hub, &lane).await);
    let (first, second) =
        tokio::join!(a.call("_acpmux/report", done.clone()), b.call("_acpmux/report", done));
    assert_eq!(
        [&first, &second].iter().filter(|r| r["replayed"] == true).count(),
        1,
        "{first} {second}"
    );
    tokio::time::sleep(Duration::from_millis(300)).await;
    let cards = person.prompts(&coordinator, &format!("task-result-{id}"), 1).await;
    assert_eq!(cards.len(), 1, "{cards:?}");

    // The chat that gave a task is gone: its result stays, marked not delivered, and the same
    // call again tries again instead of replaying.
    let gone = person.new_session().await;
    let mut from_gone = Client::in_session(&hub, &gone).await;
    let given =
        from_gone.call("_acpmux/task_new", json!({"sessionId": lane, "title": "Orphan"})).await;
    let id = given["task"]["taskId"].as_str().unwrap().to_owned();
    person.call("session/delete", json!({"sessionId": gone})).await;
    let done = json!({"briefId": id, "status": "done", "summary": "Done anyway",
                      "idempotencyKey": "orphan-done"});
    a.call("_acpmux/report", done.clone()).await;
    let row = |listed: &Value| {
        listed["tasks"].as_array().unwrap().iter().find(|t| t["taskId"] == id.as_str()).cloned()
    };
    let listed = person.call("_acpmux/tasks", json!({"all": true})).await;
    let task = row(&listed).expect("the task");
    assert_eq!(task["result"]["summary"], "Done anyway", "{task}");
    assert!(task["result"]["undelivered"].is_string(), "{task}");
    // The same call again, with the same idempotency key, is a retry, not a replay.
    let again = a.call("_acpmux/report", done).await;
    assert!(again.get("replayed").is_none(), "{again}");
}

#[tokio::test]
async fn a_lane_that_closes_or_is_deleted_with_its_task_open_orphans_it_and_the_giver_hears_at_once()
 {
    let hub = hub();
    let mut person = Client::open(&hub);
    let coordinator = person.new_session().await;
    let closing = person.new_session().await;
    let deleted = person.new_session().await;
    let finished = person.new_session().await;
    let closing_name = hub.resolve(&closing).unwrap().meta().name;
    let deleted_name = hub.resolve(&deleted).unwrap().meta().name;
    let mut from_coordinator = Client::in_session(&hub, &coordinator).await;
    let mut give = async |lane: &str, title: &str| {
        let given = from_coordinator
            .call("_acpmux/task_new", json!({"sessionId": lane, "title": title}))
            .await;
        given["task"]["taskId"].as_str().unwrap().to_owned()
    };
    let t_closed = give(&closing, "Land the fix").await;
    let t_deleted = give(&deleted, "Write the doc").await;
    let t_done = give(&finished, "Rerun CI").await;
    let done = json!({"briefId": t_done, "status": "done", "summary": "Green"});
    Client::in_session(&hub, &finished).await.call("_acpmux/report", done).await;
    person.prompts(&coordinator, &format!("task-result-{t_done}"), 1).await;

    // cx3-s61 closed with Leo's asks unfinished, and nobody noticed.
    person.call("session/close", json!({"sessionId": closing})).await;
    person.call("session/delete", json!({"sessionId": deleted})).await;
    person.call("session/close", json!({"sessionId": finished})).await;
    let card = person.prompts(&coordinator, &format!("task-result-{t_closed}"), 1).await.remove(0);
    assert_eq!(
        card["text"],
        format!(
            "Task {t_closed} \"Land the fix\" orphaned: {closing_name} closed with it still open"
        )
    );
    let provenance = card.pointer("/_meta/provenance").unwrap();
    assert_eq!(provenance["state"], "orphaned", "{card}");
    assert_eq!(provenance["from"], closing.as_str(), "{card}");
    let card = person.prompts(&coordinator, &format!("task-result-{t_deleted}"), 1).await.remove(0);
    assert_eq!(
        card["text"],
        format!(
            "Task {t_deleted} \"Write the doc\" orphaned: {deleted_name} is gone with it still open"
        )
    );

    // Each card was sent once and accepted: no mark is left owed or claimed.
    for _ in 0..300 {
        let listed = from_coordinator.call("_acpmux/tasks", json!({})).await;
        let marked = listed["tasks"].as_array().unwrap().iter().any(|t| {
            t["result"].get("cardOwed").is_some() || t["result"].get("cardSending").is_some()
        });
        if !marked {
            break;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    let listed = from_coordinator.call("_acpmux/tasks", json!({})).await;
    for t in listed["tasks"].as_array().unwrap() {
        assert!(t["result"].get("cardOwed").is_none(), "{t}");
        assert!(t["result"].get("cardSending").is_none(), "{t}");
    }

    // Orphans first; the task that was done stays done, and no second card comes for it.
    let listed = from_coordinator.call("_acpmux/tasks", json!({})).await;
    let states: Vec<&str> =
        listed["tasks"].as_array().unwrap().iter().map(|t| t["status"].as_str().unwrap()).collect();
    assert_eq!(states, ["orphaned", "orphaned", "done"], "{listed}");
    let open = from_coordinator.call("_acpmux/tasks", json!({"open": true})).await;
    assert_eq!(open["tasks"].as_array().unwrap().len(), 2, "{open}");

    // The giver may still end an orphan, once it knows what became of it.
    let done = json!({"briefId": t_closed, "status": "done", "summary": "Landed it myself"});
    let ended = from_coordinator.call("_acpmux/report", done).await;
    assert_eq!(ended["brief"]["status"], "done", "{ended}");
}

/// A store that cannot list its sessions, as a daemon start whose inventory read failed: every
/// other call goes to `0`.
struct ListFails(Box<dyn acpmux::store::Store>);

impl acpmux::store::Store for ListFails {
    fn list(&self) -> anyhow::Result<Vec<acpmux::store::SessionMeta>> {
        anyhow::bail!("the session inventory could not be read")
    }
    fn load(&self, id: &str) -> anyhow::Result<Option<acpmux::store::SessionMeta>> {
        self.0.load(id)
    }
    fn save(&self, meta: &acpmux::store::SessionMeta) -> anyhow::Result<()> {
        self.0.save(meta)
    }
    fn append(&self, id: &str, record: &acpmux::store::EventRecord) -> anyhow::Result<()> {
        self.0.append(id, record)
    }
    fn events(
        &self,
        id: &str,
        after: u64,
        limit: usize,
    ) -> anyhow::Result<Vec<acpmux::store::EventRecord>> {
        self.0.events(id, after, limit)
    }
    fn delete(&self, id: &str) -> anyhow::Result<()> {
        self.0.delete(id)
    }
    fn briefs_path(&self) -> Option<std::path::PathBuf> {
        self.0.briefs_path()
    }
}

/// A daemon that starts without its sessions (the store's list failed) does not orphan their
/// tasks: only a lane's own close orphans its task, never what a start did not load.
#[tokio::test]
async fn a_daemon_that_could_not_list_its_sessions_orphans_none_of_their_tasks() {
    let root = std::env::temp_dir().join(format!("acpmux-orphan-list-{}", uuid::Uuid::now_v7()));
    let cfg = || {
        let mut cfg: Config = serde_json::from_value(json!({
            "harnesses": {"fake": {"argv": ["python3", FAKE], "family": "codex"}},
            "defaultHarness": "fake",
            "permissionPolicy": "approve-all"
        }))
        .unwrap();
        cfg.store.mode = StoreMode::Local;
        cfg
    };
    let first = Hub::new(cfg(), acpmux::store::open(&cfg().store, &root).unwrap());
    let mut person = Client::open(&first);
    let coordinator = person.new_session().await;
    let lane = person.new_session().await;
    let given = Client::in_session(&first, &coordinator)
        .await
        .call("_acpmux/task_new", json!({"sessionId": lane, "title": "Keep going"}))
        .await;
    let id = given["task"]["taskId"].as_str().unwrap().to_owned();

    let store = ListFails(acpmux::store::open(&cfg().store, &root).unwrap());
    let next = Hub::new(cfg(), Box::new(store));
    let listed = Client::open(&next).call("_acpmux/tasks", json!({"all": true})).await;
    let task = listed["tasks"].as_array().unwrap().iter().find(|t| t["taskId"] == id.as_str());
    let task = task.unwrap_or_else(|| panic!("{listed}"));
    assert_ne!(task["status"], "orphaned", "{task}");
    let _ = std::fs::remove_dir_all(&root);
}

/// Pages the bundle `begin` describes from `src` into `dst` and finishes it there (the app's
/// move, `transfer.rs`): the chat's id, now on `dst`.
async fn move_chat(src: &mut Client, dst: &mut Client, id: &str) {
    let begin =
        src.call("_acpmux/transfer_begin", json!({"sessionId": id, "interrupt": true})).await;
    let received = dst.call("_acpmux/transfer_receive", json!({"manifest": begin})).await;
    let receive_id = received["receiveId"].as_str().unwrap().to_owned();
    for file in begin["files"].as_array().unwrap() {
        let path = file["path"].as_str().unwrap();
        let mut offset = 0u64;
        loop {
            let part = src
                .call(
                    "_acpmux/transfer_read",
                    json!({"transferId": begin["transferId"], "path": path, "offset": offset, "limit": 65536}),
                )
                .await;
            let write = json!({"receiveId": receive_id, "path": path, "offset": offset, "data": part["data"]});
            dst.call("_acpmux/transfer_write", write).await;
            offset = part["next"].as_u64().unwrap();
            if part["eof"] == true {
                break;
            }
        }
    }
    let moved = dst.call("_acpmux/transfer_finish", json!({"receiveId": receive_id})).await;
    assert_eq!(moved["sessionId"], id, "{moved}");
    let commit =
        json!({"sessionId": id, "transferId": begin["transferId"], "to": {"sessionId": id}});
    src.call("_acpmux/transfer_commit", commit).await;
}

/// A lane that moves to another daemon, and one that comes back here in place of its closed
/// copy, keeps its task: the move closes the copy it leaves, but the lane goes on.
#[tokio::test]
async fn a_lane_that_moves_away_and_back_keeps_its_task() {
    let (here, there) = (hub(), hub());
    let (mut person, mut other) = (Client::open(&here), Client::open(&there));
    let coordinator = person.new_session().await;
    let lane = person.new_session().await;
    let given = Client::in_session(&here, &coordinator)
        .await
        .call("_acpmux/task_new", json!({"sessionId": lane, "title": "Keep going"}))
        .await;
    let id = given["task"]["taskId"].as_str().unwrap().to_owned();
    let status = async |c: &mut Client| {
        let listed = c.call("_acpmux/tasks", json!({"all": true})).await;
        let row = listed["tasks"].as_array().unwrap().iter().find(|t| t["taskId"] == id.as_str());
        row.unwrap_or_else(|| panic!("{listed}"))["status"].clone()
    };

    move_chat(&mut person, &mut other, &lane).await;
    assert_eq!(status(&mut person).await, "running", "moved away");
    move_chat(&mut other, &mut person, &lane).await;
    assert_eq!(status(&mut person).await, "running", "back here, in place of its closed copy");
    let info = person.call("_acpmux/info", json!({"sessionId": lane})).await;
    assert_ne!(info["status"], "closed", "{info}");
    let page = person
        .call("_acpmux/events", json!({"sessionId": coordinator, "kinds": ["user_message"]}))
        .await;
    let cards = page["events"].as_array().unwrap().iter().filter(|e| {
        e["msg"]["promptId"].as_str().is_some_and(|p| p.starts_with(&format!("task-result-{id}")))
    });
    assert_eq!(cards.count(), 0, "{page}");
}

/// A daemon started on `root` (a file store) with `cfg`'s fake harness; `list_fails` makes its
/// session list fail ([`ListFails`]).
fn hub_at(root: &Path, list_fails: bool) -> Arc<Hub> {
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", FAKE], "family": "codex"}},
        "defaultHarness": "fake",
        "permissionPolicy": "approve-all"
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Local;
    let store = acpmux::store::open(&cfg.store, root).unwrap();
    let store: Box<dyn acpmux::store::Store> =
        if list_fails { Box::new(ListFails(store)) } else { store };
    Hub::new(cfg, store)
}

/// The ledger row of task `id` as saved beside the store at `root`.
fn saved_task(root: &Path, id: &str) -> Value {
    let rows: Value =
        serde_json::from_slice(&std::fs::read(root.join("briefs.json")).unwrap()).unwrap();
    rows[id].clone()
}

/// A lane that moved away is still not ended after the daemon it left restarts: deleting its
/// closed copy there orphans nothing (the move is read from the log, not from memory).
#[tokio::test]
async fn deleting_a_moved_lanes_copy_after_a_restart_keeps_its_task() {
    let root = std::env::temp_dir().join(format!("acpmux-orphan-moved-{}", uuid::Uuid::now_v7()));
    let (here, there) = (hub_at(&root, false), hub());
    let (mut person, mut other) = (Client::open(&here), Client::open(&there));
    let coordinator = person.new_session().await;
    let lane = person.new_session().await;
    let given = Client::in_session(&here, &coordinator)
        .await
        .call("_acpmux/task_new", json!({"sessionId": lane, "title": "Keep going"}))
        .await;
    let id = given["task"]["taskId"].as_str().unwrap().to_owned();
    move_chat(&mut person, &mut other, &lane).await;

    let restarted = hub_at(&root, false);
    Client::open(&restarted).call("session/delete", json!({"sessionId": lane})).await;
    assert_eq!(saved_task(&root, &id)["status"], "running", "{}", saved_task(&root, &id));
    let _ = std::fs::remove_dir_all(&root);
}

/// An orphan card a crash left owed waits for its giver: a start that could not list its
/// sessions keeps it owed, and the next start with the giver loaded sends it.
#[tokio::test]
async fn an_owed_orphan_card_waits_for_a_start_that_loads_its_giver() {
    let root = std::env::temp_dir().join(format!("acpmux-orphan-owed-{}", uuid::Uuid::now_v7()));
    let first = hub_at(&root, false);
    let mut person = Client::open(&first);
    let coordinator = person.new_session().await;
    let lane = person.new_session().await;
    let given = Client::in_session(&first, &coordinator)
        .await
        .call("_acpmux/task_new", json!({"sessionId": lane, "title": "Keep going"}))
        .await;
    let id = given["task"]["taskId"].as_str().unwrap().to_owned();
    person.call("session/close", json!({"sessionId": lane})).await;
    person.prompts(&coordinator, &format!("task-result-{id}"), 1).await;
    // As a crash between the ledger write and the card leaves it.
    let path = root.join("briefs.json");
    let mut rows: Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
    rows[&id]["result"]["cardOwed"] = json!(true);
    std::fs::write(&path, serde_json::to_vec(&rows).unwrap()).unwrap();

    let _blind = hub_at(&root, true);
    let row = saved_task(&root, &id);
    assert_eq!(row["result"]["cardOwed"], true, "{row}");
    assert!(row["result"].get("undelivered").is_none(), "{row}");

    // The next start, with the giver loaded, sends it again: the giver already has it, so the
    // send is a duplicate (one card), and the mark goes.
    let next = hub_at(&root, false);
    for _ in 0..300 {
        if saved_task(&root, &id)["result"].get("cardOwed").is_none() {
            break;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    let row = saved_task(&root, &id);
    assert!(row["result"].get("cardOwed").is_none(), "{row}");
    let cards = Client::open(&next).prompts(&coordinator, &format!("task-result-{id}"), 1).await;
    assert_eq!(cards.len(), 1, "{cards:?}");
    let _ = std::fs::remove_dir_all(&root);
}

/// A lane closed while its move is still in flight is not orphaned: lanes in a move wait for
/// peer-hosted tasks (`hub/tasks.rs`). The task stays open, and `task ls` shows the lane closed.
#[tokio::test]
async fn a_lane_closed_mid_move_keeps_its_task_open() {
    let hub = hub();
    let mut person = Client::open(&hub);
    let coordinator = person.new_session().await;
    let lane = person.new_session().await;
    let mut from_coordinator = Client::in_session(&hub, &coordinator).await;
    let given = from_coordinator
        .call("_acpmux/task_new", json!({"sessionId": lane, "title": "Keep going"}))
        .await;
    let id = given["task"]["taskId"].as_str().unwrap().to_owned();
    person.call("_acpmux/transfer_begin", json!({"sessionId": lane, "interrupt": true})).await;
    person.call("session/close", json!({"sessionId": lane})).await;
    let listed = from_coordinator.call("_acpmux/tasks", json!({})).await;
    let task = listed["tasks"].as_array().unwrap().iter().find(|t| t["taskId"] == id.as_str());
    let task = task.unwrap_or_else(|| panic!("{listed}"));
    assert_eq!(task["status"], "running", "{task}");
    assert_eq!(task["sessionStatus"], "closed", "{task}");
}

/// A store whose logs cannot be scanned by kind (`scan_kinds` fails); everything else goes
/// to `0`.
struct ScanFails(Box<dyn acpmux::store::Store>);

impl acpmux::store::Store for ScanFails {
    fn list(&self) -> anyhow::Result<Vec<acpmux::store::SessionMeta>> {
        self.0.list()
    }
    fn load(&self, id: &str) -> anyhow::Result<Option<acpmux::store::SessionMeta>> {
        self.0.load(id)
    }
    fn save(&self, meta: &acpmux::store::SessionMeta) -> anyhow::Result<()> {
        self.0.save(meta)
    }
    fn append(&self, id: &str, record: &acpmux::store::EventRecord) -> anyhow::Result<()> {
        self.0.append(id, record)
    }
    fn events(
        &self,
        id: &str,
        after: u64,
        limit: usize,
    ) -> anyhow::Result<Vec<acpmux::store::EventRecord>> {
        self.0.events(id, after, limit)
    }
    fn scan_kinds(
        &self,
        _id: &str,
        _kinds: &[&str],
        _visit: &mut dyn FnMut(acpmux::store::EventRecord) -> bool,
    ) -> anyhow::Result<()> {
        anyhow::bail!("the log could not be read")
    }
    fn delete(&self, id: &str) -> anyhow::Result<()> {
        self.0.delete(id)
    }
}

/// A closing lane whose moves cannot be read may have moved on: its task is not orphaned on a
/// guess (it stays open; `task ls` shows its lane's state).
#[tokio::test]
async fn a_lane_whose_moves_cannot_be_read_is_not_orphaned_on_a_guess() {
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", FAKE], "family": "codex"}},
        "defaultHarness": "fake",
        "permissionPolicy": "approve-all"
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, Box::new(ScanFails(store)));
    let mut person = Client::open(&hub);
    let coordinator = person.new_session().await;
    let lane = person.new_session().await;
    let mut from_coordinator = Client::in_session(&hub, &coordinator).await;
    let given = from_coordinator
        .call("_acpmux/task_new", json!({"sessionId": lane, "title": "Keep going"}))
        .await;
    let id = given["task"]["taskId"].as_str().unwrap().to_owned();
    person.call("session/close", json!({"sessionId": lane})).await;
    let listed = from_coordinator.call("_acpmux/tasks", json!({})).await;
    let task = listed["tasks"].as_array().unwrap().iter().find(|t| t["taskId"] == id.as_str());
    let task = task.unwrap_or_else(|| panic!("{listed}"));
    assert_eq!(task["status"], "running", "{task}");
}
