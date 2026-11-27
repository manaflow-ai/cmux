//! `home-inbox` (capability `home-inbox-v1`): the Home list as one person
//! sees it, derived once here so every view (the native Messages view, the
//! Channels page, the CLI) shows the same rows. A read model, not state: it
//! adds facts to the owner's summaries (kind, display name, unread count,
//! preview, a Chief's live state) and orders them (pins first, then newest
//! activity). Views keep only layout.

use std::cmp::Ordering;
use std::collections::{BTreeMap, BTreeSet, HashMap};

use serde::{Deserialize, Serialize};

use crate::types::{AgentClass, Message, Part, Participant, ParticipantKind, Summary, WorkStatus};

/// The name of a Chief with no name of its own.
pub const CHIEF_NAME: &str = "Chief";

/// Most characters of a row's preview.
pub const PREVIEW_CHARS: usize = 200;

/// What a conversation is to the person.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum HomeKind {
    /// A direct conversation with one Chief.
    Chief,
    /// A direct conversation with one other participant.
    Direct,
    /// A titled conversation of several participants, or a titled later
    /// conversation with the same one participant as an older direct one.
    Channel,
    /// An untitled conversation of several participants.
    Group,
}

/// A Chief's live state, for its direct conversation's row.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ChiefState {
    /// It types now, or its last message reports work that runs.
    Working,
    /// Its last message waits for the person (a question, an approval).
    Waiting,
    Idle,
}

/// The person's own list state of a conversation (kept beside it by the
/// owner: `conversation-inbox-state-v1`).
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct HomeListState {
    pub pin_position: Option<u64>,
    pub pinned: bool,
    pub marked_unread: bool,
}

/// What the projection reads besides the summaries.
#[derive(Debug, Default)]
pub struct HomeInboxInput<'a> {
    /// The person (`user_local`, `user_<id>`).
    pub me: &'a str,
    /// The person's pins and marks by conversation id.
    pub states: HashMap<String, HomeListState>,
    /// Current Chief names by participant id (the Chief registry): a Chief's
    /// direct conversation shows the Chief's name, not the title it was made
    /// with.
    pub chief_names: BTreeMap<String, String>,
    /// Participants typing now, by conversation id.
    pub typing: HashMap<String, Vec<String>>,
    /// Authors of agent runs that run now (not stale), by conversation id.
    pub running: HashMap<String, Vec<String>>,
    /// Deleted Chiefs (the registry's tombstones): a deleted Chief's direct
    /// conversation leaves the list, on every device that reads it, as Delete
    /// Chief promises.
    pub deleted_chiefs: BTreeSet<String>,
}

/// One row of the Home list.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct HomeRow {
    pub id: String,
    /// `local` (this daemon's conversations) or `cloud` (the person's Cloud
    /// inbox, through the daemon's lease).
    pub owner: &'static str,
    pub kind: HomeKind,
    /// The row's display name: a Chief's current name for its direct
    /// conversation, else the title, else the other participants' names.
    pub name: String,
    /// Messages after the person's read cursor (0 when the person wrote the
    /// last one).
    pub unread: u64,
    /// The last message's time (a deleted one too), else `updated_at`.
    pub activity_at: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub preview: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_author: Option<String>,
    /// The Chief of a `chief` row.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub chief: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub chief_state: Option<ChiefState>,
    pub pinned: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub pin_position: Option<u64>,
    pub marked_unread: bool,
    /// The person muted it (a Cloud mute; local conversations have none):
    /// a view does not count its unread messages.
    pub muted: bool,
}

fn participant<'s>(summary: &'s Summary, id: &str) -> Option<&'s Participant> {
    summary.participants.iter().find(|participant| participant.id == id)
}

/// An agent of class `mux`, or an agent the Chief registry knows (an adopted
/// Chief keeps its participant record).
fn is_chief(summary: &Summary, id: &str, input: &HomeInboxInput<'_>) -> bool {
    participant(summary, id).is_some_and(|participant| {
        participant.kind == ParticipantKind::Agent
            && (participant.agent_class == Some(AgentClass::Mux)
                || input.chief_names.contains_key(id))
    })
}

/// A deleted Chief's direct conversation (the one Delete Chief says leaves the
/// list): not in the list. Its channels and groups stay, with their history.
fn is_deleted_chiefs_direct(
    summary: &Summary,
    input: &HomeInboxInput<'_>,
    channels: &BTreeSet<&str>,
) -> bool {
    matches!(others(summary, input.me).as_slice(), [one] if input.deleted_chiefs.contains(*one))
        && !channels.contains(summary.id.as_str())
}

/// The ids of the participants other than the person.
fn others<'s>(summary: &'s Summary, me: &str) -> Vec<&'s str> {
    summary
        .participants
        .iter()
        .filter(|participant| participant.id != me)
        .map(|participant| participant.id.as_str())
        .collect()
}

