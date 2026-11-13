//! A person's message past the owner's text limit (`MAX_TEXT_BYTES`) used to
//! be refused (`invalid_parts`) and stay "Not Delivered" for good, whatever
//! Retry did. The owner now keeps the whole text as a `text/plain` file and
//! commits a short message that names it, with its first and last lines, so
//! the agent reads the file with its tools.
use super::*;
use attachments::Piece;
use cmux_conversation::Part;

const CHIEF: &str = "agent_chief";

fn setup() -> (ConversationStore, String) {
    let mut store = ConversationStore::open(None).unwrap();
    let people: Vec<Participant> = serde_json::from_value(json!([
        {"id": LOCAL_USER, "kind": "human", "display_name": "Me"},
        {"id": CHIEF, "kind": "agent", "display_name": "Chief"}
    ]))
    .unwrap();
    let conversation = store.create("spill", LOCAL_USER, "Chief", &people).unwrap().summary.id;
    (store, conversation)
}

fn send(text: &str, key: &str) -> Op {
    Op::MessageSend {
        client_msg_id: key.into(),
        parts: vec![Part::Text { text: text.into(), runs: None }],
        reply_to: None,
        answers: Vec::new(),
        answers_pending: Vec::new(),
        thread_root: None,
    }
}

/// 4,896 lines, about 300 KB: the user's paste.
fn paste() -> String {
    (1..=4896)
        .map(|n| {
            format!("line {n:04} of the pasted log: the quick brown fox jumps over the lazy dog\n")
        })
        .collect()
}

fn last(store: &mut ConversationStore, conversation: &str) -> Message {
    store.snapshot(conversation, 10).unwrap().1.pop().unwrap()
}

#[test]
fn an_oversized_person_send_commits_as_a_file_and_a_short_prompt() {
    let (mut store, conversation) = setup();
    let text = paste();
    assert!(text.len() > cmux_conversation::MAX_TEXT_BYTES);
    let outcome = store
        .apply_op(&conversation, "send-big-1", LOCAL_USER, &send(&text, "send-big-1"))
        .unwrap();
    assert!(!outcome.replayed);
    let message = last(&mut store, &conversation);
    assert_eq!(message.client_msg_id, "send-big-1");
    let prompt = message
        .parts
        .iter()
        .find_map(|part| match part {
            Part::Text { text, .. } => Some(text.clone()),
            _ => None,
        })
        .expect("a text part");
    assert!(prompt.len() < 32 * 1024, "the prompt stays short: {} bytes", prompt.len());
    assert!(prompt.contains("Read the file with your tools and carry out the user's instructions in it; check both its start and its end."));
    assert!(prompt.contains("4,896 lines"), "{prompt}");
    assert!(prompt.contains("line 0001 of the pasted log"));
    assert!(prompt.contains("line 0040 of the pasted log"));
    assert!(!prompt.contains("line 0041 of the pasted log"));
    assert!(prompt.contains("line 4857 of the pasted log"));
    assert!(prompt.contains("line 4896 of the pasted log"));
    let (hash, name, byte_count) = message
        .parts
        .iter()
        .find_map(|part| match part {
            Part::Attachment { hash, name, mime_type, byte_count, .. }
                if mime_type == "text/plain" =>
            {
                Some((hash.clone(), name.clone(), *byte_count))
            }
            _ => None,
        })
        .expect("a text/plain attachment");
    assert!(name.ends_with(".txt"));
    assert!(prompt.contains(&name), "the prompt names the file");
    assert_eq!(byte_count, text.len() as u64);
    // The agent reads the whole text back.
    let mut read = Vec::new();
    loop {
        let reply = store
            .attachment_read(
                CHIEF,
                &conversation,
                &hash,
                Piece::Original,
                read.len() as u64,
                64 * 1024,
            )
            .unwrap();
        read.extend_from_slice(&reply.data);
        if reply.eof {
            break;
        }
    }
    assert_eq!(String::from_utf8(read).unwrap(), text);
}

#[test]
fn a_retry_of_the_oversized_send_replays_it() {
    let (mut store, conversation) = setup();
    let text = paste();
    let op = send(&text, "send-big-2");
    let first = store.apply_op(&conversation, "send-big-2", LOCAL_USER, &op).unwrap();
    let again = store.apply_op(&conversation, "send-big-2", LOCAL_USER, &op).unwrap();
    assert!(again.replayed);
    assert_eq!(first.result, again.result);
    assert_eq!(store.snapshot(&conversation, 10).unwrap().1.len(), 1);
}

#[test]
fn a_short_send_is_unchanged() {
    let (mut store, conversation) = setup();
    store.apply_op(&conversation, "send-short", LOCAL_USER, &send("hello", "send-short")).unwrap();
    let message = last(&mut store, &conversation);
    assert_eq!(message.parts, vec![Part::Text { text: "hello".into(), runs: None }]);
}

#[test]
fn an_agents_oversized_send_is_still_refused() {
    let (mut store, conversation) = setup();
    let error = store
        .apply_op(&conversation, "send-agent", CHIEF, &send(&paste(), "send-agent"))
        .unwrap_err();
    assert_eq!(
        error.downcast_ref::<ConversationRejected>().map(|r| r.0),
        Some(Reject::InvalidParts)
    );
}
