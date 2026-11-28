//! `HomeCoreMapping` (and `+Thread`): the local owner's wire rows as Home core rows, and Home intents
//! as the owner's ops. An optional `identity` maps the account's own id the way `CloudHomeMapping`
//! does (message authors, mentions, reactions, thread owners), so the thread and page reads serve
//! both owners.

use super::home::{
    self, AttachmentRef, DerivedImage, LinkPreview, Mention, MessagePart, PartRef, Reaction,
    ReactionKind, ThreadInfo, WireQuestion, WorkRef,
};
use super::wire::{self, Part};
use super::{DISTANT_PAST, Identity, author, parse_date, trimmed};
use crate::ops::{self, OpError};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};

/// `HomeStrings.chiefName`'s English text; the app passes its localized one.
pub const CHIEF_NAME: &str = "Chief";

/// `HomeCoreMapping.date`, `Date.distantPast` when absent or unreadable.
pub fn date_or_past(text: &str) -> f64 {
    parse_date(text).unwrap_or(DISTANT_PAST)
}

fn date_opt(text: Option<&String>) -> Option<f64> {
    text.and_then(|text| parse_date(text))
}

/// `HomeCoreMapping.participant`: the local mux is the chief.
pub fn participant(participant: &wire::Participant, chief_name: &str) -> home::Participant {
    let is_agent = participant.kind == "agent";
    let is_chief = is_agent && participant.agent_class.as_deref() == Some("mux");
    home::Participant::new(
        participant.id.clone(),
        if is_agent { "agent" } else { "human" },
        if is_chief { chief_name.to_string() } else { participant.display_name.clone() },
        is_agent.then_some(if is_chief { "chief" } else { "agent" }),
    )
}

fn derived(image: &wire::DerivedImage) -> DerivedImage {
    DerivedImage {
        hash: image.hash.clone(),
        mime_type: image.mime_type.clone(),
        byte_count: image.byte_count,
    }
}

fn wire_derived(image: &DerivedImage) -> wire::DerivedImage {
    wire::DerivedImage {
        hash: image.hash.clone(),
        mime_type: image.mime_type.clone(),
        byte_count: image.byte_count,
    }
}

/// `HomeCoreMapping.ref(_:)`: the owner's attachment as a Home ref (same fields).
pub fn attachment_ref(attachment: &wire::Attachment) -> AttachmentRef {
    AttachmentRef {
        hash: attachment.hash.clone(),
        name: attachment.name.clone(),
        mime_type: attachment.mime_type.clone(),
        byte_count: attachment.byte_count,
        width: attachment.width,
        height: attachment.height,
        duration_ms: attachment.duration_ms,
        poster: attachment.poster.as_ref().map(derived),
        preview: attachment.preview.as_ref().map(derived),
    }
}

/// `HomeCoreMapping.attachment(_:)`: a Home ref as the owner's attachment.
pub fn wire_attachment(attachment: &AttachmentRef) -> wire::Attachment {
    wire::Attachment {
        hash: attachment.hash.clone(),
        name: attachment.name.clone(),
        mime_type: attachment.mime_type.clone(),
        byte_count: attachment.byte_count,
        width: attachment.width,
        height: attachment.height,
        duration_ms: attachment.duration_ms,
        poster: attachment.poster.as_ref().map(wire_derived),
        preview: attachment.preview.as_ref().map(wire_derived),
    }
}

/// `HomeCoreMapping.ref(_:storedAs:)`: the owner keeps the first record of a hash, so its type, size
/// and derived images win.
pub fn ref_stored_as(attachment: &AttachmentRef, stored: &wire::StoredAttachment) -> AttachmentRef {
    AttachmentRef {
        mime_type: stored.mime_type.clone(),
        byte_count: stored.byte_count,
        poster: stored.poster.as_ref().map(derived),
        preview: stored.preview.as_ref().map(derived),
        ..attachment.clone()
    }
}

