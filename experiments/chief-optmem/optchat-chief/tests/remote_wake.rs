//! The remote-origin gate (README "Remote-origin messages"): a message that
//! the user's own paired device sent through the remote relay wakes the
//! Chief and is logged like a local one; everything else from a device, or
//! claiming to be from one, is refused (default deny).

mod common;

use std::sync::Arc;

use cmux_conversation::{
    Change, Message, Origin, Participant, ParticipantKind, Summary, TextRun,
};
use common::*;
use optchat_chief::brain::Input;
use optchat_chief::daemon::DaemonEvent;
use optchat_chief::wake::chief_wakes;

const DEVICE: &str = "remote_inst_1";

fn participant(id: &str, kind: ParticipantKind, person: Option<&str>) -> Participant {
    Participant {
        id: id.into(),
        kind,
        display_name: id.into(),
        agent_class: None,
        acp_session: None,
        person: person.map(str::to_owned),
    }
}

/// The Chief conversation after pairing: the Mac user, the Chief, and the
/// user's phone (the same person, as the relay's pairing path adds it).
fn paired() -> Summary {
    let mut s = summary();
    s.participants
        .push(participant(DEVICE, ParticipantKind::Human, Some("user_local")));
    s
}

/// A message the relay delivered from `install`: the owner stamps the origin
/// from the actor.
fn from_device(seq: u64, author: &str, install: &str, text: &str) -> Message {
    let mut m = message(seq, author, text);
    m.origin = Some(Origin::Remote {
        install: install.into(),
    });
    m
}

#[test]
fn the_users_own_paired_device_wakes_the_chief() {
    let s = paired();
    assert!(chief_wakes(&s, &from_device(1, DEVICE, "inst_1", "hi"), |_| false));
    // Local messages keep the shared rule.
    assert!(chief_wakes(&s, &message(2, "user_local", "hi"), |_| false));
    // A conversation of only the phone and the Chief is one person too.
    let mut only = summary();
    only.participants.retain(|p| p.id != "user_local");
    only.participants
        .push(participant(DEVICE, ParticipantKind::Human, Some("user_local")));
    assert!(chief_wakes(&only, &from_device(1, DEVICE, "inst_1", "hi"), |_| false));
}

#[test]
fn a_group_message_from_a_device_wakes_only_with_a_mention() {
    let mut s = paired();
    s.participants
        .push(participant("user_2", ParticipantKind::Human, None));
    assert!(!chief_wakes(&s, &from_device(1, DEVICE, "inst_1", "hi all"), |_| false));
    let mut mentioned = from_device(2, DEVICE, "inst_1", "@Chief hi");
    if let cmux_conversation::Part::Text { runs, .. } = &mut mentioned.parts[0] {
        *runs = Some(vec![TextRun {
            start: 0,
            length: 6,
            mention: Some("agent_mux".into()),
            link: None,
        }]);
    }
    assert!(chief_wakes(&s, &mentioned, |_| false));
}

#[test]
fn every_other_device_message_is_refused() {
    let s = paired();
    // No origin: the owner did not stamp it as relayed.
    assert!(!chief_wakes(&s, &message(1, DEVICE, "hi"), |_| false));
    // The origin names another install than the author.
    assert!(!chief_wakes(&s, &from_device(2, DEVICE, "inst_2", "hi"), |_| false));
    // A local author with a remote origin.
    assert!(!chief_wakes(&s, &from_device(3, "user_local", "inst_1", "hi"), |_| false));
    // A device of another person (another account), or of no person.
    for person in [Some("user_2"), None] {
        let mut other = summary();
        other
            .participants
            .push(participant(DEVICE, ParticipantKind::Human, person));
        assert!(
            !chief_wakes(&other, &from_device(4, DEVICE, "inst_1", "hi"), |_| false),
            "{person:?}"
        );
    }
    // A device participant that is not a human.
    let mut agent = summary();
    agent
        .participants
        .push(participant(DEVICE, ParticipantKind::Agent, Some("user_local")));
    assert!(!chief_wakes(&agent, &from_device(5, DEVICE, "inst_1", "hi"), |_| false));
    // A participant id without the `remote_` prefix, even with a person.
    let mut odd = summary();
    odd.participants
        .push(participant("user_9", ParticipantKind::Human, Some("user_local")));
    assert!(!chief_wakes(&odd, &message(6, "user_9", "hi"), |_| false));
    // Not a participant, retracted, or a conversation without the Chief.
    assert!(!chief_wakes(&summary(), &from_device(7, DEVICE, "inst_1", "hi"), |_| false));
    let mut retracted = from_device(8, DEVICE, "inst_1", "hi");
    retracted.retracted_at = Some("2026-10-06T00:00:00Z".into());
    assert!(!chief_wakes(&s, &retracted, |_| false));
    let mut without = paired();
    without.participants.retain(|p| p.id != "agent_mux");
    assert!(!chief_wakes(&without, &from_device(9, DEVICE, "inst_1", "hi"), |_| false));
}

/// End to end: the phone's message is logged as `user`, word for word, and
/// starts a turn that answers in the conversation.
#[test]
fn a_device_message_is_logged_and_answered() {
    let dir = tempfile::tempdir().unwrap();
    let owner = Arc::new(std::sync::Mutex::new(Owner {
        summary: Some(paired()),
        ..Owner::default()
    }));
    let mut h = Harness::in_dir(dir, default_script(), owner);
    h.connect();
    let m = from_device(1, DEVICE, "inst_1", "buy milk on the way home");
    h.owner.lock().unwrap().messages.push(m.clone());
    h.brain.step(Input::from(DaemonEvent::Changed {
        conversation: CONV.into(),
        change: Change::Message { message: m },
    }));
    h.settle();
    let log = h.log();
    assert_eq!(log[0], ("user".into(), "buy milk on the way home".into()));
    assert_eq!(h.agents.inner.lock().unwrap().prompts.len(), 1);
    assert_eq!(h.owner.lock().unwrap().sends().len(), 1);
}
