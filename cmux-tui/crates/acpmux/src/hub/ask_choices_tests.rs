//! A waiting ask's one-tap choices, and a tap's answer through the one answer path.

use super::super::questions::{PreviewFormat, normalize};
use super::super::{Control, Hub, PendingPermission, person::Answerer};
use super::*;
use crate::config::Config;
use crate::store::{SessionMeta, SessionStatus};
use std::sync::Arc;
use tokio::sync::oneshot;

fn options() -> Value {
    json!([
        {"optionId": "a1", "name": "Allow once", "kind": "allow_once"},
        {"optionId": "a2", "name": "Always allow", "kind": "allow_always"},
        {"optionId": "r1", "name": "Deny", "kind": "reject_once"}
    ])
}

fn permission() -> Value {
    json!({"toolCall": {"title": "rm -rf build", "kind": "execute"}, "options": options()})
}

fn plan() -> Value {
    json!({"toolCall": {"title": "Ready to code?", "_meta": {"claude": {"tool": "ExitPlanMode"}},
    "rawInput": {"plan": "1. Write the test\n2. Fix it"}},
    "options": [
        {"optionId": "auto", "name": "Yes, and auto-accept edits", "kind": "allow_always"},
        {"optionId": "yes", "name": "Yes", "kind": "allow_once"},
        {"optionId": "no", "name": "No, keep planning", "kind": "reject_once"}
    ]})
}

fn question(labels: &[&str], multi: bool) -> Value {
    let options: Vec<Value> = labels.iter().map(|l| json!({"label": l})).collect();
    let mut request = json!({
        "toolCall": {"toolCallId": "ask-1", "rawInput": {"questions": [{
            "question": "Which card?", "options": options, "multiSelect": multi
        }]}, "_meta": {"claude": {"tool": "AskUserQuestion", "interactive": true}}},
        "options": [{"optionId": "allow_once", "kind": "allow_once"},
                    {"optionId": "reject_once", "kind": "reject_once"}]
    });
    normalize(&mut request, PreviewFormat::Monospace);
    request
}

fn ids(request: &Value) -> (Ask, Vec<String>) {
    let (ask, list) = choices(request);
    (ask, list.into_iter().map(|c| c.id).collect())
}

#[test]
fn a_plan_carries_approve_and_keep_planning_never_auto_accept() {
    let (ask, list) = choices(&plan());
    assert_eq!(ask, Ask::Plan);
    let shown: Vec<Value> = list.iter().map(Choice::json).collect();
    assert_eq!(
        shown,
        vec![
            json!({"id": "approve", "label": "Approve plan", "kind": "allow", "signed": true}),
            json!({"id": "keep_planning", "label": "Keep planning", "kind": "deny", "signed": false}),
        ]
    );
    assert_eq!(resolve(&plan(), "approve").unwrap(), ("yes".to_owned(), None));
    assert_eq!(resolve(&plan(), "keep_planning").unwrap(), ("no".to_owned(), None));
}

#[test]
fn a_permission_carries_allow_once_and_deny_never_a_lasting_grant() {
    assert_eq!(ids(&permission()), (Ask::Permission, vec!["allow_once".into(), "deny".into()]));
    assert_eq!(resolve(&permission(), "allow_once").unwrap().0, "a1");
    assert_eq!(resolve(&permission(), "deny").unwrap().0, "r1");
    // Only a lasting grant on offer: no allow choice, the app answers it.
    let lasting = json!({"toolCall": {"title": "x"}, "options": [
        {"optionId": "a2", "kind": "allow_always"}, {"optionId": "r2", "kind": "reject_always"}]});
    assert_eq!(ids(&lasting), (Ask::Permission, vec![]));
    let refused = resolve(&lasting, "allow_once").unwrap_err();
    assert_eq!(refused.data.unwrap()["reason"], "choice.not_offered");
}

#[test]
fn a_one_pick_question_carries_its_choices_as_answers() {
    let request = question(&["Glass", "Plain"], false);
    assert_eq!(ids(&request), (Ask::Question, vec!["option.0".into(), "option.1".into()]));
    let (option, answers) = resolve(&request, "option.1").unwrap();
    assert_eq!(option, "allow_once");
    assert_eq!(answers, Some(json!({"Which card?": "Plain"})));
    assert_eq!(choices(&request).1[0].json()["kind"], "answer");
    assert_eq!(choices(&request).1[0].json()["signed"], true);
}