/// A part as Home's, and the owner's question payload when it is one (Swift builds that).
pub fn part(part: &Part) -> (MessagePart, Option<Value>) {
    let mapped = match part {
        Part::Text { text, runs } => MessagePart::Text {
            text: text.clone(),
            mentions: runs
                .iter()
                .filter_map(|run| {
                    run.mention.as_ref().map(|participant| Mention {
                        start: run.start,
                        length: run.length,
                        participant: participant.clone(),
                    })
                })
                .collect(),
        },
        Part::Work { session, host, status, preview } => MessagePart::Work {
            work: WorkRef {
                session: session.clone(),
                host: host.clone(),
                title: session.clone(),
                status: if ["running", "waiting", "done", "failed"].contains(&status.as_str()) {
                    status.clone()
                } else {
                    "running".into()
                },
                preview: preview.clone(),
            },
        },
        Part::Attachment(attachment) => {
            MessagePart::Attachment { attachment: attachment_ref(attachment) }
        }
        Part::LinkPreview(link) => MessagePart::LinkPreview {
            link: LinkPreview {
                url: link.url.clone(),
                title: link.title.clone(),
                site: link.site.clone(),
                image: link.image.as_ref().map(derived),
            },
        },
        Part::Unknown { kind, payload } if kind == "question" => {
            return (MessagePart::text("question"), Some(payload.clone()));
        }
        Part::Unknown { kind, payload } if kind == "widget" => match payload.get("fallback") {
            // Chat widgets are gone; an older build's stored one shows its fallback text.
            Some(Value::String(fallback)) if !fallback.is_empty() => {
                MessagePart::text(fallback.clone())
            }
            _ => MessagePart::text(part.plain_text()),
        },
        Part::Unknown { .. } => MessagePart::text(part.plain_text()),
    };
    (mapped, None)
}

/// `HomeCoreMapping.reaction`: a tapback this build does not know reads as an emoji.
pub fn reaction(reaction: &wire::Reaction, identity: Option<&Identity>) -> Reaction {
    let kind = match &reaction.kind {
        wire::ReactionKind::Tapback(value) if TAPBACK_SET.contains(&value.as_str()) => {
            ReactionKind::Tapback { tapback: value.clone() }
        }
        wire::ReactionKind::Tapback(value) | wire::ReactionKind::Emoji(value) => {
            ReactionKind::Emoji { emoji: value.clone() }
        }
    };
    Reaction { author: author(identity, &reaction.author), part_index: reaction.part_index, kind }
}

const TAPBACK_SET: &[&str] = home::TAPBACKS;

/// `HomeCoreMapping.thread(_ wire: ConversationThreadObject?)`.
pub fn thread_info(
    thread: Option<&wire::ThreadObject>,
    identity: Option<&Identity>,
) -> Option<ThreadInfo> {
    let thread = thread?;
    Some(ThreadInfo {
        title: thread.title.clone(),
        owner: thread.owner.as_ref().map(|owner| author(identity, owner)),
        resolved_at_seq: thread.resolved.as_ref().and_then(|resolved| resolved.seq),
        resolved_by: thread.resolved.as_ref().map(|resolved| author(identity, &resolved.by)),
    })
}

/// `HomeCoreMapping.message`, and with an identity `CloudHomeMapping.message` (the account's id as
/// Home's in the author, mentions, reactions and thread).
pub fn message(message: &wire::Message, identity: Option<&Identity>) -> home::Message {
    let mut questions = Vec::new();
    let parts = message
        .parts
        .iter()
        .enumerate()
        .map(|(index, wire_part)| {
            let (mut mapped, question) = part(wire_part);
            if let Some(payload) = question {
                questions.push(WireQuestion { part_index: index, payload });
            }
            if let (Some(identity), MessagePart::Text { mentions, .. }) = (identity, &mut mapped) {
                for mention in mentions {
                    mention.participant = identity.to_home(&mention.participant);
                }
            }
            mapped
        })
        .collect();
    home::Message {
        id: message.id.clone(),
        conversation: message.conversation.clone(),
        seq: message.seq,
        client_message_id: message.client_msg_id.clone(),
        author: author(identity, &message.author),
        parts,
        created_at: date_or_past(&message.created_at),
        edited_at: date_opt(message.edited_at.as_ref()),
        retracted_at: date_opt(message.retracted_at.as_ref()),
        reactions: message.reactions.iter().map(|r| reaction(r, identity)).collect(),
        reply_to: message.reply_to.as_ref().map(|reply| PartRef {
            message: reply.message_id.clone(),
            part_index: reply.part_index,
        }),
        // A message from before threads marked its thread as a reply to the root.
        thread_root: message
            .thread_root
            .clone()
            .or_else(|| message.reply_to.as_ref().map(|reply| reply.message_id.clone())),
        thread: thread_info(message.thread.as_ref(), identity),
        wire_questions: questions,
    }
}

