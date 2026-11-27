//! Group conversation rules (`HomeGroupActions`, `HomeGroupOutcome`, `HomeGroupCreation`): who a name
//! means, the info sheet's facts, which people resolve for add and create, and how an owner's answer
//! becomes an outcome.

use super::text::{self, case_equal, trim_space};
use super::types::{
    Contact, Membership, Owner, Participant, ParticipantKind, ReplyPolicy, Role, Row, RowKind,
    Source,
};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

/// What a group action came to (`HomeGroupOutcome`); the app words it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum Outcome {
    Done,
    Queued,
    Left,
    NotReachable { name: String },
    OwnerOnly,
    Forbidden,
    ReadOnly,
    NotAGroup,
    UnknownConversation,
    UnknownPerson { name: String },
    NotAMember { name: String },
    CannotMute,
    EmptyText,
    NoPeople,
    Offline,
    RateLimited,
    TooMany,
    Refused { reason: String },
}

impl Outcome {
    pub fn succeeded(&self) -> bool {
        matches!(self, Outcome::Done | Outcome::Queued | Outcome::Left)
    }
}

/// The owner's refusal (`HomeRejection`).
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum Rejection {
    OwnerUnreachable,
    NotAuthorized,
    Invalid { reason: String },
    RateLimited,
    Indeterminate,
}

/// `HomeGroupOutcome(rejection:naming:removing:)`.
pub fn outcome(rejection: &Rejection, naming: &str, removing: bool) -> Outcome {
    let refused_for = || if removing { Outcome::OwnerOnly } else { Outcome::Forbidden };
    match rejection {
        Rejection::OwnerUnreachable => Outcome::Offline,
        Rejection::RateLimited => Outcome::RateLimited,
        Rejection::NotAuthorized => refused_for(),
        Rejection::Indeterminate => Outcome::Refused { reason: String::new() },
        Rejection::Invalid { reason } => match reason.as_str() {
            "forbidden" => refused_for(),
            "read_only" => Outcome::ReadOnly,
            "not_reachable" => Outcome::NotReachable { name: naming.to_owned() },
            "kind_forbids" => Outcome::NotAGroup,
            "unknown_conversation" => Outcome::UnknownConversation,
            "not_participant" => Outcome::NotAMember { name: naming.to_owned() },
            "too_many_participants" => Outcome::TooMany,
            "home.rate_limited" => Outcome::RateLimited,
            other => Outcome::Refused { reason: other.to_owned() },
        },
    }
}

/// `names(in:)`: a comma-separated list, trimmed, empties dropped.
pub fn names(list: &str) -> Vec<String> {
    list.split(',').map(trim_space).filter(|n| !n.is_empty()).map(str::to_owned).collect()
}

/// `match(_:in:)`: an id first, else a name equal but for case.
pub fn match_person<'a>(text: &str, people: &[(&'a str, String)]) -> Option<&'a str> {
    if let Some((id, _)) = people.iter().find(|(id, _)| *id == text) {
        return Some(id);
    }
    people.iter().find(|(_, name)| !name.is_empty() && case_equal(name, text)).map(|(id, _)| *id)
}

/// The groups and contacts the rules look up people in.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Book {
    pub rows: Vec<Row>,
    pub me: Option<String>,
    pub contacts: Vec<Contact>,
}

impl Book {
    fn row(&self, id: &str) -> Option<&Row> {
        self.rows.iter().find(|r| r.id == id)
    }

    /// `member(_:in:)`: a participant of that conversation.
    pub fn member(&self, text: &str, conversation: &str) -> Option<&str> {
        let people: Vec<(&str, String)> = self
            .row(conversation)
            .map(|r| r.participants.iter().map(|p| (p.id.as_str(), p.visible_name())).collect())
            .unwrap_or_default();
        match_person(text, &people)
    }

