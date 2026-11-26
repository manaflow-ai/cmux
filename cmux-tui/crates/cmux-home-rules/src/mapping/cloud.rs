//! `CloudHomeMapping` and the decisions of `CloudHomeState`: the cloud owners' rows (through the
//! daemon) as Home rows, with the account's own id as Home's (`CloudIdentity`), and the inbox
//! projection the cloud source lists.
//!
//! Heads (Home `ConversationSummary` as Swift encodes it) come in and go out as JSON objects: the
//! inbox fields are patched in place, so every field Swift keeps survives the round trip.

use super::core;
use super::home::{self, MessagePart};
use super::wire::{self, InboxEntry};
use super::{DISTANT_PAST, Identity, parse_date, sha256};
use crate::ops::{self, OpError};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};
use std::collections::{BTreeMap, BTreeSet};

/// `CloudIdentity.cloudID`: `user_` once.
pub fn cloud_id(stack_user_id: &str) -> String {
    if stack_user_id.starts_with("user_") {
        stack_user_id.to_string()
    } else {
        format!("user_{stack_user_id}")
    }
}

/// `CloudIdentity.workerUserID` (backend `userIdFor`).
pub fn worker_user_id(stack_project_id: &str, stack_user_id: &str) -> String {
    let hex = sha256::hex(format!("stack:{stack_project_id}:{stack_user_id}").as_bytes());
    format!("user_{}", hex.get(..20).unwrap_or(&hex))
}

/// `CloudIdentity.workerTeamID` (the API's `stackTeamIdFor`).
pub fn worker_team_id(stack_project_id: &str, stack_team_id: &str) -> String {
    let hex = sha256::hex(
        format!("stack-team:{stack_project_id}:{}", stack_team_id.to_lowercase()).as_bytes(),
    );
    format!("team_{}", hex.get(..20).unwrap_or(&hex))
}

/// `CloudIdentity.init`.
pub fn identity(
    stack_user_id: &str,
    display_name: &str,
    local_id: &str,
    stack_project_id: Option<&str>,
) -> Identity {
    let cloud = cloud_id(stack_user_id);
    Identity {
        participant_id: stack_project_id
            .map_or_else(|| cloud.clone(), |p| worker_user_id(p, stack_user_id)),
        cloud_id: cloud,
        local_id: local_id.to_string(),
        display_name: display_name.to_string(),
    }
}

const ROLES: &[&str] = &["owner", "admin", "member", "read_only"];

/// `CloudHomeMapping.participant`: an address is an invited contact.
pub fn participant(participant: &wire::Participant, identity: &Identity) -> home::Participant {
    let is_agent = participant.kind == "agent";
    let is_address = participant.kind == "address";
    let mut mapped = home::Participant::new(
        identity.to_home(&participant.id),
        if is_agent { "agent" } else { "human" },
        participant.display_name.clone(),
        is_agent.then_some(if participant.agent_class.as_deref() == Some("mux") {
            "chief"
        } else {
            "agent"
        }),
    );
    mapped.owner_user = participant.owner_user.as_ref().map(|owner| identity.to_home(owner));
    if is_address {
        mapped.membership = "invited".into();
        mapped.invited_contact = Some(participant.display_name.clone());
    }
    mapped.role = participant.role.clone().filter(|role| ROLES.contains(&role.as_str()));
    mapped
}

/// `CloudHomeMapping.kind`: `group`, `dm`, `chief`; None for one it does not name.
pub fn kind(wire: Option<&str>) -> Option<&'static str> {
    match wire? {
        "group" => Some("group"),
        "dm" => Some("direct"),
        "chief" => Some("chief"),
        _ => None,
    }
}

/// `CloudHomeMapping.summary(_ summary:)`: a cloud head. Participants who left are not members.
pub fn summary(summary: &wire::Summary, identity: &Identity) -> home::Summary {
    let mut cursors: BTreeMap<String, u64> = BTreeMap::new();
    for (id, seq) in &summary.read_cursors {
        let slot = cursors.entry(identity.to_home(id)).or_insert(*seq);
        *slot = (*slot).max(*seq);
    }
    home::Summary {
        id: summary.id.clone(),
        owner: "cloud".into(),
        title: summary.title.clone(),
        participants: summary
            .participants
            .iter()
            .filter(|p| p.left_at.is_none())
            .map(|p| participant(p, identity))
            .collect(),
        last_seq: summary.last_seq,
        rev: summary.rev,
        created_at: core::date_or_past(&summary.created_at),
        updated_at: core::date_or_past(&summary.updated_at),
        last_message: summary.last_message.as_ref().map(|m| core::message(m, Some(identity))),
        read_cursors: cursors.into_iter().collect(),
        read_cursor_times: Vec::new(),
        pin_rank: None,
        muted: false,
        mention_count: 0,
        declared_kind: kind(summary.kind.as_deref()).map(Into::into),
        member_count: summary.member_count,
        chief_replies: summary
            .settings
            .as_ref()
            .and_then(|s| s.wake_policy.clone())
            .filter(|policy| ["auto", "mentions", "all"].contains(&policy.as_str())),
        channel_chief: summary.channel_chief.as_ref().map(|chief| identity.to_home(chief)),
    }
}

