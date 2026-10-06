//! `link_preview` parts: the sender's fetched preview of a URL, validated by
//! the reducer like every other part (the owner checks `image` against its
//! attachment records separately).

use serde_json::{Value, json};

use super::*;

const ALICE: &str = "user_local";
const NOW: &str = "2026-10-01T12:00:00.000Z";
const HASH: &str = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

fn head() -> ConversationHead {
    let alice = Participant {
        id: ALICE.to_string(),
        kind: ParticipantKind::Human,
        display_name: "Alice".to_string(),
        agent_class: None,
        acp_session: None,
        person: None,
    };
    create(&CreateRequest {
        id: "conv_TEST",
        actor: ALICE,
        title: "t",
        participants: &[alice],
        now: NOW,
    })
    .unwrap()
}

fn send(part: Value) -> Result<Commit, Reject> {
    let part: Part = serde_json::from_value(part).expect("a link_preview part decodes");
    let op = Op::MessageSend { client_msg_id: "k".to_string(), parts: vec![part], reply_to: None };
    apply(
        &head(),
        &OpRequest {
            actor: ALICE,
            idempotency_key: "k",
            op: &op,
            now: NOW,
            new_message_id: "msg_00000000000000000000000001",
            target: None,
            reply_target: None,
            last_message: None,
        },
    )
}

fn preview(over: Value) -> Value {
    let mut part = json!({"type":"link_preview","url":"https://example.com/a?b=c#d",
        "title":"Example","site":"example.com",
        "image":{"hash":HASH,"mime_type":"image/jpeg","byte_count":512_000}});
    for (key, value) in over.as_object().unwrap() {
        if value.is_null() {
            part.as_object_mut().unwrap().remove(key);
        } else {
            part[key] = value.clone();
        }
    }
    part
}

#[test]
fn link_preview_part_round_trips_and_is_accepted() {
    let part = preview(json!({}));
    let commit = send(part.clone()).unwrap();
    let message = commit.message.unwrap();
    assert_eq!(serde_json::to_value(&message.parts[0]).unwrap(), part);
    // Only the URL is required; absent fields stay absent on the wire.
    let bare = json!({"type":"link_preview","url":"http://example.com"});
    let commit = send(bare.clone()).unwrap();
    assert_eq!(serde_json::to_value(&commit.message.unwrap().parts[0]).unwrap(), bare);
    assert!(send(preview(json!({"image":{"hash":HASH,"mime_type":"image/webp","byte_count":1}}))).is_ok());
    assert!(send(preview(json!({"title":"é".repeat(300),"site":"s".repeat(253)}))).is_ok());
    let longest = format!("https://example.com/{}", "a".repeat(2048 - 20));
    assert_eq!(longest.len(), 2048);
    assert!(send(preview(json!({"url":longest}))).is_ok());
}

#[test]
fn link_preview_part_refuses_bad_urls_text_and_images() {
    let too_long = format!("https://example.com/{}", "a".repeat(2048 - 19));
    let cases = [
        json!({"url":""}),
        json!({"url":too_long}),
        json!({"url":"ftp://example.com"}),
        json!({"url":"javascript:alert(1)"}),
        json!({"url":"file:///etc/passwd"}),
        json!({"url":"example.com"}),
        json!({"url":"https://"}),
        json!({"url":"https:///path"}),
        json!({"url":"https://exa mple.com"}),
        json!({"url":"https://example.com/\n"}),
        json!({"url":"https://user@example.com"}),
        json!({"url":"https:\\\\example.com"}),
        json!({"title":""}),
        json!({"title":"x".repeat(301)}),
        json!({"title":"a\u{0007}b"}),
        json!({"site":""}),
        json!({"site":"s".repeat(254)}),
        json!({"site":"a\nb"}),
        json!({"image":{"hash":"ABC","mime_type":"image/jpeg","byte_count":10}}),
        json!({"image":{"hash":HASH,"mime_type":"image/png","byte_count":10}}),
        json!({"image":{"hash":HASH,"mime_type":"image/jpeg","byte_count":0}}),
        json!({"image":{"hash":HASH,"mime_type":"image/jpeg","byte_count":512_001}}),
    ];
    for over in cases {
        assert_eq!(send(preview(over.clone())).unwrap_err(), Reject::InvalidParts, "{over}");
    }
    assert!(send(preview(json!({"url":"HTTPS://Example.com"}))).is_ok(), "the scheme is case-insensitive");
}

#[test]
fn link_preview_part_has_no_search_text_beyond_its_title() {
    let commit = send(preview(json!({}))).unwrap();
    assert_eq!(message_text(&commit.message.unwrap()), "Example");
}
