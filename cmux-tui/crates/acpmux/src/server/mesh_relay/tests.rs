use super::*;
use crate::mesh::{AckState, Sender, Target};

fn from(host: &str, name: &str) -> InMessage {
    InMessage {
        message_id: "m".into(),
        to: Target::default(),
        from: Sender { name: Some(name.into()), host: Some(host.into()), ..Sender::default() },
        body: "x".into(),
        mode: Mode::TurnEnd,
        attempt: 1,
        kind: Kind::Prompt,
        op: None,
        start_work: Some(StartWork::Information),
        state: Some("queued".into()),
        subject: None,
    }
}

#[test]
fn a_relayed_message_always_names_a_sender_on_one_line() {
    assert_eq!(sender_name(&from("gcp-codex-lane-3", "lane-a")), "gcp-codex-lane-3/lane-a");
    assert_eq!(sender_name(&from("", "lane-a")), "lane-a");
    assert_eq!(sender_name(&from("vm", "")), "a session on vm");
    assert_eq!(sender_name(&from(" ", "")), "a session on another machine");
    assert_eq!(sender_name(&from("vm\n", "a\u{7}b")), "vm/ab");
    let long = sender_name(&from(&"h".repeat(80), "lane"));
    assert_eq!(long.chars().count(), crate::hub::MAX_FROM_AGENT_CHARS);
}

#[test]
fn team_sender_names_are_explicitly_addressed() {
    let mut message = from("", "lane");
    message.from.team_address = Some("lawrence/coordinator".into());
    assert_eq!(sender_name(&message), "@lawrence/coordinator");
}

#[test]
fn the_same_persons_direct_prompt_is_a_turn_and_any_other_marked_one_is_information() {
    let mut message = from("machine-a", "own-e2e");
    message.from.user = Some("person-1".into());
    // The hub marks every message `information` by default.
    assert!(!team_delivery(&message, Some("person-1")), "the same person's own prompt");
    assert!(team_delivery(&message, Some("person-2")), "another person's");
    assert!(team_delivery(&message, None), "no person recorded here");
    message.from.user = None;
    assert!(team_delivery(&message, Some("person-1")), "no hub-stamped sender");
    message.from.user = Some("person-1".into());
    message.from.team_address = Some("@person-1/lead".into());
    assert!(team_delivery(&message, Some("person-1")), "a team sender");
    message.from.team_address = None;
    message.to.team_address = Some("@person-1/coordinator".into());
    assert!(team_delivery(&message, Some("person-1")), "a team address always is");
    message.to.team_address = None;
    message.start_work = None;
    assert!(!team_delivery(&message, None), "an unmarked direct prompt, as before");
}

#[test]
fn only_an_explicit_allowed_decision_can_start_work() {
    let mut message = from("", "lane");
    message.to.team_address = Some("@team/coordinator".into());
    message.start_work = None;
    assert!(!start_work_allowed(&message));
    message.start_work = Some(StartWork::Information);
    assert!(!start_work_allowed(&message));
    message.start_work = Some(StartWork::Allowed);
    assert!(start_work_allowed(&message));
}

#[test]
fn heartbeats_come_at_a_third_of_the_ttl_at_most_every_heartbeat_every() {
    let options = RelayOptions::default();
    assert_eq!(heartbeat_wait(&options, 90), Duration::from_secs(30));
    assert_eq!(heartbeat_wait(&options, 30), Duration::from_secs(10));
    assert_eq!(heartbeat_wait(&options, 0), Duration::from_secs(30));
    let mut backoff = Backoff::new(Duration::from_secs(1), Duration::from_secs(4));
    let limited =
        HubError { retry_after: Some(Duration::from_secs(9)), ..HubError::unavailable("") };
    assert_eq!(after_failure(&mut backoff, &limited), Duration::from_secs(9));
}

#[tokio::test(start_paused = true)]
async fn a_late_rpc_result_survives_the_delivery_lease() {
    let ledger = ControlLedger::open(None);
    let mut message = from("", "");
    message.kind = Kind::Control;
    message.op = Some("start".into());
    let Claim::New { key, receiver } = ledger.claim("sender", &message, true) else {
        panic!("a new operation must be admitted");
    };
    let (tx, mut requests) = mpsc::channel(1);
    let (replies, mut rx) = mpsc::channel(1);
    let target = tokio::spawn(async move {
        requests.recv().await.unwrap();
        tokio::time::sleep(Duration::from_secs(90)).await;
        replies
            .send(crate::rpc::Message::ok(json!(2), json!({"sessionId": "stable-id"})).to_line())
            .await
            .unwrap();
    });
    let worker_ledger = ledger.clone();
    let worker = tokio::spawn(async move {
        let result = rpc_call(&tx, &mut rx, 2, crate::rpc::method::SESSION_NEW, json!({})).await;
        if let Ok(result) = result {
            worker_ledger
                .finish(&key, Ack::delivered("m", result["sessionId"].as_str().map(str::to_owned)));
        }
    });
    assert!(wait_control_result(receiver, Duration::from_secs(50)).await.is_none());
    let Claim::Waiting(receiver) = ledger.claim("sender", &message, true) else {
        panic!("redelivery must join the running operation");
    };
    let ack = wait_control_result(receiver, Duration::from_secs(50)).await.unwrap();
    assert_eq!(ack.state, AckState::Delivered);
    assert_eq!(ack.detail.as_deref(), Some("stable-id"));
    target.await.unwrap();
    worker.await.unwrap();
    assert!(matches!(ledger.claim("sender", &message, true), Claim::Done(_)));
}

#[tokio::test]
async fn a_lost_rpc_response_is_indeterminate_not_refused() {
    let (tx, mut requests) = mpsc::channel(1);
    let (replies, mut rx) = mpsc::channel(1);
    let target = tokio::spawn(async move {
        requests.recv().await.unwrap();
        // The handler may have executed before the connection dropped.
        drop(replies);
    });
    let result = rpc_call(&tx, &mut rx, 1, crate::rpc::method::SESSION_NEW, json!({})).await;
    assert!(matches!(result, Err(ControlFailure::Unknown)));
    target.await.unwrap();
}

#[test]
fn an_ack_detail_is_clipped_to_what_the_hub_takes() {
    let ack = clip(Ack::refused("é".repeat(5000)));
    assert_eq!(ack.detail.unwrap().chars().count(), MAX_DETAIL_CHARS);
    assert_eq!(clip(Ack::refused("short")).detail.as_deref(), Some("short"));
}