/// `HomeCoreMapping.summary`: a local head.
pub fn summary(summary: &wire::Summary, chief_name: &str) -> home::Summary {
    home::Summary {
        id: summary.id.clone(),
        owner: if summary.owner == "cloud" { "cloud" } else { "local" }.into(),
        title: summary.title.clone(),
        participants: summary.participants.iter().map(|p| participant(p, chief_name)).collect(),
        last_seq: summary.last_seq,
        rev: summary.rev,
        created_at: date_or_past(&summary.created_at),
        updated_at: date_or_past(&summary.updated_at),
        last_message: summary.last_message.as_ref().map(|m| message(m, None)),
        read_cursors: summary.read_cursors.iter().map(|(k, v)| (k.clone(), *v)).collect(),
        read_cursor_times: Vec::new(),
        pin_rank: None,
        muted: false,
        mention_count: 0,
        declared_kind: None,
        member_count: None,
        chief_replies: None,
        channel_chief: None,
    }
}

/// `HomeCoreMapping.thread(_ summary: ConversationThreadSummary, author:)`.
pub fn thread(summary: &wire::ThreadSummary, identity: Option<&Identity>) -> home::ThreadSummary {
    home::ThreadSummary {
        root: summary.root.clone(),
        reply_count: summary.reply_count,
        last_reply_seq: summary.last_reply_seq,
        last_reply_at: date_opt(summary.last_reply_at.as_ref()),
        authors: summary.authors.iter().map(|id| author(identity, id)).collect(),
    }
}

/// `HomeCoreMapping.threadPage`.
pub fn thread_page(page: &wire::ThreadPage, identity: Option<&Identity>) -> home::ThreadPage {
    home::ThreadPage {
        root: message(&page.root, identity),
        replies: page.replies.iter().map(|m| message(m, identity)).collect(),
        has_more: page.has_more,
        summary: thread(&page.thread, identity),
    }
}

/// `Location`'s `plainText` without its label: Swift's `"\(latitude), \(longitude)"`.
fn location_text(location: &Value) -> String {
    if let Some(label) = location.get("label").and_then(Value::as_str) {
        return label.to_string();
    }
    let number = |key: &str| location.get(key).and_then(Value::as_f64).unwrap_or(0.0);
    format!("{:?}, {:?}", number("latitude"), number("longitude"))
}

/// `HomeCoreMapping.parts`: the parts an op sends. The local owner stores text, work, attachment and
/// link preview parts; approval, location and question go as their text (`plain_texts[i]` when the
/// caller gives it: a question's transcript text is the Home core's).
pub fn wire_parts(parts: &[MessagePart], plain_texts: &[Option<String>]) -> Vec<Part> {
    parts
        .iter()
        .enumerate()
        .map(|(index, part)| {
            let given = || plain_texts.get(index).cloned().flatten();
            match part {
                MessagePart::Text { text, mentions } => Part::Text {
                    text: text.clone(),
                    runs: mentions
                        .iter()
                        .map(|m| wire::TextRun {
                            start: m.start,
                            length: m.length,
                            mention: Some(m.participant.clone()),
                            link: None,
                        })
                        .collect(),
                },
                MessagePart::Work { work } => Part::Work {
                    session: work.session.clone(),
                    host: work.host.clone(),
                    status: work.status.clone(),
                    preview: work.preview.clone(),
                },
                MessagePart::Attachment { attachment } => {
                    Part::Attachment(wire_attachment(attachment))
                }
                MessagePart::LinkPreview { link } => Part::LinkPreview(wire::LinkPreview {
                    url: link.url.clone(),
                    title: link.title.clone(),
                    site: link.site.clone(),
                    image: link.image.as_ref().map(wire_derived),
                }),
                MessagePart::Approval { approval } => Part::Text {
                    text: given().unwrap_or_else(|| {
                        approval
                            .get("prompt")
                            .and_then(Value::as_str)
                            .unwrap_or_default()
                            .to_string()
                    }),
                    runs: Vec::new(),
                },
                MessagePart::Location { location } => Part::Text {
                    text: given().unwrap_or_else(|| location_text(location)),
                    runs: Vec::new(),
                },
                MessagePart::Question { .. } => Part::Text {
                    text: given().unwrap_or_else(|| "question".into()),
                    runs: Vec::new(),
                },
            }
        })
        .collect()
}

