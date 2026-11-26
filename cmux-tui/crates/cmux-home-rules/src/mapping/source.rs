//! The decisions of `DaemonHomeSource` (what a conversation event publishes, the read limits, search
//! hits, refusals) and `HomeConversationSession` as `step(state, event) -> (state, effects)`. The
//! reads, sockets, the mirror's rows and the intent log stay in Swift; these ops decide around them.

use super::core::{self, CHIEF_NAME};
use super::home::{self, MessagePart};
use super::wire;
use super::{DISTANT_PAST, parse_date};
use crate::ops::{self, OpError};
use serde::{Deserialize, Serialize};
use serde_json::Value;

// MARK: DaemonHomeSource.publish(_:summary:)

/// `ConversationChange` (the change's kind and the rows it carries).
#[derive(Debug, Clone, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum Change {
    Message {
        message: wire::Message,
    },
    MessageUpdated {
        message: wire::Message,
    },
    Conversation {
        head: Box<wire::Summary>,
    },
    ReadCursor,
    #[serde(other)]
    Unknown,
}

/// A conversation event: `rev` and its change.
#[derive(Debug, Clone, Deserialize)]
pub struct Event {
    pub rev: u64,
    pub change: Change,
}

/// A Home event the source publishes.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum Publish {
    Message {
        message: Box<home::Message>,
        rev: u64,
    },
    /// `conversationChanged(summary, stream: .conversation(summary.id), rev:)`.
    ConversationChanged {
        summary: Box<home::Summary>,
        rev: u64,
    },
}

/// What one event publishes, and whether the source reads its inbox again (a conversation it has no
/// head for: without that read Home never learns it, cx-ebm.55).
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Published {
    pub publish: Vec<Publish>,
    pub reread_inbox: bool,
}

/// `DaemonHomeSource.publish(_ event:summary:)`; `summary` is the head the daemon sent with it.
pub fn conversation_event(
    event: &Event,
    summary: Option<&wire::Summary>,
    chief_name: &str,
) -> Published {
    let changed = |head: &wire::Summary| Publish::ConversationChanged {
        summary: Box::new(core::summary(head, chief_name)),
        rev: event.rev,
    };
    let mut publish = Vec::new();
    match &event.change {
        Change::Message { message } | Change::MessageUpdated { message } => {
            publish.push(Publish::Message {
                message: Box::new(core::message(message, None)),
                rev: event.rev,
            });
        }
        Change::Conversation { head } => {
            return Published { publish: vec![changed(head)], reread_inbox: summary.is_none() };
        }
        Change::ReadCursor | Change::Unknown => {}
    }
    match summary {
        Some(head) => {
            publish.push(changed(head));
            Published { publish, reread_inbox: false }
        }
        None => Published { publish, reread_inbox: true },
    }
}

// MARK: limits, search, refusals

/// The read sizes the source sends: snapshot tail and history pages `1...500`, search `1...100`.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Limits {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tail: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub limit: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub search_limit: Option<i64>,
}

/// Clamps each given limit.
pub fn request_limits(limits: &Limits) -> Limits {
    Limits {
        tail: limits.tail.map(|n| n.clamp(1, 500)),
        limit: limits.limit.map(|n| n.clamp(1, 500)),
        search_limit: limits.search_limit.map(|n| n.clamp(1, 100)),
    }
}

/// `ConversationSearchRequest.Hit`.
#[derive(Debug, Clone, Deserialize)]
pub struct SearchHit {
    pub conversation: String,
    #[serde(default)]
    pub title: String,
    pub seq: u64,
    pub message_id: String,
    pub author: String,
    #[serde(default)]
    pub created_at: String,
    #[serde(default)]
    pub snippet: String,
}

/// `HomeSearchHit` (not `Codable` in Swift).
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct HomeSearchHit {
    pub conversation: String,
    pub message: home::Message,
    pub highlights: Vec<Value>,
}

/// `DaemonHomeSource.search`'s mapping: the hit as a message whose one part is its snippet.
pub fn search_hit(hit: &SearchHit) -> HomeSearchHit {
    HomeSearchHit {
        conversation: hit.conversation.clone(),
        message: home::Message {
            id: hit.message_id.clone(),
            conversation: hit.conversation.clone(),
            seq: hit.seq,
            client_message_id: hit.message_id.clone(),
            author: hit.author.clone(),
            parts: vec![MessagePart::text(hit.snippet.clone())],
            created_at: parse_date(&hit.created_at).unwrap_or(DISTANT_PAST),
            edited_at: None,
            retracted_at: None,
            reactions: Vec::new(),
            reply_to: None,
            thread_root: None,
            thread: None,
            wire_questions: Vec::new(),
        },
        highlights: Vec::new(),
    }
}