    /// `contact(_:)`: a contact, else an active person or Chief from any conversation but me.
    pub fn contact(&self, text: &str) -> Option<&str> {
        let contacts: Vec<(&str, String)> =
            self.contacts.iter().map(|c| (c.id.as_str(), c.name.clone())).collect();
        if let Some(id) = match_person(text, &contacts) {
            return Some(id);
        }
        let me = self.me.as_deref();
        let known: Vec<(&str, String)> = self
            .rows
            .iter()
            .flat_map(|r| &r.participants)
            .filter(|p| {
                Some(p.id.as_str()) != me
                    && (p.kind == ParticipantKind::Human || p.is_chief())
                    && p.membership == Membership::Active
            })
            .map(|p| (p.id.as_str(), p.visible_name()))
            .collect();
        match_person(text, &known)
    }

    /// `addable(to:)`: contacts not in the conversation; a Chief conversation takes people only.
    pub fn addable(&self, conversation: &str) -> Vec<Contact> {
        let row = self.row(conversation);
        let present: Vec<&str> =
            row.map(|r| r.participants.iter().map(|p| p.id.as_str()).collect()).unwrap_or_default();
        let people_only = row.is_some_and(|r| r.kind == RowKind::Chief);
        self.contacts
            .iter()
            .filter(|c| {
                !present.contains(&c.id.as_str()) && (!people_only || c.source != Source::Agent)
            })
            .cloned()
            .collect()
    }

    /// `sharesMyChief(_:)`.
    pub fn shares_my_chief(&self, conversation: &str) -> bool {
        self.row(conversation).is_some_and(|r| is_my_cloud_chief(r, self.me.as_deref()))
    }
}

/// `isMyCloudChief(_:me:)`: my own Chief's cloud conversation.
pub fn is_my_cloud_chief(row: &Row, me: Option<&str>) -> bool {
    match me {
        Some(me) if row.owner == Some(Owner::Cloud) => row.is_my_chief_line(me),
        _ => false,
    }
}

/// `chiefReplies(of:)`: the reply policy a shared group with a Chief shows; nil elsewhere.
pub fn chief_replies(row: &Row) -> Option<ReplyPolicy> {
    let shows = row.kind == RowKind::Group
        && row.declared_kind != Some(RowKind::Chief)
        && row.owner == Some(Owner::Cloud)
        && row.participants.iter().any(Participant::is_chief);
    shows.then(|| row.chief_replies.unwrap_or_default())
}

/// One person on the info sheet (`HomeGroupMember`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Member {
    pub id: String,
    pub name: String,
    pub initials: String,
    pub is_me: bool,
    pub is_agent: bool,
    pub is_invited: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub role: Option<Role>,
}

/// The info sheet's facts (`HomeGroupInfo`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Info {
    pub conversation: String,
    pub is_group: bool,
    pub title: String,
    pub display_title: String,
    pub members: Vec<Member>,
    pub can_mute: bool,
    pub muted: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub member_count: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub chief_replies: Option<ReplyPolicy>,
    pub can_add_people: bool,
    pub can_rename: bool,
}

/// `info(_:)`: me first, the owner's title unless it is an internal id.
pub fn info(row: &Row, me: Option<&str>, can_mute: bool, muted_here: bool) -> Info {
    let members: Vec<Member> = row
        .participants
        .iter()
        .map(|p| Member {
            id: p.id.clone(),
            name: p.visible_name(),
            initials: p.initials(),
            is_me: Some(p.id.as_str()) == me,
            is_agent: p.kind == ParticipantKind::Agent,
            is_invited: p.membership == Membership::Invited,
            role: p.role,
        })
        .collect();
    let (mine, others): (Vec<Member>, Vec<Member>) = members.into_iter().partition(|m| m.is_me);
    let group_not_chief = row.kind == RowKind::Group && row.declared_kind != Some(RowKind::Chief);
    Info {
        conversation: row.id.clone(),
        is_group: row.kind == RowKind::Group,
        title: if text::is_home_internal_id(&row.summary_title) {
            String::new()
        } else {
            row.summary_title.clone()
        },
        display_title: row.title.clone(),
        members: mine.into_iter().chain(others).collect(),
        can_mute,
        muted: muted_here || row.muted,
        member_count: row.member_count,
        chief_replies: chief_replies(row),
        can_add_people: is_my_cloud_chief(row, me) || group_not_chief,
        can_rename: group_not_chief,
    }
}