/// A Home intent (`HomeOp`, not `Codable` in Swift): its case name and the fields it carries.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HomeOp {
    pub kind: String,
    #[serde(default)]
    pub conversation: String,
    #[serde(default)]
    pub message: String,
    #[serde(default)]
    pub parts: Vec<MessagePart>,
    #[serde(default)]
    pub plain_texts: Vec<Option<String>>,
    #[serde(default)]
    pub thread_root: Option<String>,
    #[serde(default)]
    pub parent: Option<String>,
    #[serde(default)]
    pub seq: u64,
    #[serde(default)]
    pub reaction: Option<ReactionKind>,
    #[serde(default)]
    pub part_index: i64,
    /// `answer.conversationAnswer` as JSON (Swift encodes it).
    #[serde(default)]
    pub answer: Option<Value>,
    #[serde(default)]
    pub root: String,
    #[serde(default)]
    pub title: Option<String>,
    #[serde(default)]
    pub status: Option<String>,
    #[serde(default)]
    pub owner: Option<String>,
}

fn reaction_kind(kind: &ReactionKind) -> Value {
    match kind {
        ReactionKind::Tapback { tapback } => json!({ "tapback": tapback }),
        ReactionKind::Emoji { emoji } => json!({ "emoji": emoji }),
    }
}

/// `HomeCoreMapping.op`: the owner op of an intent (`ConversationOp`'s encoding), or None when the
/// local owner has no such op. `key` is the intent's idempotency key.
pub fn op(op: &HomeOp, key: &str) -> Option<(String, Value)> {
    let parts =
        || serde_json::to_value(wire_parts(&op.parts, &op.plain_texts)).unwrap_or(Value::Null);
    let mut body = Map::new();
    let kind = match op.kind.as_str() {
        "sendMessage" => {
            body.insert("client_msg_id".into(), key.into());
            body.insert("parts".into(), parts());
            // `thread_root` is the thread; `reply_to` the message answered (the root without a parent),
            // which also keeps the thread on a daemon from before threads.
            if let Some(root) = &op.thread_root {
                let answered = op.parent.clone().unwrap_or_else(|| root.clone());
                body.insert("reply_to".into(), json!({ "message_id": answered, "part_index": 0 }));
                body.insert("thread_root".into(), root.clone().into());
            }
            "message.send"
        }
        "editMessage" => {
            body.insert("message_id".into(), op.message.clone().into());
            body.insert("parts".into(), parts());
            "message.edit"
        }
        "retractMessage" => {
            body.insert("message_id".into(), op.message.clone().into());
            "message.retract"
        }
        "setReadCursor" => {
            body.insert("seq".into(), op.seq.into());
            "read_cursor.set"
        }
        "addReaction" | "removeReaction" => {
            body.insert("message_id".into(), op.message.clone().into());
            body.insert("part_index".into(), op.part_index.into());
            body.insert("reaction".into(), reaction_kind(op.reaction.as_ref()?));
            if op.kind == "addReaction" { "reaction.add" } else { "reaction.remove" }
        }
        "answerQuestion" => {
            body.insert("message_id".into(), op.message.clone().into());
            body.insert("part_index".into(), op.part_index.into());
            body.insert("answer".into(), op.answer.clone()?);
            "question.answer"
        }
        "updateThread" => {
            body.insert("root".into(), op.root.clone().into());
            for (key, value) in [("title", &op.title), ("status", &op.status), ("owner", &op.owner)]
            {
                if let Some(value) = value {
                    body.insert(key.into(), value.clone().into());
                }
            }
            "thread.update"
        }
        "renameConversation" => {
            body.insert("title".into(), trimmed(op.title.as_deref().unwrap_or_default()).into());
            "title.set"
        }
        // createGroup, createChief, startConversation, invite, openDirect, setPinned, setMuted,
        // setTyping, addParticipants, removeParticipant, setChiefReplies: no local owner op.
        _ => return None,
    };
    let mut encoded = Map::new();
    encoded.insert("kind".into(), kind.into());
    encoded.extend(body);
    Some((op.conversation.clone(), Value::Object(encoded)))
}

// MARK: ops

