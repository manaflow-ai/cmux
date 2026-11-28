use super::*;
use serde_json::json;
use std::sync::Mutex;

const AGENT: &str = "agt-1";

fn record(kind: &str, msg: Value, at: u64) -> EventRecord {
    serde_json::from_value(json!({"seq": 1, "at": at, "dir": "mux", "kind": kind, "msg": msg}))
        .unwrap()
}

#[test]
fn audit_denies_of_the_agents_sessions_are_refusals() {
    let entries = [
        json!({"at": 10, "sessionId": "a", "kind": "approval", "decision": {"kind": "deny"}}),
        json!({"at": 11, "sessionId": "a", "kind": "approval", "decision": {"kind": "allow"}}),
        json!({"at": 12, "sessionId": "b", "kind": "approval", "decision": {"kind": "deny"}}),
        json!({"at": 13, "sessionId": "a", "kind": "review", "decision": {"kind": "changes"}}),
        json!({"at": 14, "sessionId": "a", "kind": "approval", "decision": {"kind": "cancel"}}),
    ];
    let got = refusals_from_audit(&entries, &HashSet::from(["a"]));
    assert_eq!(got, vec![Event { at: 10, kind: EventKind::Refusal { evaded: false } }]);
}

#[test]
fn policy_rejects_and_policy_cancels_are_refusals_other_cancels_are_not() {
    let at = |r: &EventRecord| refusal_of_record(r).map(|e| e.at);
    let gate = json!({"policy": "review", "optionId": "reject_once", "gate": "preToolUse"});
    assert_eq!(at(&record("permission_auto", gate, 1)), Some(1));
    let cancel = json!({"policy": "deny-all", "cancelled": true});
    assert_eq!(at(&record("permission_auto", cancel, 2)), Some(2));
    let allowed = json!({"policy": "approve-reads", "optionId": "allow_once"});
    assert_eq!(at(&record("permission_auto", allowed, 3)), None);
    let grouping = json!({"cancelled": true, "reason": "group full"});
    assert_eq!(at(&record("permission_auto", grouping, 4)), None);
    let other = json!({"optionId": "reject_once"});
    assert_eq!(at(&record("permission_decision", other, 5)), None);
}

#[tokio::test]
async fn the_hub_reads_refusals_from_its_own_log() {
    let mut config = crate::config::Config::default();
    config.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&config.store, std::path::Path::new("/nonexistent")).unwrap();
    let meta: crate::store::SessionMeta = serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": "s1", "name": "lane", "harness": "claude",
        "cwd": "/tmp", "status": "idle", "createdAt": 1, "updatedAt": 1
    }))
    .unwrap();
    store.save(&meta).unwrap();
    let hub = super::super::Hub::new(config, store);
    let session = hub.make_session(meta);
    hub.sessions.lock().unwrap().insert("s1".to_owned(), session.clone());
    let deny = json!({"policy": "review", "optionId": "reject_once", "request": {}});
    hub.append_logged(&session, "mux", "permission_auto", deny, None);
    let allow = json!({"policy": "review", "optionId": "allow_once", "request": {}});
    hub.append_logged(&session, "mux", "permission_auto", allow, None);

    let refusals = hub.local_refusals(&["s1"]);
    assert_eq!(refusals.len(), 1);
    assert_eq!(refusals[0].kind, EventKind::Refusal { evaded: false });
    assert!(hub.local_refusals(&["other"]).is_empty());

    // Fed to the ladder: ten landings before the refusal no longer count.
    let landed: Vec<Event> =
        (0..10).map(|i| Event { at: refusals[0].at - 100 + i, kind: EventKind::Landed }).collect();
    let e = hub.earned_eligibility(&["s1"], &landed, refusals[0].at + 1);
    assert_eq!(e.earned, super::super::earned_access::Rung::Reads);
    assert_eq!(e.reset_at, Some(refusals[0].at));
    let without = hub.earned_eligibility(&["other"], &landed, refusals[0].at + 1);
    assert_eq!(without.earned, super::super::earned_access::Rung::Full);
}