// MARK: Named people for add and create

/// Whether the names go into a new group or an existing one.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Purpose {
    Add,
    Create,
}

/// The next step of turning a list of names into people (`add(named:to:)`, `create(named:title:replies:)`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum NamedStep {
    /// Ask the owner who this email is (`store.resolve`), put the answer in `lookups`, ask again.
    Lookup { email: String },
    /// Everyone resolved: run the op with these people; `naming` names them in a refusal.
    People { people: Vec<String>, naming: String },
    /// Stop with this outcome.
    Refused { outcome: Outcome },
}

/// Turns `list` into people, one name at a time, as the Swift loop did: a contact or a known person, else
/// an email the owner resolves (a member, or `notReachable`), else `unknownPerson`. `lookups` holds the
/// owner's answers so far: an email to the member's id, or null when it is no member.
pub fn named_people(
    book: &Book,
    list: &str,
    conversation: Option<&str>,
    purpose: Purpose,
    lookups: &BTreeMap<String, Option<String>>,
) -> NamedStep {
    let names = names(list);
    if names.is_empty() {
        return NamedStep::Refused { outcome: Outcome::NoPeople };
    }
    if purpose == Purpose::Add && conversation.and_then(|c| book.row(c)).is_none() {
        return NamedStep::Refused { outcome: Outcome::UnknownConversation };
    }
    let me = book.me.as_deref();
    let mut people: Vec<String> = Vec::new();
    for name in &names {
        let found = if let Some(person) = book.contact(name) {
            if purpose == Purpose::Create && Some(person) == me {
                continue;
            }
            person.to_owned()
        } else if let Some(address) = text::address(name).filter(|a| a.is_email()) {
            match lookups.get(&address.value) {
                None => return NamedStep::Lookup { email: address.value },
                Some(None) => {
                    return NamedStep::Refused {
                        outcome: Outcome::NotReachable { name: name.clone() },
                    };
                }
                Some(Some(id)) => id.clone(),
            }
        } else {
            return NamedStep::Refused { outcome: Outcome::UnknownPerson { name: name.clone() } };
        };
        if purpose == Purpose::Create && people.contains(&found) {
            continue;
        }
        people.push(found);
    }
    if people.is_empty() {
        return NamedStep::Refused { outcome: Outcome::NoPeople };
    }
    NamedStep::People { people, naming: names.join(", ") }
}

/// After `createGroup`: set the reply policy only when one other than the default was asked for.
pub fn create_sets_replies(replies: Option<ReplyPolicy>) -> bool {
    replies.is_some_and(|r| r != ReplyPolicy::default())
}

// MARK: Gates before an op runs

/// What a group change does before it reaches the owner.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Change {
    Rename,
    Add,
    Remove,
    Leave,
    SetChiefReplies,
    Send,
}

/// The gate's answer: go ahead (with the trimmed text for a send), or stop with an outcome.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum Gate {
    Run {
        #[serde(skip_serializing_if = "Option::is_none")]
        text: Option<String>,
        /// A removal of me is a leave.
        #[serde(skip_serializing_if = "std::ops::Not::not")]
        leave: bool,
    },
    Stop {
        outcome: Outcome,
    },
}

