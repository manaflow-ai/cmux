//! The chat list's rows (`HomeSidebarModel`): search, the main Chief first, each row's avatars,
//! preview, badges and VoiceOver parts, the teammates without a DM, and moving between chats.
//! Strings stay Swift's: an item says which words to show (`untitled`, `chiefEmpty`, a list time
//! kind) and Swift words them.

use super::model::{Contact, ContactSource, Roster, Row, RowKind, fold, standard_contains};
use super::pins::Pins;
use super::text::{self, LastMessage, ListTime, Preview};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet, HashSet};

/// How the rows are split into pinned and the rest.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", rename_all_fields = "camelCase", tag = "kind")]
pub enum Order {
    /// `init(rows:pins:)`: the pins split them; the main Chief leads until placed.
    Pins { pins: Pins },
    /// `init(ordered:pinned:)`: already ordered; these ids are pinned.
    Ordered { pinned: BTreeSet<String> },
}

/// `HomeSidebarModel.init`'s inputs (`chiefAvatars` and `chiefHarnesses` stay Swift's: an item
/// names its Chief participant to look them up).
#[derive(Debug, Clone, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Request {
    pub rows: Vec<Row>,
    pub order: Order,
    #[serde(default)]
    pub me: Option<String>,
    #[serde(default)]
    pub query: String,
    #[serde(default)]
    pub contacts: Vec<Contact>,
    #[serde(default)]
    pub unread_marks: BTreeSet<String>,
    #[serde(default)]
    pub roster: Roster,
    /// `chiefNames`: a Chief's own name by conversation.
    #[serde(default)]
    pub chief_names: BTreeMap<String, String>,
    /// `chiefRoster.tag(for:engine:)` by conversation, computed by the caller (ChiefList).
    #[serde(default)]
    pub chief_tags: BTreeMap<String, String>,
    /// `summary.lastMessage` by conversation, Markdown already stripped.
    #[serde(default)]
    pub last_messages: BTreeMap<String, LastMessage>,
    /// Now, seconds since 1970, and the calendar's UTC offset in seconds.
    #[serde(default)]
    pub now: f64,
    #[serde(default)]
    pub utc_offset: f64,
}

/// `HomeAvatar`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Avatar {
    pub initials: String,
    pub seed: String,
}

/// `HomeSidebarPerson`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Person {
    pub id: String,
    pub name: String,
    pub initials: String,
}

/// What the preview line shows.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", rename_all_fields = "camelCase", tag = "kind")]
pub enum ShownPreview {
    /// `homePreview`'s text or reaction.
    Row { preview: Preview },
    /// `HomeConversationStrings.invitedLabel`.
    Invited,
    /// `HomeConversationStrings.waitingFor(name)`.
    WaitingFor { name: String },
    /// `HomeConversationStrings.chiefEmptyPreview` (a Chief row with no preview).
    ChiefEmpty,
}

impl ShownPreview {
    fn is_empty(&self) -> bool {
        matches!(self, Self::Row { preview: Preview::Text { text, .. } } if text.is_empty())
    }
}

/// The tag after a row's name.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", rename_all_fields = "camelCase", tag = "kind")]
pub enum ListBadge {
    /// A Chief's roster tag.
    Tag { text: String },
    /// `HomeConversationStrings.channelTag`.
    Channel,
}

/// One part of the VoiceOver label, joined by ", ".
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", rename_all_fields = "camelCase", tag = "kind")]
pub enum LabelPart {
    Title,
    Badge,
    /// `HomeConversationStrings.unread(count)`.
    Unread {
        count: i64,
    },
    /// `HomeConversationStrings.mentioned`.
    Mentioned,
    Time,
    /// The preview as words (never the Chief's empty-preview text).
    Preview,
}

/// `HomeSidebarItem`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Item {
    pub id: String,
    /// The name; empty with `untitled` set.
    pub title: String,
    pub untitled: bool,
    pub avatars: Vec<Avatar>,
    pub is_group: bool,
    pub badge: Option<String>,
    pub preview: ShownPreview,
    pub is_reply: bool,
    pub time: ListTime,
    pub last_at: f64,
    pub people: Vec<Person>,
    pub is_muted: bool,
    pub unread: bool,
    pub unread_count: i64,
    pub mentions: i64,
    pub is_pinned: bool,
    pub is_chief: bool,
    /// The Chief participant (Swift looks up its avatar and backend badge).
    pub chief: Option<String>,
    pub chief_is_working: bool,
    pub is_main_chief: bool,
    pub place: Option<super::model::ChiefPlace>,
    pub list_badge: Option<ListBadge>,
    pub accessibility: Vec<LabelPart>,
}