/// The text a row previews: the text parts, else the file names; nothing
/// for a deleted message.
pub fn preview_of(message: &Message) -> Option<String> {
    if message.retracted_at.is_some() {
        return None;
    }
    let text = message
        .parts
        .iter()
        .filter_map(|part| match part {
            Part::Text { text, .. } => Some(text.as_str()),
            _ => None,
        })
        .collect::<Vec<_>>()
        .join(" ");
    let text = text.trim();
    let shown = if text.is_empty() {
        message
            .parts
            .iter()
            .filter_map(|part| match part {
                Part::Attachment { name, .. } => Some(name.as_str()),
                _ => None,
            })
            .collect::<Vec<_>>()
            .join(", ")
    } else {
        text.to_string()
    };
    (!shown.is_empty()).then(|| shown.chars().take(PREVIEW_CHARS).collect())
}

fn last_work(message: &Message) -> Option<WorkStatus> {
    message.parts.iter().find_map(|part| match part {
        Part::Work { status, .. } => Some(*status),
        _ => None,
    })
}

/// The Home rows of `summaries` for `input.me`, in list order: pinned rows
/// by pin position, then the rest by newest activity; ties by id.
pub fn home_inbox(summaries: &[Summary], input: &HomeInboxInput<'_>) -> Vec<HomeRow> {
    let me = input.me;
    // A second conversation with the same one participant that has a title
    // is a channel (the person made it as one); the oldest stays the direct.
    let mut channels = BTreeSet::new();
    let mut by_member: BTreeMap<&str, Vec<&Summary>> = BTreeMap::new();
    for summary in summaries {
        if let [one] = others(summary, me).as_slice() {
            by_member.entry(one).or_default().push(summary);
        }
    }
    for list in by_member.values_mut() {
        list.sort_by(|a, b| a.created_at.cmp(&b.created_at).then_with(|| a.id.cmp(&b.id)));
        for later in list.iter().skip(1) {
            if !later.title.is_empty() {
                channels.insert(later.id.as_str());
            }
        }
    }
    let mut rows: Vec<HomeRow> = summaries
        .iter()
        .filter(|summary| !is_deleted_chiefs_direct(summary, input, &channels))
        .map(|summary| {
            let others = others(summary, me);
            let direct = others.len() == 1 && !channels.contains(summary.id.as_str());
            let chief = direct.then(|| others[0]).filter(|id| is_chief(summary, id, input));
            let kind = match (direct, chief.is_some(), summary.title.is_empty()) {
                (true, true, _) => HomeKind::Chief,
                (true, false, _) => HomeKind::Direct,
                (false, _, false) => HomeKind::Channel,
                (false, _, true) => HomeKind::Group,
            };
            let name = chief
                .and_then(|id| input.chief_names.get(id).filter(|name| !name.is_empty()).cloned())
                .or_else(|| (!summary.title.is_empty()).then(|| summary.title.clone()))
                .unwrap_or_else(|| {
                    // A participant with no name is left out: an id is never a name.
                    others
                        .iter()
                        .filter_map(|id| {
                            participant(summary, id)
                                .map(|p| p.display_name.clone())
                                .filter(|name| !name.is_empty())
                                .or_else(|| (chief == Some(*id)).then(|| CHIEF_NAME.to_string()))
                        })
                        .collect::<Vec<_>>()
                        .join(", ")
                });
            let last = summary.last_message.as_ref();
            let mut cursor = summary.read_cursors.get(me).copied().unwrap_or(0);
            if let Some(last) = last.filter(|last| last.author == me) {
                cursor = cursor.max(last.seq);
            }
            let live = last.filter(|last| last.retracted_at.is_none());
            let chief_state = chief.map(|id| {
                let active = |map: &HashMap<String, Vec<String>>| {
                    map.get(&summary.id).is_some_and(|ids| ids.iter().any(|t| t == id))
                };
                let typing = active(&input.typing) || active(&input.running);
                let work = live.filter(|last| last.author == id).and_then(last_work);
                match (typing, work) {
                    (true, _) | (false, Some(WorkStatus::Running)) => ChiefState::Working,
                    (false, Some(WorkStatus::Waiting)) => ChiefState::Waiting,
                    _ => ChiefState::Idle,
                }
            });
            let state = input.states.get(&summary.id).copied().unwrap_or_default();
            HomeRow {
                id: summary.id.clone(),
                owner: crate::OWNER_LOCAL,
                kind,
                name,
                unread: summary.last_seq.saturating_sub(cursor),
                activity_at: last
                    .map_or_else(|| summary.updated_at.clone(), |last| last.created_at.clone()),
                preview: last.and_then(preview_of),
                last_author: live.map(|last| last.author.clone()),
                chief: chief.map(str::to_string),
                chief_state,
                pinned: state.pinned,
                pin_position: state.pin_position.filter(|_| state.pinned),
                marked_unread: state.marked_unread,
                muted: false,
            }
        })
        .collect();
    rows.sort_by(order);
    rows
}