fn chief_name(name: &Option<String>) -> &str {
    name.as_deref().unwrap_or(CHIEF_NAME)
}

#[derive(Deserialize)]
struct DateRequest {
    #[serde(default)]
    text: Option<String>,
}

#[derive(Serialize)]
struct DateReply {
    date: Option<f64>,
}

/// `mapping.date {text?}` → `{date}` (seconds since 1970, null when it does not parse).
pub fn date_op(request: &Value) -> Result<Value, OpError> {
    let request: DateRequest = ops::parse(request)?;
    ops::reply(&DateReply { date: request.text.as_deref().and_then(parse_date) })
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ParticipantRequest {
    participant: wire::Participant,
    #[serde(default)]
    chief_name: Option<String>,
}

#[derive(Serialize)]
struct ParticipantReply {
    participant: home::Participant,
}

/// `mapping.participant {participant, chiefName?}` → `{participant}`.
pub fn participant_op(request: &Value) -> Result<Value, OpError> {
    let request: ParticipantRequest = ops::parse(request)?;
    ops::reply(&ParticipantReply {
        participant: participant(&request.participant, chief_name(&request.chief_name)),
    })
}

#[derive(Deserialize)]
struct PartRequest {
    part: Part,
}

#[derive(Serialize)]
struct PartReply {
    part: MessagePart,
    #[serde(skip_serializing_if = "Option::is_none")]
    question: Option<Value>,
}

/// `mapping.part {part}` → `{part, question?}`.
pub fn part_op(request: &Value) -> Result<Value, OpError> {
    let request: PartRequest = ops::parse(request)?;
    let (part, question) = part(&request.part);
    ops::reply(&PartReply { part, question })
}

#[derive(Deserialize)]
struct MessageRequest {
    message: wire::Message,
    #[serde(default)]
    identity: Option<Identity>,
}

#[derive(Serialize)]
struct MessageReply {
    message: home::Message,
}

/// `mapping.message {message, identity?}` → `{message}`.
pub fn message_op(request: &Value) -> Result<Value, OpError> {
    let request: MessageRequest = ops::parse(request)?;
    ops::reply(&MessageReply { message: message(&request.message, request.identity.as_ref()) })
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct SummaryRequest {
    summary: wire::Summary,
    #[serde(default)]
    chief_name: Option<String>,
}

#[derive(Serialize)]
struct SummaryReply {
    summary: home::Summary,
}

/// `mapping.summary {summary, chiefName?}` → `{summary}`.
pub fn summary_op(request: &Value) -> Result<Value, OpError> {
    ops::reply(&summary_reply(ops::parse(request)?)?)
}

fn summary_reply(request: SummaryRequest) -> Result<SummaryReply, OpError> {
    Ok(SummaryReply { summary: summary(&request.summary, chief_name(&request.chief_name)) })
}

#[derive(Deserialize)]
struct ThreadRequest {
    summary: wire::ThreadSummary,
    #[serde(default)]
    identity: Option<Identity>,
}

#[derive(Serialize)]
struct ThreadReply {
    thread: home::ThreadSummary,
}

/// `mapping.thread {summary, identity?}` → `{thread}`.
pub fn thread_op(request: &Value) -> Result<Value, OpError> {
    let request: ThreadRequest = ops::parse(request)?;
    ops::reply(&ThreadReply { thread: thread(&request.summary, request.identity.as_ref()) })
}

#[derive(Deserialize)]
struct ThreadPageRequest {
    page: wire::ThreadPage,
    #[serde(default)]
    identity: Option<Identity>,
}

/// `mapping.threadPage {page, identity?}` → `{root, replies, hasMore, summary}`.
pub fn thread_page_op(request: &Value) -> Result<Value, OpError> {
    ops::reply(&thread_page_reply(ops::parse(request)?)?)
}

fn thread_page_reply(request: ThreadPageRequest) -> Result<home::ThreadPage, OpError> {
    Ok(thread_page(&request.page, request.identity.as_ref()))
}

/// `ConversationSnapshot` and `ConversationHistoryPage` as the daemon sends them.
#[derive(Deserialize)]
struct WirePage {
    #[serde(default)]
    conversation: Option<wire::Summary>,
    #[serde(default)]
    messages: Vec<wire::Message>,
    #[serde(default)]
    threads: Vec<wire::ThreadSummary>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct PageRequest {
    page: WirePage,
    #[serde(default)]
    identity: Option<Identity>,
    #[serde(default)]
    chief_name: Option<String>,
}

/// `mapping.conversationPage {page: {conversation, messages, threads}, chiefName?}` →
/// `{conversation, messages, threads}` (`DaemonHomeSource.snapshot`).
pub fn conversation_page_op(request: &Value) -> Result<Value, OpError> {
    ops::reply(&conversation_page_reply(ops::parse(request)?)?)
}

fn conversation_page_reply(request: PageRequest) -> Result<home::ConversationPage, OpError> {
    let identity = request.identity.as_ref();
    let Some(head) = request.page.conversation.as_ref() else {
        return Err(OpError::Invalid("page.conversation is required".into()));
    };
    Ok(home::ConversationPage {
        conversation: summary(head, chief_name(&request.chief_name)),
        messages: request.page.messages.iter().map(|m| message(m, identity)).collect(),
        threads: request.page.threads.iter().map(|t| thread(t, identity)).collect(),
    })
}

/// `mapping.historyPage {page: {messages, threads}, identity?}` → `{messages, threads}`.
pub fn history_page_op(request: &Value) -> Result<Value, OpError> {
    ops::reply(&history_page_reply(ops::parse(request)?)?)
}

fn history_page_reply(request: PageRequest) -> Result<home::HistoryPage, OpError> {
    let identity = request.identity.as_ref();
    Ok(home::HistoryPage {
        messages: request.page.messages.iter().map(|m| message(m, identity)).collect(),
        threads: request.page.threads.iter().map(|t| thread(t, identity)).collect(),
    })
}

/// The ops above from request bytes to reply bytes, with no `Value` tree either way: the ops
/// the app calls per listed conversation (`summary`) or per page of messages. `None`: not one of
/// them, or a request the typed read refused (the `Value` path then answers, its error included).
pub fn call_bytes(name: &str, bytes: &[u8]) -> Option<Result<Vec<u8>, OpError>> {
    match name {
        "summary" => ops::typed_bytes(bytes, summary_reply),
        "threadPage" => ops::typed_bytes(bytes, thread_page_reply),
        "conversationPage" => ops::typed_bytes(bytes, conversation_page_reply),
        "historyPage" => ops::typed_bytes(bytes, history_page_reply),
        _ => None,
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct PartsRequest {
    parts: Vec<MessagePart>,
    #[serde(default)]
    plain_texts: Vec<Option<String>>,
}

#[derive(Serialize)]
struct PartsReply {
    parts: Vec<Part>,
}

/// `mapping.parts {parts, plainTexts?}` → `{parts}` (the owner's parts).
pub fn parts_op(request: &Value) -> Result<Value, OpError> {
    let request: PartsRequest = ops::parse(request)?;
    ops::reply(&PartsReply { parts: wire_parts(&request.parts, &request.plain_texts) })
}

#[derive(Deserialize)]
struct OpRequest {
    op: HomeOp,
    key: String,
}

#[derive(Serialize)]
struct OpReply {
    #[serde(skip_serializing_if = "Option::is_none")]
    conversation: Option<String>,
    /// null: the local owner has no such op (`unsupported_on_local_owner`).
    op: Option<Value>,
}

/// `mapping.op {op, key}` → `{conversation?, op}`.
pub fn op_op(request: &Value) -> Result<Value, OpError> {
    let request: OpRequest = ops::parse(request)?;
    let mapped = op(&request.op, &request.key);
    let (conversation, op) = match mapped {
        Some((conversation, op)) => (Some(conversation), Some(op)),
        None => (None, None),
    };
    ops::reply(&OpReply { conversation, op })
}

#[derive(Deserialize)]
struct RefStoredAsRequest {
    #[serde(rename = "ref")]
    attachment: AttachmentRef,
    stored: wire::StoredAttachment,
}

#[derive(Serialize)]
struct RefReply {
    #[serde(rename = "ref")]
    attachment: AttachmentRef,
}

/// `mapping.refStoredAs {ref, stored}` → `{ref}`.
pub fn ref_stored_as_op(request: &Value) -> Result<Value, OpError> {
    let request: RefStoredAsRequest = ops::parse(request)?;
    ops::reply(&RefReply { attachment: ref_stored_as(&request.attachment, &request.stored) })
}