/// `HomeSidebarModel`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Model {
    pub pinned: Vec<Item>,
    pub rows: Vec<Item>,
    pub people: Vec<Contact>,
    pub teammates: Vec<Contact>,
}

/// `HomeSidebarModel.nameKey`.
pub fn name_key(name: &str) -> String {
    fold(name.trim())
}

fn item(row: &Row, pinned: bool, request: &Request) -> Item {
    let me = request.me.as_deref();
    let others: Vec<_> = row.others(me).collect();
    let waiting = if row.kind == RowKind::Direct {
        text::invite_waiting(&row.participants, me)
    } else {
        None
    };
    let mut preview = match waiting {
        Some(text::InviteWaiting::Invited) => ShownPreview::Invited,
        Some(text::InviteWaiting::WaitingFor { name }) => ShownPreview::WaitingFor { name },
        None => ShownPreview::Row {
            preview: text::preview(
                &row.preview,
                request.last_messages.get(&row.id),
                &row.participants,
                me,
            ),
        },
    };
    let is_reply =
        matches!(&preview, ShownPreview::Row { preview: Preview::Text { is_reply: true, .. } });
    let said = !preview.is_empty();
    if !said && row.kind == RowKind::Chief {
        preview = ShownPreview::ChiefEmpty;
    }
    let time = text::list_time(row.timestamp, request.now, request.utc_offset);
    let unread = row.unread.max(i64::from(request.unread_marks.contains(&row.id)));
    let mut accessibility = vec![LabelPart::Title];
    if unread > 0 {
        accessibility.push(LabelPart::Unread { count: unread });
    }
    if row.mentions > 0 {
        accessibility.push(LabelPart::Mentioned);
    }
    if time != ListTime::None {
        accessibility.push(LabelPart::Time);
    }
    if said {
        accessibility.push(LabelPart::Preview);
    }
    let is_group = row.kind == RowKind::Group;
    let mut item = Item {
        id: row.id.clone(),
        title: row.title.clone(),
        untitled: row.title.is_empty(),
        avatars: others
            .iter()
            .take(if is_group { 3 } else { 1 })
            .map(|p| Avatar { initials: p.initials(), seed: p.id.clone() })
            .collect(),
        is_group,
        badge: if is_group { others.first().map(|p| p.initials()) } else { None },
        preview,
        is_reply,
        time,
        last_at: row.timestamp,
        people: others
            .iter()
            .map(|p| Person {
                id: p.id.clone(),
                name: p.display_name.clone(),
                initials: p.initials(),
            })
            .collect(),
        is_muted: row.muted,
        unread: unread > 0,
        unread_count: unread,
        mentions: row.mentions,
        is_pinned: pinned,
        is_chief: row.kind == RowKind::Chief,
        chief: None,
        chief_is_working: false,
        is_main_chief: false,
        place: None,
        list_badge: None,
        accessibility,
    };
    if item.is_chief {
        item.chief = row.participants.iter().find(|p| p.is_chief()).map(|p| p.id.clone());
        item.chief_is_working = row.is_typing;
        if let Some(name) = request.chief_names.get(&row.id).map(|n| n.trim())
            && !name.is_empty()
            && (item.untitled || name != item.title)
        {
            item.title = name.to_owned();
            item.untitled = false;
        }
        item.is_main_chief = request.roster.main.as_deref() == Some(row.id.as_str());
        item.place = request.roster.places.get(&row.id).cloned();
        item.list_badge =
            request.chief_tags.get(&row.id).map(|text| ListBadge::Tag { text: text.clone() });
    }
    if row.is_channel && item.list_badge.is_none() {
        item.list_badge = Some(ListBadge::Channel);
    }
    if item.list_badge.is_some() {
        item.accessibility.insert(1, LabelPart::Badge);
    }
    item
}