fn encoded(summary: &home::Summary) -> Value {
    serde_json::to_value(summary).unwrap_or(Value::Null)
}

/// `CloudHomeMapping.summary(_ entry:)`: a conversation known only from its inbox entry.
pub fn entry_summary(entry: &InboxEntry, identity: &Identity) -> Value {
    let mut participants = vec![home::Participant::new(
        identity.local_id.clone(),
        "human",
        identity.display_name.clone(),
        None,
    )];
    if let Some(peer) = &entry.dm_peer {
        let is_agent = peer.starts_with("agent_");
        participants.push(home::Participant::new(
            identity.to_home(peer),
            if is_agent { "agent" } else { "human" },
            String::new(),
            is_agent.then_some("agent"),
        ));
    }
    let at = parse_date(&entry.last_at).unwrap_or(DISTANT_PAST);
    // The entry's unread count excludes the user's own messages; the cursor it implies is a floor.
    let cursor = entry.last_seq - entry.last_seq.min(entry.unread);
    let mut summary = encoded(&home::Summary {
        id: entry.conversation.clone(),
        owner: "cloud".into(),
        title: entry.title.clone(),
        participants,
        last_seq: entry.last_seq,
        rev: entry.rev,
        created_at: at,
        updated_at: at,
        last_message: None,
        read_cursors: vec![(identity.local_id.clone(), cursor)],
        read_cursor_times: Vec::new(),
        pin_rank: None,
        muted: false,
        mention_count: 0,
        declared_kind: None,
        member_count: None,
        chief_replies: None,
        channel_chief: None,
    });
    apply(entry, &mut summary);
    summary
}

/// `CloudHomeMapping.apply`: the user-owned inbox fields (pin, mute) over a head; a newer entry also
/// moves `lastSeq`.
pub fn apply(entry: &InboxEntry, summary: &mut Value) {
    let Some(head) = summary.as_object_mut() else {
        return;
    };
    if entry.pinned {
        head.insert("pinRank".into(), entry.pin_position.unwrap_or(0).into());
    } else {
        head.remove("pinRank");
    }
    head.insert("muted".into(), entry.muted.into());
    head.insert("mentionCount".into(), entry.mentions.min(i64::MAX as u64).into());
    // A teammate's entry for someone else's shared Chief conversation says group; the head's chief stays.
    if let Some(kind) = kind(Some(&entry.kind))
        && head.get("declaredKind").and_then(Value::as_str) != Some("chief")
    {
        head.insert("declaredKind".into(), kind.into());
    }
    if entry.last_seq > last_seq(head) {
        head.insert("lastSeq".into(), entry.last_seq.into());
        if let Some(at) = parse_date(&entry.last_at) {
            let updated = head.get("updatedAt").and_then(Value::as_f64).unwrap_or(DISTANT_PAST);
            head.insert("updatedAt".into(), updated.max(at).into());
        }
    }
}

fn last_seq(head: &Map<String, Value>) -> u64 {
    head.get("lastSeq").and_then(Value::as_u64).unwrap_or(0)
}

fn head_id(head: &Value) -> Option<&str> {
    head.get("id").and_then(Value::as_str)
}

/// `CloudHomeMapping.parts`: mentions as the cloud's ids, then the local owner's parts.
pub fn parts(
    parts: &[MessagePart],
    plain_texts: &[Option<String>],
    identity: &Identity,
) -> Vec<wire::Part> {
    let mapped: Vec<MessagePart> = parts
        .iter()
        .map(|part| match part {
            MessagePart::Text { text, mentions } => MessagePart::Text {
                text: text.clone(),
                mentions: mentions
                    .iter()
                    .map(|m| home::Mention {
                        participant: identity.to_cloud(&m.participant),
                        ..m.clone()
                    })
                    .collect(),
            },
            other => other.clone(),
        })
        .collect();
    core::wire_parts(&mapped, plain_texts)
}

/// What `CloudHomeState` keeps that its decisions read.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct State {
    #[serde(default)]
    pub identity: Option<Identity>,
    #[serde(default)]
    pub entries: Vec<InboxEntry>,
    /// Home `ConversationSummary` objects.
    #[serde(default)]
    pub heads: Vec<Value>,
    /// Subscribed conversation ids.
    #[serde(default)]
    pub targets: Vec<String>,
    #[serde(default)]
    pub created: Vec<String>,
    #[serde(default)]
    pub removed: Vec<String>,
    /// People the user can reach that no head names yet.
    #[serde(default)]
    pub directory: Vec<home::Participant>,
    #[serde(default)]
    pub inbox_rev: u64,
}