/// `Summary.owner`-style name of the Cloud owner's rows.
pub const OWNER_CLOUD: &str = "cloud";

/// One entry of the person's Cloud inbox (UserDO, `cloud-inbox-list`): the
/// Cloud owner keeps the counts, the preview and the person's list state.
#[derive(Debug, Clone, Deserialize)]
pub struct CloudInboxEntry {
    pub conversation: String,
    /// `chief`, `dm` or `group`.
    #[serde(default)]
    pub kind: String,
    #[serde(default)]
    pub title: String,
    #[serde(default)]
    pub last_at: String,
    #[serde(default)]
    pub preview: String,
    #[serde(default)]
    pub dm_peer: Option<String>,
    #[serde(default)]
    pub unread: u64,
    #[serde(default)]
    pub removed: bool,
    #[serde(default)]
    pub archived: bool,
    #[serde(default)]
    pub pinned: bool,
    #[serde(default)]
    pub pin_position: Option<u64>,
    #[serde(default)]
    pub marked_unread: bool,
    #[serde(default)]
    pub muted: bool,
    /// Unix ms; absent with `muted` = muted until unmuted.
    #[serde(default)]
    pub muted_until: Option<u64>,
}

/// A Cloud inbox entry as a Home row; none for a removed or archived entry.
/// The Cloud owner's kind (`dm` is `direct`; a `group` is a `channel` when it
/// has a title); the name is the title, else "Chief" for a Chief, else empty
/// (the entry has no names, and an id is never a name: the page fills it from
/// the people once it reads the head); a Cloud Chief's live state is not
/// known here (no `chief_state`).
pub fn cloud_row(entry: &CloudInboxEntry, now_ms: u64) -> Option<HomeRow> {
    if entry.removed || entry.archived {
        return None;
    }
    let kind = match entry.kind.as_str() {
        "chief" => HomeKind::Chief,
        "dm" => HomeKind::Direct,
        _ if entry.title.is_empty() => HomeKind::Group,
        _ => HomeKind::Channel,
    };
    let name = if !entry.title.is_empty() {
        entry.title.clone()
    } else if kind == HomeKind::Chief {
        CHIEF_NAME.to_string()
    } else {
        String::new()
    };
    Some(HomeRow {
        id: entry.conversation.clone(),
        owner: OWNER_CLOUD,
        kind,
        name,
        unread: entry.unread,
        activity_at: entry.last_at.clone(),
        preview: (!entry.preview.is_empty())
            .then(|| entry.preview.chars().take(PREVIEW_CHARS).collect()),
        last_author: None,
        chief: (kind == HomeKind::Chief).then(|| entry.dm_peer.clone()).flatten(),
        chief_state: None,
        pinned: entry.pinned,
        pin_position: entry.pin_position.filter(|_| entry.pinned),
        marked_unread: entry.marked_unread,
        muted: entry.muted && entry.muted_until.is_none_or(|until| until > now_ms),
    })
}

/// Local and Cloud rows in one list order.
pub fn merge_rows(mut rows: Vec<HomeRow>, cloud: Vec<HomeRow>) -> Vec<HomeRow> {
    rows.extend(cloud);
    rows.sort_by(order);
    rows
}

fn order(a: &HomeRow, b: &HomeRow) -> Ordering {
    match (a.pinned, b.pinned) {
        (true, false) => return Ordering::Less,
        (false, true) => return Ordering::Greater,
        (true, true) => {
            let position = |row: &HomeRow| row.pin_position.unwrap_or(u64::MAX);
            let by = position(a).cmp(&position(b));
            if by != Ordering::Equal {
                return by;
            }
        }
        (false, false) => {}
    }
    activity_key(b).cmp(&activity_key(a)).then_with(|| a.id.cmp(&b.id))
}

/// A time's sort key: RFC 3339 UTC text sorts as text once its fraction has
/// exactly three digits (the Cloud owner may leave them out or write more).
fn activity_key(row: &HomeRow) -> std::borrow::Cow<'_, str> {
    let at = row.activity_at.as_str();
    let Some(body) = at.strip_suffix('Z').filter(|body| body.len() >= 19) else {
        return std::borrow::Cow::Borrowed(at);
    };
    let (seconds, fraction) = body.split_at(19);
    let digits = fraction.strip_prefix('.').unwrap_or(fraction);
    if digits.len() == 3 || !digits.bytes().all(|byte| byte.is_ascii_digit()) {
        return std::borrow::Cow::Borrowed(at);
    }
    let millis: String = digits.chars().chain(std::iter::repeat('0')).take(3).collect();
    std::borrow::Cow::Owned(format!("{seconds}.{millis}Z"))
}