/// `HomeSidebarModel.init`.
pub fn model(request: &Request) -> Model {
    let me = request.me.as_deref();
    let (pinned_rows, rest, leading): (Vec<&Row>, Vec<&Row>, Option<&str>) = match &request.order {
        Order::Pins { pins } => {
            let (pinned, rest) = pins.split(&request.rows);
            (pinned, rest, pins.leading(request.roster.main.as_deref()))
        }
        Order::Ordered { pinned } => (
            request.rows.iter().filter(|r| pinned.contains(&r.id)).collect(),
            request.rows.iter().filter(|r| !pinned.contains(&r.id)).collect(),
            None,
        ),
    };
    let needle = request.query.trim();
    let keep = |row: &&Row| needle.is_empty() || row.matches(needle, me);
    let mut pinned_rows: Vec<&Row> = pinned_rows.into_iter().filter(keep).collect();
    let rest: Vec<&Row> = rest.into_iter().filter(keep).collect();
    if let Some(at) = leading.and_then(|main| pinned_rows.iter().position(|r| r.id == main)) {
        let main = pinned_rows.remove(at);
        pinned_rows.insert(0, main);
    }
    let pinned_items = pinned_rows.iter().map(|row| item(row, true, request));
    let rest_items = rest.iter().map(|row| item(row, false, request));
    let dms: Vec<&Row> = request.rows.iter().filter(|r| r.kind == RowKind::Direct).collect();
    let dm_peers: HashSet<&str> =
        dms.iter().flat_map(|r| r.participants.iter().map(|p| p.id.as_str())).collect();
    if needle.is_empty() {
        let mut listed: HashSet<String> =
            dms.iter().flat_map(|r| r.others(me).map(|p| name_key(&p.display_name))).collect();
        let teammates = request
            .contacts
            .iter()
            .filter(|c| {
                let key = name_key(&c.name);
                c.source == ContactSource::Team
                    && Some(c.id.as_str()) != me
                    && !dm_peers.contains(c.id.as_str())
                    && (key == "member" || listed.insert(key))
            })
            .cloned()
            .collect();
        Model {
            pinned: pinned_items.collect(),
            rows: rest_items.collect(),
            people: Vec::new(),
            teammates,
        }
    } else {
        Model {
            pinned: Vec::new(),
            rows: pinned_items.chain(rest_items).collect(),
            people: request
                .contacts
                .iter()
                .filter(|c| !dm_peers.contains(c.id.as_str()) && standard_contains(&c.name, needle))
                .cloned()
                .collect(),
            teammates: Vec::new(),
        }
    }
}

/// `HomeSidebarModel.unreadConversations(pinned:rest:unreadMarks:mainChief:)`.
pub fn unread_conversations(
    pinned: &[Row],
    rest: &[Row],
    marks: &BTreeSet<String>,
    main_chief: Option<&str>,
) -> Vec<String> {
    let mut pinned: Vec<&Row> = pinned.iter().collect();
    if let Some(at) = main_chief.and_then(|main| pinned.iter().position(|r| r.id == main)) {
        let main = pinned.remove(at);
        pinned.insert(0, main);
    }
    pinned
        .into_iter()
        .chain(rest)
        .filter(|r| (r.unread > 0 || marks.contains(&r.id)) && !r.muted)
        .map(|r| r.id.clone())
        .collect()
}

/// `HomeSidebarModel.neighbor(of:offset:wrapping:)` over the list order (pinned, then rows).
pub fn neighbor(
    order: &[String],
    current: Option<&str>,
    offset: i64,
    wrapping: bool,
) -> Option<String> {
    let Some(index) = current.and_then(|c| order.iter().position(|id| id == c)) else {
        return order.first().cloned();
    };
    let next = index as i64 + offset;
    let count = order.len() as i64;
    if wrapping {
        return order.get(next.rem_euclid(count) as usize).cloned();
    }
    usize::try_from(next).ok().and_then(|at| order.get(at).cloned())
}

/// `HomeSidebarModel.conversation(number:)`: ⌘1–⌘8 by place, ⌘9 the last.
pub fn conversation_number(order: &[String], number: i64) -> Option<String> {
    let last = order.len().checked_sub(1)?;
    let at = if number >= 9 { last } else { ((number.max(1) - 1) as usize).min(last) };
    order.get(at).cloned()
}
