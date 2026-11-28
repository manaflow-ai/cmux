//! Every close records who closed the chat, why, and how its work ended (`close_why.rs`): one
//! `mux/closed` record in its log, `close` on its meta and its closed row. One test per path.

use super::*;
use crate::close_why::{CloseActor, CloseWhy};
use crate::config::{Config, StoreMode};
use crate::store::SubsessionLink;
use std::path::Path;

async fn hub_with_chat() -> (Arc<Hub>, Arc<Session>) {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", fake]}},
        "defaultHarness": "fake",
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = crate::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    let req = NewRequest { cwd: Some(std::env::temp_dir()), ..NewRequest::default() };
    let chat = hub.new_session(req).await.unwrap();
    (hub, chat)
}

async fn child_of(hub: &Arc<Hub>, parent: &Session, short: &str) -> Arc<Session> {
    let req = NewRequest {
        cwd: Some(std::env::temp_dir()),
        subsession: Some(SubsessionLink {
            started_by: parent.id.clone(),
            short_name: short.to_owned(),
            depth: 1,
            offered: false,
            ..Default::default()
        }),
        ..NewRequest::default()
    };
    hub.new_session(req).await.unwrap()
}

/// The `mux/closed` records in `session`'s log.
fn closes(hub: &Hub, session: &Session) -> Vec<Value> {
    hub.events(&session.id, 0, 10_000)
        .unwrap()
        .into_iter()
        .filter(|e| e.dir == "mux" && e.kind == "closed")
        .map(|e| e.msg)
        .collect()
}

/// The one close recorded, as the log, the meta and the closed row all carry it.
fn the_close(hub: &Hub, session: &Session) -> Value {
    let logged = closes(hub, session);
    assert_eq!(logged.len(), 1, "{logged:?}");
    let meta = serde_json::to_value(session.meta().close.clone().unwrap()).unwrap();
    assert_eq!(logged[0], meta);
    assert_eq!(hub.session_list_summary(session)["close"], meta, "the closed row carries it");
    meta
}

fn lane(hub: &Hub, session: &Session) {
    let tags = json!({"lane.reportsTo": "coordinator"});
    hub.set_tags(session, tags.as_object(), &[], None);
}

/// `acpmux session stop NAME --outcome done --reason TEXT` (`_acpmux/kill` from the CLI).
#[tokio::test]
async fn a_cli_stop_records_its_actor_reason_and_outcome() {
    let (hub, chat) = hub_with_chat().await;
    let actor = CloseActor::new("cli").pid(Some(4242));
    let why = CloseWhy::from_params(actor, &json!({"reason": "merged #1", "outcome": "done"}));
    let condition = super::stop_if_idle::StopCondition::default();
    hub.stop_why(&chat, false, condition, why).await.unwrap();
    let close = the_close(&hub, &chat);
    assert_eq!(close["actor"], json!({"kind": "cli", "pid": 4242}));
    assert_eq!(close["reason"], "merged #1");
    assert_eq!(close["outcome"], "done");
    assert!(close["closedAt"].as_u64().unwrap() > 0);
    // Stopping it again records nothing new: the first close stays the record.
    hub.kill(&chat, false).await.unwrap();
    assert_eq!(closes(&hub, &chat).len(), 1);
}

/// A lane stopped with no outcome is recorded `unfinished`, and the stop is never refused.
#[tokio::test]
async fn a_lane_stopped_with_no_outcome_is_unfinished_and_still_stopped() {
    let (hub, chat) = hub_with_chat().await;
    lane(&hub, &chat);
    let why = CloseWhy::from_params(CloseActor::new("cli"), &json!({}));
    hub.stop_why(&chat, false, Default::default(), why).await.unwrap();
    assert_eq!(chat.status(), SessionStatus::Closed);
    let close = the_close(&hub, &chat);
    assert_eq!(close["outcome"], "unfinished");
    assert_eq!(close["reason"], "unrecorded");
}