#[test]
fn a_question_that_needs_the_chat_carries_none() {
    assert_eq!(ids(&question(&["A", "B", "C", "D"], false)).1, Vec::<String>::new());
    assert_eq!(ids(&question(&["A", "B"], true)).1, Vec::<String>::new());
    assert_eq!(ids(&question(&[], false)).1, Vec::<String>::new());
    let trust = json!({"toolCall": {"_meta": {"acpmux": {"trust": {"cwd": "/w"}}}},
        "options": [{"optionId": "t", "kind": "allow_once"}]});
    assert_eq!(ids(&trust).1, Vec::<String>::new());
}

fn hub_with(request: Value) -> (Arc<Hub>, Arc<super::super::Session>, oneshot::Receiver<Value>) {
    let mut config = Config::default();
    config.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&config.store, std::path::Path::new("/unused")).unwrap();
    let hub = Hub::new(config, store);
    let meta: SessionMeta = serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": "choice-session", "name": "Choice",
        "harness": "claude", "cwd": "/tmp", "status": "waiting", "createdAt": 1, "updatedAt": 1
    }))
    .unwrap();
    hub.store.save(&meta).unwrap();
    let session = hub.make_session(meta);
    let (reply, receiver) = oneshot::channel();
    session.permissions.lock().unwrap().pending.insert(
        "perm-1".into(),
        PendingPermission {
            request,
            reply,
            decision_nonce: "choice-nonce".into(),
            ancestor_may_answer: false,
            prev_status: SessionStatus::Running,
            agent_request: None,
            agent_host_incarnation: None,
        },
    );
    (hub, session, receiver)
}

async fn tap(hub: &Hub, session: &super::super::Session, choice: &str) -> Result<(), RpcError> {
    let person = Answerer { person: true, ..Default::default() };
    hub.respond_choice(session, "perm-1", choice, None, person, Control::Local).await
}

#[tokio::test]
async fn a_tap_answers_through_the_answer_path_and_a_second_is_refused_as_stale() {
    let (hub, session, receiver) = hub_with(question(&["Glass", "Plain"], false));
    tap(&hub, &session, "option.0").await.unwrap();
    let delivered = receiver.await.unwrap();
    assert_eq!(delivered["optionId"], "allow_once");
    assert_eq!(delivered["_meta"]["updatedInput"]["answers"], json!({"Which card?": "Glass"}));
    // Answered already: refused as any late answer, saying how it was answered.
    let stale = tap(&hub, &session, "option.1").await.unwrap_err();
    assert_eq!(stale.code, -32002);
    assert!(stale.message.contains("no pending permission perm-1"));
    assert!(stale.data.is_some());
}

#[tokio::test]
async fn an_allow_tap_from_a_device_that_is_not_the_person_needs_its_proof() {
    let (hub, session, _receiver) = hub_with(permission());
    let device = Answerer { person: false, ..Default::default() };
    let refused = hub
        .respond_choice(&session, "perm-1", "allow_once", None, device, Control::Local)
        .await
        .unwrap_err();
    assert!(session.permissions.lock().unwrap().pending.contains_key("perm-1"), "{refused:?}");
    // A deny needs no proof, as a deny from anywhere.
    let device = Answerer { person: false, ..Default::default() };
    hub.respond_choice(&session, "perm-1", "deny", None, device, Control::Local).await.unwrap();
    assert!(!session.permissions.lock().unwrap().pending.contains_key("perm-1"));
}

#[tokio::test]
async fn a_choice_the_ask_does_not_offer_is_refused_and_the_ask_stays() {
    let (hub, session, _receiver) = hub_with(permission());
    let refused = tap(&hub, &session, "allow_always").await.unwrap_err();
    assert_eq!(refused.data.unwrap()["reason"], "choice.not_offered");
    assert!(session.permissions.lock().unwrap().pending.contains_key("perm-1"));
}