fn cloud(kind: &str, at: u64, trailer: Option<&str>, green: bool) -> CloudEvent {
    CloudEvent {
        kind: kind.into(),
        at,
        pr_url: format!("https://github.com/o/r/pull/{at}"),
        trailer_agent_id: trailer.map(str::to_owned),
        checks_green: green,
    }
}

#[test]
fn only_trailer_checked_green_landings_and_reverts_count() {
    let events = [
        cloud("landed", 1, Some(AGENT), true),
        cloud("landed", 2, Some(AGENT), false),
        cloud("landed", 3, Some("agt-other"), true),
        cloud("landed", 4, None, true),
        cloud("revert", 5, Some(AGENT), false),
        cloud("revert", 6, Some("agt-other"), false),
        cloud("retitled", 7, Some(AGENT), true),
    ];
    let got = events_from_cloud(AGENT, &events);
    assert_eq!(
        got,
        vec![Event { at: 1, kind: EventKind::Landed }, Event { at: 5, kind: EventKind::Revert },]
    );
}

struct Fake {
    pages: Vec<AgentRecordReadResult>,
    asked: Mutex<Vec<AgentRecordReadParams>>,
}

impl RecordSource for Fake {
    async fn page(&self, p: AgentRecordReadParams) -> Result<AgentRecordReadResult, String> {
        let mut asked = self.asked.lock().unwrap();
        asked.push(p);
        self.pages.get(asked.len() - 1).cloned().ok_or_else(|| "no page".into())
    }
}

#[tokio::test]
async fn the_client_follows_every_page_and_feeds_the_ladder() {
    let fake = Fake {
        pages: vec![
            AgentRecordReadResult {
                events: vec![cloud("landed", 100, Some(AGENT), true)],
                next_cursor: Some("c2".into()),
            },
            AgentRecordReadResult {
                events: vec![
                    cloud("landed", 101, Some(AGENT), true),
                    cloud("landed", 102, Some(AGENT), true),
                ],
                next_cursor: None,
            },
        ],
        asked: Mutex::new(Vec::new()),
    };
    let events = cloud_events(&fake, AGENT, 50).await.unwrap();
    assert_eq!(events.len(), 3);
    let asked = fake.asked.lock().unwrap().clone();
    assert_eq!(asked.len(), 2);
    assert_eq!((asked[0].since, asked[0].cursor.as_deref()), (50, None));
    assert_eq!(asked[1].cursor.as_deref(), Some("c2"));
    let e = super::super::earned_access::eligibility(&events, 200);
    assert_eq!(e.earned, super::super::earned_access::Rung::Edits);
}

#[tokio::test]
async fn a_failed_page_fails_the_read() {
    let fake = Fake { pages: vec![], asked: Mutex::new(Vec::new()) };
    assert_eq!(cloud_events(&fake, AGENT, 0).await, Err("no page".into()));
}

#[test]
fn the_op_reads_the_services_answer_and_its_refusal() {
    let body = json!({
        "op": "cloud.agent.record.read", "stream": "team:t", "revision": "7",
        "value": {"events": [{"kind": "landed", "at": 9, "pr_url": "https://github.com/o/r/pull/9",
                              "trailer_agent_id": AGENT, "checks_green": true}],
                  "next_cursor": null}
    });
    let answer = cmux_cloud_client::ops::read_answer::<AgentRecordReadOp>(
        200,
        None,
        body.to_string().as_bytes(),
    )
    .unwrap()
    .into_result()
    .unwrap();
    assert_eq!(answer.events, vec![cloud("landed", 9, Some(AGENT), true)]);
    assert_eq!(
        serde_json::to_value(AgentRecordReadParams {
            agent_id: AGENT.into(),
            since: 3,
            cursor: None
        })
        .unwrap(),
        json!({"agent_id": AGENT, "since": 3})
    );

    let refused = json!({"_tag": "OpError", "code": "auth.unauthenticated", "message": "sign in"});
    let error = cmux_cloud_client::ops::read_answer::<AgentRecordReadOp>(
        401,
        None,
        refused.to_string().as_bytes(),
    )
    .unwrap_err();
    assert_eq!(error.status, Some(401));
    assert_eq!(
        AgentRecordReadError::from_code("cloud.agent.not_found"),
        AgentRecordReadError::NotFound
    );
    assert!(!AgentRecordReadError::from_code("new.code").is_declared());
}