/// An agent's `stop_session close:true` (MCP): the target and each session under it.
#[tokio::test]
async fn an_mcp_stop_session_records_the_caller_on_the_whole_family() {
    let (hub, parent) = hub_with_chat().await;
    let child = child_of(&hub, &parent, "worker").await;
    let grandchild = child_of(&hub, &child, "helper").await;
    let actor = CloseActor::new("mcp").session(Some(&parent.id));
    let why = CloseWhy::from_params(actor, &json!({"reason": "lane done", "outcome": "done"}));
    hub.subsession_stop_why(&child, true, why).await.unwrap();
    let close = the_close(&hub, &child);
    assert_eq!(close["actor"], json!({"kind": "mcp", "session": parent.id}));
    assert_eq!(close["reason"], "lane done");
    let below = the_close(&hub, &grandchild);
    assert_eq!(below["actor"]["kind"], "mcp");
    assert!(below["reason"].as_str().unwrap().contains(&child.id), "{below}");
    assert_eq!(below["outcome"], "done");
}

/// A session closing itself (`session/close` from its own caller token) and a peer's mesh stop
/// both go through `session/close`'s actor: recorded as `agent_self` and `peer`.
#[tokio::test]
async fn agent_self_and_peer_closes_are_recorded_by_kind() {
    let (hub, me) = hub_with_chat().await;
    lane(&hub, &me);
    let actor = CloseActor::new("agent_self").session(Some(&me.id));
    hub.kill_why(&me, false, CloseWhy::from_params(actor, &json!({}))).await.unwrap();
    let close = the_close(&hub, &me);
    assert_eq!(close["actor"]["kind"], "agent_self");
    assert_eq!(close["outcome"], "unfinished");

    let peer_closed = hub
        .new_session(NewRequest { cwd: Some(std::env::temp_dir()), ..NewRequest::default() })
        .await
        .unwrap();
    let params = json!({"reason": "mesh stop from far-mac: freeing the slot"});
    hub.kill_why(&peer_closed, false, CloseWhy::from_params(CloseActor::new("peer"), &params))
        .await
        .unwrap();
    let close = the_close(&hub, &peer_closed);
    assert_eq!(close["actor"]["kind"], "peer");
    assert!(close["reason"].as_str().unwrap().contains("far-mac"));
    assert_eq!(close["outcome"], "dropped");
}

/// The daemon's own closes: a close that names nobody is still recorded (`daemon`,
/// `unrecorded`), and an import replacing a chat is `moved`.
#[tokio::test]
async fn the_daemons_own_closes_are_recorded() {
    let (hub, chat) = hub_with_chat().await;
    lane(&hub, &chat);
    hub.kill(&chat, false).await.unwrap();
    let close = the_close(&hub, &chat);
    assert_eq!(close["actor"], json!({"kind": "daemon"}));
    assert_eq!(close["reason"], "unrecorded");
    assert_eq!(close["outcome"], "unfinished");

    let (hub, chat) = hub_with_chat().await;
    let why = CloseWhy::by("daemon", "replaced by an import of the same chat").outcome("moved");
    hub.kill_why(&chat, false, why).await.unwrap();
    assert_eq!(the_close(&hub, &chat)["outcome"], "moved");
}

/// An expiry's close (an ephemeral chat whose connection ended) is `ttl`; its purge takes the
/// log, so only the INFO line keeps it, and the purge still goes through.
#[tokio::test]
async fn a_ttl_purge_still_purges() {
    let (hub, chat) = hub_with_chat().await;
    let why = CloseWhy::by("ttl", "its ephemeral connection ended");
    hub.kill_why(&chat, true, why).await.unwrap();
    assert!(hub.resolve(&chat.id).is_err(), "purged");
}

/// A reopened chat's row no longer carries the close; its next close is recorded anew.
#[tokio::test]
async fn a_reopened_chat_carries_no_close_until_it_closes_again() {
    let (hub, chat) = hub_with_chat().await;
    hub.kill_why(&chat, false, CloseWhy::by("cli", "first")).await.unwrap();
    let stops = chat.stops.load(Ordering::SeqCst);
    assert!(hub.reopen(&chat, stops));
    assert!(hub.session_list_summary(&chat).get("close").is_none());
    hub.kill_why(&chat, false, CloseWhy::by("cli", "second")).await.unwrap();
    let logged = closes(&hub, &chat);
    assert_eq!(logged.len(), 2);
    assert_eq!(hub.session_list_summary(&chat)["close"]["reason"], "second");
}
