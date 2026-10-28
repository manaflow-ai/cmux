//! The lines the macOS app sends for its Conversations requests reach the owner as it
//! reads them. spec/fixtures/conversation-requests/lines.json records them
//! before their migration to the generated `<Name>Request` types;
//! ConversationsRequestWireGoldenTests (CmuxNextDaemonTests) proves the app encodes exactly
//! these lines. Here every line goes through the connection's own `Request` parse, and every
//! document field (an op, participants, imported parts, a derived image) through the decode
//! its handler runs, so a golden the daemon would refuse fails here, not in the app.
//! Chromium keeps the same idea in mojo/public/tools/bindings/ golden tests: one recorded
//! message checked on both ends.
use super::super::*;
use super::{InboxOp, decode};
use crate::cloud_conversations::{CLOUD_INBOX_OP_KINDS, InboxOpRequest};
use cmux_conversation::{Op, Part, Participant};

const FIXTURE: &str = include_str!("../../../../spec/fixtures/conversation-requests/lines.json");

/// `(name, line)` of every recorded request.
fn entries() -> Vec<(String, Value)> {
    let fixture: Value =
        serde_json::from_str(FIXTURE).expect("spec/fixtures/conversation-requests/lines.json");
    fixture["requests"]
        .as_array()
        .expect("no requests in lines.json")
        .iter()
        .map(|entry| (entry["name"].as_str().expect("name").to_owned(), entry["line"].clone()))
        .collect()
}

/// The line as the connection reads it: one JSON text through `line_parses::parse`.
fn parse(name: &str, line: &Value) -> Request {
    crate::line_parses::parse::<Request>(&line.to_string())
        .unwrap_or_else(|error| panic!("{name}: {error}"))
}

/// A part the owner could not read decodes as `Unknown` instead of failing; the app
/// must never send one.
fn assert_known_parts(name: &str, parts: &[Part]) {
    for part in parts {
        assert!(!matches!(part, Part::Unknown(_)), "{name}: unreadable part {part:?}");
    }
}

#[test]
fn every_recorded_line_parses_as_its_command() {
    let lines = entries();
    assert!(lines.len() > 40, "lines.json has {} lines", lines.len());
    for (name, line) in lines {
        let request = parse(&name, &line);
        assert_eq!(request.id, Some(json!(1)), "{name}");
        assert_eq!(Some(request.cmd.wire_name()), line["cmd"].as_str(), "{name}");
    }
}

/// The document-valued fields decode as their handler decodes them (conversations.rs,
/// conversation_attachments.rs, cloud_conversations.rs).
#[test]
fn every_document_field_decodes_as_the_owner_reads_it() {
    let mut checked = 0;
    for (name, line) in entries() {
        match parse(&name, &line).cmd {
            Command::ConversationCreate(params) => {
                let participants: Vec<Participant> = decode(params.participants, "participants")
                    .unwrap_or_else(|error| panic!("{name}: {error}"));
                assert!(!participants.is_empty(), "{name}");
            }
            Command::ConversationOp(params) => {
                let op: Op =
                    decode(params.op, "op").unwrap_or_else(|error| panic!("{name}: {error}"));
                if let Op::MessageSend { parts, .. } | Op::MessageEdit { parts, .. } = &op {
                    assert_known_parts(&name, parts);
                }
            }
            Command::ConversationInboxOp(params) => {
                let _: InboxOp =
                    decode(params.op, "op").unwrap_or_else(|error| panic!("{name}: {error}"));
            }
            Command::CloudInboxOp(params) => {
                let request = InboxOpRequest::from(params);
                let kind = request.op["kind"].as_str().unwrap_or_default();
                assert!(
                    CLOUD_INBOX_OP_KINDS.contains(&kind),
                    "{name}: {kind} is not a cloud inbox op"
                );
            }
            Command::ConversationImport(params) => {
                for message in &params.messages {
                    assert_known_parts(&name, &message.parts);
                }
            }
            Command::ConversationAttachmentUpload(params) => {
                use super::super::conversation_attachments::{derived, piece};
                derived(params.poster, "poster").unwrap_or_else(|error| panic!("{name}: {error}"));
                derived(params.preview, "preview")
                    .unwrap_or_else(|error| panic!("{name}: {error}"));
                piece(params.piece, "piece").unwrap_or_else(|error| panic!("{name}: {error}"));
            }
            Command::ConversationAttachmentRead(params) => {
                use super::super::conversation_attachments::piece;
                piece(params.variant, "variant").unwrap_or_else(|error| panic!("{name}: {error}"));
            }
            _ => continue,
        }
        checked += 1;
    }
    assert!(checked > 20, "{checked} document lines checked");
}

/// The fullest `message.send` keeps every part as the app wrote it.
#[test]
fn a_full_message_send_keeps_every_part() {
    let (name, line) = entries()
        .into_iter()
        .find(|(name, _)| name == "conversation-op message.send attachment, link preview and work")
        .expect("the full message.send golden");
    let Command::ConversationOp(params) = parse(&name, &line).cmd else {
        panic!("{name}: not a conversation-op");
    };
    assert_eq!(params.actor.as_deref(), Some("user_local"));
    let Op::MessageSend { parts, .. } = decode::<Op>(params.op, "op").expect("op") else {
        panic!("{name}: not a message.send");
    };
    assert!(
        matches!(&parts[0], Part::Attachment { preview: Some(_), width: Some(640), .. }),
        "{parts:?}"
    );
    assert!(
        matches!(&parts[1], Part::Attachment { poster: Some(_), duration_ms: Some(4500), .. }),
        "{parts:?}"
    );
    assert!(matches!(&parts[2], Part::LinkPreview { image: Some(_), .. }), "{parts:?}");
    assert!(matches!(&parts[3], Part::Work { .. }), "{parts:?}");
}