/// An error a daemon read or op threw, as Swift names it.
#[derive(Debug, Clone, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum Failure {
    /// Already a `HomeRejection`: it passes through.
    Rejection { rejection: Value },
    /// `DaemonError.command`.
    Command {
        #[serde(default)]
        code: Option<String>,
        #[serde(default)]
        message: String,
    },
    /// `DaemonError.notConnected`.
    NotConnected,
    #[serde(other)]
    Other,
}

/// `DaemonHomeSource.mapped`: a reject is final, a lost connection leaves the outcome open (the store
/// resends the same key). The reply is `HomeRejection`: `{kind: invalid, message}`,
/// `{kind: ownerUnreachable}` or `{kind: indeterminate}`.
pub fn rejection(failure: &Failure) -> Value {
    match failure {
        Failure::Rejection { rejection } => rejection.clone(),
        Failure::Command { code: Some(code), message }
            if code == "conversation_rejected" || code == "attachment_rejected" =>
        {
            serde_json::json!({ "kind": "invalid", "message": message })
        }
        Failure::NotConnected => serde_json::json!({ "kind": "ownerUnreachable" }),
        Failure::Command { .. } | Failure::Other => serde_json::json!({ "kind": "indeterminate" }),
    }
}

// MARK: HomeConversationSession

/// What a session keeps that its decisions read: the mirror's revision (None: no mirror yet), the
/// read in flight, the events buffered while it runs, and who is typing.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Session {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mirror_rev: Option<u64>,
    #[serde(default)]
    pub loading: bool,
    #[serde(default)]
    pub buffered: Vec<Value>,
    #[serde(default)]
    pub typing: Vec<String>,
}

/// The most events a session buffers while its snapshot read runs.
pub const BUFFER_LIMIT: usize = 1024;

/// A session input.
#[derive(Debug, Clone, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum SessionEvent {
    /// `load`: a snapshot read starts.
    Load,
    /// The snapshot read answered at `rev`.
    Loaded {
        rev: u64,
    },
    LoadFailed,
    /// A conversation event (`{rev, change: {kind, ...}}`), buffered as given.
    Event {
        event: Value,
    },
    SetTyping {
        participant: String,
        on: bool,
    },
}

/// What Swift does next.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum Effect {
    /// `mirror = ConversationMirror(snapshot:)` or `mirror.reset(snapshot)`.
    AdoptSnapshot,
    /// Apply this event to the mirror (its revision is the next one).
    ApplyToMirror {
        event: Value,
    },
    /// `log.settle(against: mirror)`; emit `pendingChanged` when it settled any.
    Settle,
    /// Emit `appended([message])` / `updated(message)` for an applied event.
    Appended {
        event: Value,
    },
    Updated {
        event: Value,
    },
    Reset,
    Typing {
        participants: Vec<String>,
    },
    /// Run the caller's `resend`.
    Resend,
    /// Log the failed read.
    LogFailure,
}

/// The step's answer: the new state, the effects in order, and `apply`'s return (false: a gap,
/// the caller reloads).
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Stepped {
    pub state: Session,
    pub effects: Vec<Effect>,
    pub accepted: bool,
}

fn event_rev(event: &Value) -> u64 {
    event.get("rev").and_then(Value::as_u64).unwrap_or(0)
}

fn change_kind(event: &Value) -> Option<&str> {
    event.get("change").and_then(|c| c.get("kind")).and_then(Value::as_str)
}

/// `ConversationMirror.apply`'s revision rule, on a session with a mirror.
fn apply_event(state: &mut Session, event: Value, effects: &mut Vec<Effect>) -> bool {
    let Some(rev) = state.mirror_rev else {
        return true;
    };
    let at = event_rev(&event);
    if at <= rev {
        return true; // stale
    }
    if at != rev + 1 {
        return false; // gap
    }
    state.mirror_rev = Some(at);
    let kind = change_kind(&event).map(str::to_string);
    effects.push(Effect::ApplyToMirror { event: event.clone() });
    effects.push(Effect::Settle);
    match kind.as_deref() {
        Some("message") => effects.push(Effect::Appended { event }),
        Some("messageUpdated") => effects.push(Effect::Updated { event }),
        _ => {}
    }
    true
}

