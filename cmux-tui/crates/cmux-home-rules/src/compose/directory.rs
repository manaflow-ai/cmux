//! The directory and team rules (`HomeDirectory`, `HomeTeamInviteRun`, `HomeTeamSeatImpact`): which Chief a
//! name means, the team member list, how an owner's error becomes a rename or archive answer, the ops a
//! new channel sends, and what inviting a teammate costs.

use super::text::{self, standard_order, trim_space};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

/// A Chief the directory knows.
#[derive(Debug, Clone, Deserialize)]
pub struct Chief {
    pub id: String,
    #[serde(default)]
    pub name: String,
}

fn name_key(text: &str) -> String {
    text.to_lowercase().split_whitespace().collect::<Vec<_>>().join(" ")
}

/// `chief(named:)`: an id first, else the one Chief whose name matches but for case and spacing.
pub fn chief_named<'a>(chiefs: &'a [Chief], id_or_name: &str) -> Option<&'a str> {
    let wanted = trim_space(id_or_name);
    if wanted.is_empty() {
        return None;
    }
    if let Some(chief) = chiefs.iter().find(|c| c.id == wanted) {
        return Some(&chief.id);
    }
    let key = name_key(wanted);
    let matches: Vec<&Chief> = chiefs.iter().filter(|c| name_key(&c.name) == key).collect();
    match matches.as_slice() {
        [only] => Some(&only.id),
        _ => None,
    }
}

/// One teammate (`HomeTeamMember`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Member {
    pub id: String,
    pub name: String,
}

fn cloud_id(user: &str) -> String {
    if user.starts_with("user_") { user.to_owned() } else { format!("user_{user}") }
}

/// `teamMembers(from:me:)`: the owner's `members[]`, me left out, sorted by name.
pub fn members(value: &Value, me: Option<&str>) -> Vec<Member> {
    let me = me.map(cloud_id);
    let mut result: Vec<Member> = value
        .get("members")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|m| {
            let user = m.get("user").and_then(Value::as_str).filter(|u| !u.is_empty())?;
            let id = cloud_id(user);
            if Some(&id) == me.as_ref() {
                return None;
            }
            let name = m
                .get("display_name")
                .and_then(Value::as_str)
                .filter(|n| !n.is_empty())
                .unwrap_or(user);
            Some(Member { id, name: name.to_owned() })
        })
        .collect();
    result.sort_by(|a, b| standard_order(&a.name, &b.name));
    result
}

/// `sessionScope(_:)`: the account and team a session key names (`account|team|...`).
pub fn session_scope(key: &str) -> Vec<String> {
    key.splitn(3, '|').take(2).map(str::to_owned).collect()
}

/// Whether the team member list is cleared: the scope changed.
pub fn scope_changed(old: &str, new: &str) -> bool {
    session_scope(old) != session_scope(new)
}

/// An owner's answer: a failure tagged with a `code`, or a value.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum Reply {
    Owner { code: String, message: String },
    Value { value: Value },
}

/// `replyValue(_:)`.
pub fn reply_value(value: &Value) -> Reply {
    if value.get("_tag").is_some()
        && let Some(code) = value.get("code").and_then(Value::as_str)
    {
        let message = value.get("message").and_then(Value::as_str).unwrap_or(code);
        return Reply::Owner { code: code.to_owned(), message: message.to_owned() };
    }
    Reply::Value { value: value.clone() }
}

/// The error a directory call threw.
#[derive(Debug, Clone, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum Failure {
    SignedOut,
    Owner {
        code: String,
        #[serde(default)]
        message: String,
    },
    Other,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum RenameFailure {
    SignedOut,
    ChangedElsewhere,
    InvalidName,
    NotFound,
    Refused { reason: String },
    NoConnection,
}

