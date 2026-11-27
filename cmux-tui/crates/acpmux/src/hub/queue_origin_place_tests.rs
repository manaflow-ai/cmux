//! Where the person's prompt goes in the queue (`queue_origin::person_place`): ahead of every
//! prompt the person did not send, an inbox notice and a surge digest too.

use super::super::queue::{PromptRun, QueuedPrompt};
use super::super::{Control, inbox, surge_triage};
use super::*;
use serde_json::json;
use std::sync::{Arc, Mutex as StdMutex};
use tokio::sync::Notify;

fn queued(id: &str, agent: Option<&str>, kind: Option<&str>) -> QueuedPrompt {
    let run = PromptRun {
        size: Default::default(),
        blocks: vec![json!({"type": "text", "text": id})],
        display_parts: None,
        control: Control::Local,
        cloud_mobile: false,
        trust_gate: false,
        provenance: kind.map(|k| json!({"kind": k})),
        agent: agent.map(str::to_owned),
        class: None,
        supersede: None,
        full_access_device: None,
        message_id: None,
        message_sender: None,
    };
    QueuedPrompt {
        prompt_id: id.into(),
        turn_id: format!("t-{id}"),
        client: "test".into(),
        preview: id.into(),
        queued_at: 7,
        withdraw: Arc::new(Notify::new()),
        run: Arc::new(run),
        restored: false,
        resume: false,
        steer: false,
        steer_on_start: false,
        held: false,
        awaiting_owner: false,
        revision: 0,
        declined: Arc::new(std::sync::atomic::AtomicBool::new(false)),
        sent_now: false,
        joined: Arc::new(StdMutex::new(None)),
        requeued: false,
        retries: 0,
    }
}

#[test]
fn the_persons_prompt_goes_ahead_of_an_inbox_notice_and_a_surge_digest() {
    // Leo's coordinator, 2026-11-27: his message waited behind "Held during a message surge"
    let queue = vec![
        queued("mine", None, None),
        queued("notice", None, Some(inbox::NOTICE_KIND)),
        queued("surge", None, Some(surge_triage::PROVENANCE_KIND)),
        queued("lane", Some("lane-a"), Some("agent_message")),
    ];
    assert_eq!(person_place(&queue), Some(1));
    let queue = vec![
        queued("surge", None, Some(surge_triage::PROVENANCE_KIND)),
        queued("mine", None, None),
    ];
    assert_eq!(person_place(&queue), Some(0));
}

#[test]
fn the_persons_prompt_stays_behind_their_own_and_a_prompt_sent_now() {
    let mut now = queued("notice", None, Some(inbox::NOTICE_KIND));
    now.sent_now = true;
    let queue = vec![queued("mine", None, None), now, queued("mine-2", None, None)];
    assert_eq!(person_place(&queue), None);
    let mut held = queued("held", None, None);
    held.held = true;
    assert_eq!(person_place(&[queued("mine", None, None), held]), Some(1));
}
