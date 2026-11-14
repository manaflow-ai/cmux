use super::*;

const CONV: &str = "conv_0123456789ABCDEFGHJKMNPQRS";

fn presence(stream: &mut StreamState, frame: Value) -> Vec<Value> {
    stream
        .on_text(&frame.to_string(), 0)
        .into_iter()
        .filter_map(|action| match action {
            StreamAction::Emit(event) => Some(event.wire_json()),
            _ => None,
        })
        .collect()
}

/// `conversation-presence` of this conversation becomes the
/// `cloud-conversation-presence` event (the whole set); another
/// conversation's, a malformed one and an oversized one are dropped; a
/// socket that ends after a non-empty set empties it once.
#[test]
fn the_owners_presence_passes_for_this_conversation_and_empties_when_the_socket_ends() {
    let mut stream =
        StreamState::new(Target::Conversation(CONV.to_string()), SnapshotBackoff::default());
    let frame = |conversation: &str, participants: Value| {
        json!({"t":"conversation-presence","conversation":conversation,
                   "participants":participants})
    };
    let one = json!([{"participant":"user_1","viewing":true}]);
    assert!(presence(&mut stream, frame("conv_other", one.clone())).is_empty());
    assert!(presence(&mut stream, frame(CONV, json!({"user_1":true}))).is_empty());
    let unnamed = json!([{"participant":"","viewing":true}]);
    assert!(presence(&mut stream, frame(CONV, unnamed)).is_empty());
    let unbool = json!([{"participant":"user_1","viewing":"yes"}]);
    assert!(presence(&mut stream, frame(CONV, unbool)).is_empty());
    let many: Vec<Value> = (0..=MAX_PRESENCE)
        .map(|n| json!({"participant":format!("user_{n}"),"viewing":true}))
        .collect();
    assert!(presence(&mut stream, frame(CONV, json!(many))).is_empty());
    let long = json!([{"participant":"u".repeat(MAX_PARTICIPANT_ID + 1),"viewing":true}]);
    assert!(presence(&mut stream, frame(CONV, long)).is_empty());
    assert_eq!(stream.presence_ended(), None, "nothing was shown");

    assert_eq!(
        presence(&mut stream, frame(CONV, one.clone())),
        vec![json!({"event":"cloud-conversation-presence","conversation":CONV,
                        "participants":[{"participant":"user_1","viewing":true}]})]
    );
    let ended = stream.presence_ended().map(|event| event.with_account(Some("me")));
    assert_eq!(
        ended.map(|event| event.wire_json()),
        Some(json!({"event":"cloud-conversation-presence","conversation":CONV,
                        "participants":[],"account":"me"}))
    );
    assert_eq!(stream.presence_ended(), None, "emptied once");
    // An empty set from the owner leaves nothing to empty.
    presence(&mut stream, frame(CONV, one));
    presence(&mut stream, frame(CONV, json!([])));
    assert_eq!(stream.presence_ended(), None);
}