/// `run(on:naming:removing:requiresGroup:)` and the checks each change makes before it.
pub fn gate(
    book: &Book,
    change: Change,
    conversation: &str,
    text: Option<&str>,
    person: Option<&str>,
) -> Gate {
    let stop = |outcome| Gate::Stop { outcome };
    let me = book.me.as_deref();
    let mut leave = false;
    let mut trimmed = None;
    let requires_group = match change {
        Change::Send => {
            let typed = trim_space(text.unwrap_or(""));
            if typed.is_empty() {
                return stop(Outcome::EmptyText);
            }
            trimmed = Some(typed.to_owned());
            false
        }
        Change::Leave => {
            if me.is_none() {
                return stop(Outcome::Offline);
            }
            false
        }
        Change::Remove if person.is_some() && person == me => {
            if me.is_none() {
                return stop(Outcome::Offline);
            }
            leave = true;
            false
        }
        Change::Add | Change::Remove => !book.shares_my_chief(conversation),
        Change::Rename | Change::SetChiefReplies => true,
    };
    let Some(row) = book.row(conversation) else {
        return stop(Outcome::UnknownConversation);
    };
    if requires_group && row.kind != RowKind::Group {
        return stop(Outcome::NotAGroup);
    }
    Gate::Run { text: trimmed, leave }
}

/// What the op came to, mapped for the change: a send offline is queued, a leave done is left.
pub fn settle(change: Change, result: &Outcome) -> Outcome {
    match (change, result) {
        (Change::Send, Outcome::Offline) => Outcome::Queued,
        (Change::Leave, Outcome::Done) => Outcome::Left,
        _ => result.clone(),
    }
}

/// `remove(named:from:)`'s lookup: the trimmed name to a member's id.
pub fn remove_named(book: &Book, text: &str, conversation: &str) -> Result<String, Outcome> {
    let name = trim_space(text);
    if name.is_empty() {
        return Err(Outcome::NoPeople);
    }
    if book.row(conversation).is_none() {
        return Err(Outcome::UnknownConversation);
    }
    book.member(name, conversation)
        .map(str::to_owned)
        .ok_or_else(|| Outcome::NotAMember { name: name.to_owned() })
}

/// The name a refusal of removing `person` uses: their visible name, else the id.
pub fn removal_naming(book: &Book, person: &str, conversation: &str) -> String {
    book.row(conversation)
        .and_then(|r| r.participants.iter().find(|p| p.id == person))
        .map_or_else(|| person.to_owned(), Participant::visible_name)
}

/// `setMuted(_:_:)`'s checks.
pub fn mute_gate(book: &Book, conversation: &str, can_mute: bool) -> Outcome {
    if book.row(conversation).is_none() {
        Outcome::UnknownConversation
    } else if !can_mute {
        Outcome::CannotMute
    } else {
        Outcome::Done
    }
}

// MARK: Requests

#[derive(Deserialize)]
pub struct NamesRequest {
    pub list: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LookupRequest {
    pub text: String,
    pub conversation: Option<String>,
    #[serde(flatten)]
    pub book: Book,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct InfoRequest {
    pub conversation: String,
    #[serde(default)]
    pub can_mute: bool,
    #[serde(default)]
    pub muted: bool,
    #[serde(flatten)]
    pub book: Book,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NamedRequest {
    pub list: String,
    pub conversation: Option<String>,
    pub purpose: Purpose,
    #[serde(default)]
    pub lookups: BTreeMap<String, Option<String>>,
    #[serde(flatten)]
    pub book: Book,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OutcomeRequest {
    pub rejection: Rejection,
    #[serde(default)]
    pub naming: String,
    #[serde(default)]
    pub removing: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GateRequest {
    pub change: Change,
    pub conversation: String,
    pub text: Option<String>,
    pub person: Option<String>,
    #[serde(default)]
    pub can_mute: bool,
    #[serde(flatten)]
    pub book: Book,
}

#[derive(Deserialize)]
pub struct SettleRequest {
    pub change: Change,
    pub outcome: Outcome,
}

#[derive(Deserialize)]
pub struct RepliesRequest {
    pub replies: Option<ReplyPolicy>,
}