impl State {
    fn entry(&self, id: &str) -> Option<&InboxEntry> {
        self.entries.iter().find(|entry| entry.conversation == id)
    }

    fn head(&self, id: &str) -> Option<&Value> {
        self.heads.iter().find(|head| head_id(head) == Some(id))
    }

    /// `joined`: the head with the inbox's pin and mute, or the entry alone.
    pub fn joined(&self, id: &str) -> Option<Value> {
        let identity = self.identity.as_ref()?;
        let entry = self.entry(id);
        let Some(head) = self.head(id) else {
            return entry.map(|entry| entry_summary(entry, identity));
        };
        let mut summary = head.clone();
        if let Some(entry) = entry {
            apply(entry, &mut summary);
        }
        Some(summary)
    }

    /// `snapshot`: the listed conversations, the created ones not listed yet, then the open ones
    /// (subscribed, not listed, created or removed); each group by id. Bumps `inboxRev`.
    pub fn snapshot(&mut self) -> Vec<Value> {
        self.inbox_rev += 1;
        let listed: BTreeSet<&str> = self.entries.iter().map(|e| e.conversation.as_str()).collect();
        let created: BTreeSet<&str> = self.created.iter().map(String::as_str).collect();
        let removed: BTreeSet<&str> = self.removed.iter().map(String::as_str).collect();
        let open: BTreeSet<&str> = self
            .targets
            .iter()
            .map(String::as_str)
            .filter(|id| !listed.contains(id) && !created.contains(id) && !removed.contains(id))
            .collect();
        listed
            .iter()
            .chain(created.difference(&listed))
            .chain(open.iter())
            .filter_map(|id| self.joined(id))
            .collect()
    }

    /// `needsHead`: a listed conversation, not subscribed, whose head is missing or behind its entry.
    pub fn needs_head(&self, id: &str) -> bool {
        let Some(entry) = self.entry(id) else {
            return false;
        };
        if self.targets.iter().any(|target| target == id) {
            return false;
        }
        match self.head(id).and_then(Value::as_object) {
            None => true,
            Some(head) => entry.last_seq > last_seq(head),
        }
    }

    /// `missingHeads`: the listed conversations that need a head, by id.
    pub fn missing_heads(&self) -> Vec<String> {
        let ids: BTreeSet<&str> = self.entries.iter().map(|e| e.conversation.as_str()).collect();
        ids.into_iter().filter(|id| self.needs_head(id)).map(String::from).collect()
    }

    /// `participantRecord`: a participant for `conversation.create`, as a known head names it.
    pub fn participant_record(&self, id: &str, identity: &Identity) -> wire::Participant {
        let known = self
            .heads
            .iter()
            .filter_map(|head| head.get("participants"))
            .filter_map(|list| serde_json::from_value::<Vec<home::Participant>>(list.clone()).ok())
            .flatten()
            .find(|p| p.id == id)
            .or_else(|| self.directory.iter().find(|p| p.id == id).cloned());
        let wire_id = identity.to_cloud(id);
        let is_agent =
            known.as_ref().map_or_else(|| wire_id.starts_with("agent_"), |p| p.kind == "agent");
        let chief = known.as_ref().and_then(|p| p.agent_class.as_deref()) == Some("chief");
        wire::Participant {
            display_name: known.map_or_else(|| wire_id.clone(), |p| p.display_name),
            id: wire_id,
            kind: if is_agent { "agent" } else { "human" }.into(),
            agent_class: is_agent.then(|| if chief { "mux" } else { "agent" }.into()),
            acp_session: None,
            owner_user: None,
            role: None,
            left_at: None,
        }
    }
}