/// `HomeConversationSession`'s `load`, its reply, `apply` and `setTyping`.
pub fn session_step(mut state: Session, event: SessionEvent) -> Stepped {
    let mut effects = Vec::new();
    let mut accepted = true;
    match event {
        SessionEvent::Load => state.loading = true,
        SessionEvent::Loaded { rev } => {
            state.loading = false;
            // Never move back to an older revision than the mirror already has.
            if state.mirror_rev.is_none_or(|current| current <= rev) {
                state.mirror_rev = Some(rev);
                state.typing.clear();
                effects.push(Effect::AdoptSnapshot);
            }
            let pending = std::mem::take(&mut state.buffered);
            for event in pending {
                if event_rev(&event) > state.mirror_rev.unwrap_or(0) {
                    apply_event(&mut state, event, &mut effects);
                }
            }
            if state.mirror_rev.is_some() {
                effects.push(Effect::Settle);
            }
            effects.push(Effect::Reset);
            effects.push(Effect::Resend);
        }
        SessionEvent::LoadFailed => {
            state.loading = false;
            state.buffered.clear();
            effects.push(Effect::LogFailure);
        }
        SessionEvent::Event { event } => {
            if state.loading || state.mirror_rev.is_none() {
                if state.buffered.len() < BUFFER_LIMIT {
                    state.buffered.push(event);
                }
            } else {
                accepted = apply_event(&mut state, event, &mut effects);
            }
        }
        SessionEvent::SetTyping { participant, on } => {
            let before = state.typing.clone();
            if on {
                if !state.typing.contains(&participant) {
                    state.typing.push(participant);
                    state.typing.sort();
                }
            } else {
                state.typing.retain(|p| *p != participant);
            }
            if state.typing != before {
                effects.push(Effect::Typing { participants: state.typing.clone() });
            }
        }
    }
    Stepped { state, effects, accepted }
}

// MARK: ops

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct EventRequest {
    event: Event,
    #[serde(default)]
    summary: Option<wire::Summary>,
    #[serde(default)]
    chief_name: Option<String>,
}

/// `mapping.conversationEvent {event: {rev, change}, summary?, chiefName?}` → `{publish, rereadInbox}`.
pub fn conversation_event_op(request: &Value) -> Result<Value, OpError> {
    let request: EventRequest = ops::parse(request)?;
    let chief = request.chief_name.as_deref().unwrap_or(CHIEF_NAME);
    ops::reply(&conversation_event(&request.event, request.summary.as_ref(), chief))
}

#[derive(Deserialize)]
struct RejectionRequest {
    error: Failure,
}

#[derive(Serialize)]
struct RejectionReply {
    rejection: Value,
}

/// `mapping.rejection {error}` → `{rejection}`.
pub fn rejection_op(request: &Value) -> Result<Value, OpError> {
    let request: RejectionRequest = ops::parse(request)?;
    ops::reply(&RejectionReply { rejection: rejection(&request.error) })
}

/// `mapping.requestLimits {tail?, limit?, searchLimit?}` → the same, clamped.
pub fn request_limits_op(request: &Value) -> Result<Value, OpError> {
    let request: Limits = ops::parse(request)?;
    ops::reply(&request_limits(&request))
}

#[derive(Deserialize)]
struct HitsRequest {
    #[serde(default)]
    hits: Vec<SearchHit>,
}

#[derive(Serialize)]
struct HitsReply {
    hits: Vec<HomeSearchHit>,
}

/// `mapping.searchHits {hits}` → `{hits}`.
pub fn search_hits_op(request: &Value) -> Result<Value, OpError> {
    let request: HitsRequest = ops::parse(request)?;
    ops::reply(&HitsReply { hits: request.hits.iter().map(search_hit).collect() })
}

#[derive(Deserialize)]
struct StepRequest {
    #[serde(default)]
    state: Session,
    event: SessionEvent,
}

/// `mapping.sessionStep {state, event}` → `{state, effects, accepted}`.
pub fn session_step_op(request: &Value) -> Result<Value, OpError> {
    let request: StepRequest = ops::parse(request)?;
    ops::reply(&session_step(request.state, request.event))
}