/// `renameFailure(_:)`.
pub fn rename_failure(failure: &Failure) -> RenameFailure {
    match failure {
        Failure::SignedOut => RenameFailure::SignedOut,
        Failure::Owner { code, message } => match code.as_str() {
            "revision.conflict" => RenameFailure::ChangedElsewhere,
            "validation.invalid" => RenameFailure::InvalidName,
            "selector.not_found" | "chief_archived" => RenameFailure::NotFound,
            _ => RenameFailure::Refused {
                reason: if message.is_empty() { code.clone() } else { message.clone() },
            },
        },
        Failure::Other => RenameFailure::NoConnection,
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum ArchiveOutcome {
    Conflict,
    IsDefault,
    NotFound,
    Refused { reason: String },
    Unreachable,
}

/// `archiveOutcome(_:)`.
pub fn archive_outcome(failure: &Failure) -> ArchiveOutcome {
    match failure {
        Failure::Owner { code, message } => match code.as_str() {
            "revision.conflict" => ArchiveOutcome::Conflict,
            "chief_is_default" => ArchiveOutcome::IsDefault,
            "selector.not_found" => ArchiveOutcome::NotFound,
            _ => ArchiveOutcome::Refused { reason: message.clone() },
        },
        _ => ArchiveOutcome::Unreachable,
    }
}

/// `needsEnsure(_:)`: the owner wants `user.ensure` before this call.
pub fn needs_ensure(code: &str, message: &str) -> bool {
    code == "validation.invalid" && message.contains("user.ensure")
}

/// Someone a new channel takes in.
#[derive(Debug, Clone, Deserialize)]
#[serde(untagged)]
pub enum Person {
    Email { email: String },
    Account { account: String },
}

/// `createChannel`'s plan: the title check and the ops each person needs.
pub fn channel_plan(
    title: &str,
    chief_name: Option<&str>,
    people: &[Person],
    key: &str,
    conversation: &str,
) -> Value {
    let title = trim_space(title);
    let count = title.chars().count();
    if count == 0 || count > 200 {
        return json!({"error": {"code": "validation.invalid", "field": "title"}});
    }
    let mut params = json!({"title": title});
    if let (Some(name), Some(object)) =
        (chief_name.map(trim_space).filter(|n| !n.is_empty()), params.as_object_mut())
    {
        object.insert("display_name".to_owned(), json!(name));
    }
    let ops: Vec<Value> = people
        .iter()
        .enumerate()
        .map(|(i, person)| match person {
            Person::Email { email } => json!({
                "op": "invite.create",
                "idempotency_key": format!("{key}:invite:{i}"),
                "origin": "user",
                "params": {
                    "conversation": conversation,
                    "address": {"email": email},
                    "display_name": email.split('@').next().unwrap_or(""),
                },
            }),
            Person::Account { account } => json!({
                "op": "participants.add",
                "idempotency_key": format!("{key}:add:{i}"),
                "params": {"conversation": conversation, "participant": {"id": account, "kind": "human"}},
            }),
        })
        .collect();
    json!({"params": params, "ops": ops})
}

/// `makePrimary(_:)`: an already-default Chief sends nothing.
pub fn make_primary_sends(is_default: bool) -> bool {
    !is_default
}

// MARK: Team seats and invites

/// `HomeTeamSeatImpact`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum SeatImpact {
    NotAllowed,
    Capped { members: u64, limit: u64 },
    PaidSeat { members: u64 },
    Unknown,
    Free { members: u64 },
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct SeatRequest {
    pub can_invite: bool,
    #[serde(rename = "planID")]
    pub plan_id: Option<String>,
    pub has_subscription: bool,
    pub member_count: u64,
    pub member_limit: Option<u64>,
}

pub fn seat_impact(r: &SeatRequest) -> SeatImpact {
    if !r.can_invite {
        SeatImpact::NotAllowed
    } else if let Some(limit) = r.member_limit {
        SeatImpact::Capped { members: r.member_count, limit }
    } else if r.has_subscription {
        if r.plan_id.as_deref().is_some_and(|p| p.to_lowercase() == "team") {
            SeatImpact::PaidSeat { members: r.member_count }
        } else {
            SeatImpact::Unknown
        }
    } else {
        SeatImpact::Free { members: r.member_count }
    }
}

/// `inviteEmail(_:)`: a typed email to prefill, or why it is refused.
pub fn invite_email(text: &str) -> Value {
    let typed = trim_space(text);
    if !typed.is_empty() && !text::address(typed).is_some_and(|a| a.is_email()) {
        return json!({"refused": {"kind": "invalidAddress", "text": typed}});
    }
    json!({"ok": true, "prefill": typed})
}

/// The invite run's result (`HomeTeamInviteRun`).
#[derive(Debug, Clone, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum InviteResult {
    Sent,
    AlreadyMember { email: String },
    SendFailed { email: String },
    NotAllowed,
    Unreachable,
}

pub fn invite_outcome(result: &InviteResult) -> Value {
    match result {
        InviteResult::Sent => json!({"kind": "invited"}),
        InviteResult::AlreadyMember { email } => {
            json!({"kind": "refused", "reason": {"kind": "alreadyMember", "email": email}})
        }
        InviteResult::SendFailed { email } => {
            json!({"kind": "refused", "reason": {"kind": "sendFailed", "email": email}})
        }
        InviteResult::NotAllowed => json!({"kind": "refused", "reason": {"kind": "notAllowed"}}),
        InviteResult::Unreachable => json!({"kind": "cloudUnreachable"}),
    }
}

/// The sheet's answer: sent, or cancelled (by the person, or because nothing was sent).
pub fn invite_answer(sent: Option<&str>, by_person: bool, team: &str) -> Value {
    match sent {
        Some(email) => json!({"sent": email, "team": team}),
        None if by_person => json!({"cancelled": true, "team": team}),
        None => json!({"cancelled": true, "team": team, "failed": true}),
    }
}

// MARK: Requests

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ChiefRequest {
    #[serde(default)]
    pub chiefs: Vec<Chief>,
    pub text: String,
}

#[derive(Deserialize)]
pub struct MembersRequest {
    #[serde(default)]
    pub value: Value,
    pub me: Option<String>,
}

#[derive(Deserialize)]
pub struct ValueRequest {
    pub value: Value,
}

#[derive(Deserialize)]
pub struct FailureRequest {
    pub error: Failure,
}

#[derive(Deserialize)]
pub struct EnsureRequest {
    pub code: String,
    #[serde(default)]
    pub message: String,
}

#[derive(Deserialize)]
pub struct ScopeRequest {
    pub key: String,
    pub previous: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ChannelRequest {
    pub title: String,
    pub chief_name: Option<String>,
    #[serde(default)]
    pub people: Vec<Person>,
    pub key: String,
    pub conversation: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PrimaryRequest {
    pub is_default: bool,
}

#[derive(Deserialize)]
pub struct EmailRequest {
    pub text: String,
}

#[derive(Deserialize)]
pub struct InviteOutcomeRequest {
    pub result: InviteResult,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AnswerRequest {
    pub sent: Option<String>,
    #[serde(default)]
    pub by_person: bool,
    pub team: String,
}