// MARK: ops

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct IdentityRequest {
    #[serde(default)]
    stack_user_id: String,
    #[serde(default)]
    display_name: String,
    #[serde(default)]
    local_id: String,
    #[serde(default)]
    stack_project_id: Option<String>,
    #[serde(default)]
    stack_team_id: Option<String>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct IdentityReply {
    identity: Identity,
    #[serde(skip_serializing_if = "Option::is_none")]
    worker_team_id: Option<String>,
}

/// `mapping.cloudIdentity {stackUserId, displayName, localId, stackProjectId?, stackTeamId?}` →
/// `{identity, workerTeamId?}` (the team id needs the project).
pub fn identity_op(request: &Value) -> Result<Value, OpError> {
    let request: IdentityRequest = ops::parse(request)?;
    let project = request.stack_project_id.as_deref();
    ops::reply(&IdentityReply {
        identity: identity(
            &request.stack_user_id,
            &request.display_name,
            &request.local_id,
            project,
        ),
        worker_team_id: project
            .zip(request.stack_team_id.as_deref())
            .map(|(p, t)| worker_team_id(p, t)),
    })
}

#[derive(Deserialize)]
struct ParticipantRequest {
    participant: wire::Participant,
    identity: Identity,
}

#[derive(Serialize)]
struct ParticipantReply {
    participant: home::Participant,
}

/// `mapping.cloudParticipant {participant, identity}` → `{participant}`.
pub fn participant_op(request: &Value) -> Result<Value, OpError> {
    let request: ParticipantRequest = ops::parse(request)?;
    ops::reply(&ParticipantReply {
        participant: participant(&request.participant, &request.identity),
    })
}

#[derive(Deserialize)]
struct MessageRequest {
    message: wire::Message,
    identity: Identity,
}

#[derive(Serialize)]
struct MessageReply {
    message: home::Message,
}

/// `mapping.cloudMessage {message, identity}` → `{message}`.
pub fn message_op(request: &Value) -> Result<Value, OpError> {
    let request: MessageRequest = ops::parse(request)?;
    ops::reply(&MessageReply { message: core::message(&request.message, Some(&request.identity)) })
}

#[derive(Deserialize)]
struct SummaryRequest {
    summary: wire::Summary,
    identity: Identity,
}

#[derive(Serialize)]
struct SummaryReply {
    summary: Value,
}

/// `mapping.cloudSummary {summary, identity}` → `{summary}`.
pub fn summary_op(request: &Value) -> Result<Value, OpError> {
    let request: SummaryRequest = ops::parse(request)?;
    ops::reply(&SummaryReply { summary: encoded(&summary(&request.summary, &request.identity)) })
}

#[derive(Deserialize)]
struct EntrySummaryRequest {
    entry: InboxEntry,
    identity: Identity,
    /// A head to lay the entry over (`apply`); without one, the entry alone.
    #[serde(default)]
    head: Option<Value>,
}

/// `mapping.inboxEntrySummary {entry, identity, head?}` → `{summary}`.
pub fn entry_summary_op(request: &Value) -> Result<Value, OpError> {
    let request: EntrySummaryRequest = ops::parse(request)?;
    let summary = match request.head {
        Some(mut head) => {
            apply(&request.entry, &mut head);
            head
        }
        None => entry_summary(&request.entry, &request.identity),
    };
    ops::reply(&SummaryReply { summary })
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct PartsRequest {
    parts: Vec<MessagePart>,
    #[serde(default)]
    plain_texts: Vec<Option<String>>,
    identity: Identity,
}

#[derive(Serialize)]
struct PartsReply {
    parts: Vec<wire::Part>,
}

/// `mapping.cloudParts {parts, plainTexts?, identity}` → `{parts}`.
pub fn parts_op(request: &Value) -> Result<Value, OpError> {
    let request: PartsRequest = ops::parse(request)?;
    ops::reply(&PartsReply {
        parts: parts(&request.parts, &request.plain_texts, &request.identity),
    })
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct SnapshotReply {
    conversations: Vec<Value>,
    rev: u64,
}

/// `mapping.cloudSnapshot {identity, entries, heads, targets, created, removed, inboxRev}` →
/// `{conversations, rev}`.
pub fn snapshot_op(request: &Value) -> Result<Value, OpError> {
    let mut state: State = ops::parse(request)?;
    let conversations = state.snapshot();
    ops::reply(&SnapshotReply { conversations, rev: state.inbox_rev })
}

#[derive(Serialize)]
struct IdsReply {
    ids: Vec<String>,
}

/// `mapping.cloudMissingHeads {entries, heads, targets}` → `{ids}`.
pub fn missing_heads_op(request: &Value) -> Result<Value, OpError> {
    let state: State = ops::parse(request)?;
    ops::reply(&IdsReply { ids: state.missing_heads() })
}

#[derive(Deserialize)]
struct RecordRequest {
    id: String,
    #[serde(flatten)]
    state: State,
}

#[derive(Serialize)]
struct RecordReply {
    participant: wire::Participant,
}

/// `mapping.cloudParticipantRecord {id, identity, heads, directory}` → `{participant}`.
pub fn participant_record_op(request: &Value) -> Result<Value, OpError> {
    let request: RecordRequest = ops::parse(request)?;
    let Some(identity) = request.state.identity.as_ref() else {
        return Err(OpError::Invalid("identity is required".into()));
    };
    ops::reply(&RecordReply {
        participant: request.state.participant_record(&request.id, identity),
    })
}
