//! `HomeInboxMapping` and `HomeInboxSource`: the owner's `home-inbox` rows as the Messages list's
//! rows, and the list source's decisions (which events read again, which reply is kept, what a pin,
//! mark or mute edit shows and sends). I/O, the read loop and the write tasks stay in Swift.

use crate::ops::{self, OpError};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};

// MARK: wire

/// `HomeInboxRequest.Row`: one owner row, snake_case as the daemon sends it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Row {
    pub id: String,
    /// `chief`, `direct`, `channel` or `group`.
    pub kind: String,
    pub name: String,
    pub unread: i64,
    pub activity_at: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub preview: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_author: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub chief: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub chief_state: Option<String>,
    pub pinned: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pin_position: Option<u64>,
    pub marked_unread: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub owner: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub muted: Option<bool>,
}

/// `HomeInboxRequest.Response`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Response {
    pub me: String,
    pub rows: Vec<Row>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cloud: Option<String>,
}

/// `ConversationInboxOpRequest.Op`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct InboxOp {
    pub kind: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub pinned: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub position: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub unread: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub muted: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub until: Option<u64>,
}

impl InboxOp {
    fn empty(kind: &str) -> Self {
        Self {
            kind: kind.into(),
            pinned: None,
            position: None,
            unread: None,
            muted: None,
            until: None,
        }
    }

    /// `Op.pin`: a pin without a position goes after the caller's last pin.
    pub fn pin(pinned: bool, position: Option<u64>) -> Self {
        Self {
            pinned: Some(pinned),
            position: position.filter(|_| pinned),
            ..Self::empty("inbox.pin")
        }
    }

    /// `Op.markUnread`.
    pub fn mark_unread(unread: bool) -> Self {
        Self { unread: Some(unread), ..Self::empty("inbox.mark_unread") }
    }

    /// `Op.mute` (Cloud rows only).
    pub fn mute(muted: bool, until: Option<u64>) -> Self {
        Self { muted: Some(muted), until: until.filter(|_| muted), ..Self::empty("inbox.mute") }
    }
}

// MARK: HomeInboxMapping

/// A row of the Messages list as `HomeInboxMapping` reads it (`InboxRow`): the fields the mapping
/// reads or changes. `kind` is `ConversationSummary.Kind`'s raw value; `timestamp` is seconds.
#[derive(Debug, Clone, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ListedRow {
    pub id: String,
    pub kind: String,
    #[serde(default)]
    pub is_pinned: bool,
    pub timestamp: f64,
    /// `summary.lastMessage != nil`.
    #[serde(default)]
    pub has_last_message: bool,
    #[serde(default)]
    pub preview: String,
    #[serde(default)]
    pub title: String,
    /// `summary.muted`.
    #[serde(default)]
    pub muted: bool,
}

/// `HomePins` (CmuxNextHomeModel): this Mac's own pins of the rows the owner does not list.
#[derive(Debug, Clone, Default, PartialEq, Eq, Deserialize)]
pub struct Pins {
    #[serde(default)]
    pub pinned: Vec<String>,
    #[serde(default)]
    pub unpinned: BTreeSet<String>,
    #[serde(default)]
    pub positions: BTreeMap<String, u64>,
}

impl Pins {
    /// `HomePins.isPinned`.
    pub fn is_pinned(&self, row: &ListedRow) -> bool {
        if self.pinned.contains(&row.id) {
            return true;
        }
        if self.unpinned.contains(&row.id) {
            return false;
        }
        row.kind == "chief" || row.is_pinned
    }

    /// `HomePins.split`: the pinned rows (the user's order, then default pins in row order), and the
    /// others newest first (ties by id).
    pub fn split<'a>(&self, rows: &[&'a ListedRow]) -> (Vec<&'a ListedRow>, Vec<&'a ListedRow>) {
        let mut order: HashMap<&str, usize> = HashMap::new();
        for (index, id) in self.pinned.iter().enumerate() {
            order.entry(id.as_str()).or_insert(index);
        }
        let mut pinned: Vec<(usize, &ListedRow)> =
            rows.iter().copied().filter(|row| self.is_pinned(row)).enumerate().collect();
        pinned.sort_by_key(|(offset, row)| {
            (order.get(row.id.as_str()).copied().unwrap_or(usize::MAX), *offset)
        });
        let mut rest: Vec<&ListedRow> =
            rows.iter().copied().filter(|row| !self.is_pinned(row)).collect();
        rest.sort_by(|a, b| b.timestamp.total_cmp(&a.timestamp).then_with(|| a.id.cmp(&b.id)));
        (pinned.into_iter().map(|(_, row)| row).collect(), rest)
    }
}

/// What the mapping changed on an owned row (absent fields stay as listed).
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RowPatch {
    pub kind: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub preview: Option<String>,
    pub unread: i64,
    pub is_pinned: bool,
    pub muted: bool,
}

/// One row of the list, in order: a listed row's id, with its patch when the owner lists it.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct MappedRow {
    pub id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub patch: Option<RowPatch>,
}

/// `HomeInboxMapping`'s result. `pinned` and `unreadMarks` are sets (sorted here).
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Mapping {
    pub rows: Vec<MappedRow>,
    pub pinned: Vec<String>,
    pub unread_marks: Vec<String>,
}

/// `HomeInboxMapping.kind`: a channel draws as a group.
pub fn home_kind(kind: &str) -> &'static str {
    match kind {
        "chief" => "chief",
        "direct" => "direct",
        _ => "group",
    }
}

/// `HomeInboxMapping.init`: each owned row is the store's row with the owner's kind, name, unread,
/// pin and mark, in the owner's order; the rows the owner does not list keep this Mac's pins and
/// marks (pins among the owner's by drag position, the rest among the unpinned rows by time).
pub fn map_rows(
    owned: &[Row],
    listed: &[ListedRow],
    pins: &Pins,
    marks: &BTreeSet<String>,
) -> Mapping {
    let mut by_id: HashMap<&str, &ListedRow> = HashMap::new();
    for row in listed {
        by_id.entry(row.id.as_str()).or_insert(row);
    }
    let mut pinned: BTreeSet<String> = BTreeSet::new();
    let mut unread_marks: BTreeSet<String> = BTreeSet::new();
    let mut owned_pinned: Vec<(MappedRow, Option<u64>)> = Vec::new();
    let mut owned_rest: Vec<(MappedRow, f64)> = Vec::new();
    for row in owned {
        let Some(listed) = by_id.get(row.id.as_str()) else {
            continue;
        };
        let title = (!row.name.is_empty() && !super::is_home_internal_id(&row.name))
            .then(|| row.name.clone());
        let preview = row
            .preview
            .as_ref()
            .filter(|preview| {
                !listed.has_last_message && listed.preview.is_empty() && !preview.is_empty()
            })
            .cloned();
        let patch = RowPatch {
            kind: home_kind(&row.kind).into(),
            title,
            preview,
            unread: row.unread,
            is_pinned: row.pinned,
            muted: row.muted.unwrap_or(listed.muted),
        };
        let mapped = MappedRow { id: listed.id.clone(), patch: Some(patch) };
        if row.marked_unread {
            unread_marks.insert(listed.id.clone());
        }
        if row.pinned {
            pinned.insert(listed.id.clone());
            owned_pinned.push((mapped, row.pin_position));
        } else {
            owned_rest.push((mapped, listed.timestamp));
        }
    }
    let owned_ids: HashSet<&str> = owned.iter().map(|row| row.id.as_str()).collect();
    let others: Vec<&ListedRow> =
        listed.iter().filter(|row| !owned_ids.contains(row.id.as_str())).collect();
    let (other_pinned, other_rest) = pins.split(&others);
    pinned.extend(other_pinned.iter().map(|row| row.id.clone()));
    for row in &others {
        if marks.contains(&row.id) {
            unread_marks.insert(row.id.clone());
        }
    }
    let unmapped = |row: &ListedRow| MappedRow { id: row.id.clone(), patch: None };
    let mut all_pinned: Vec<(usize, MappedRow, Option<u64>)> = owned_pinned
        .into_iter()
        .chain(other_pinned.iter().map(|row| (unmapped(row), pins.positions.get(&row.id).copied())))
        .enumerate()
        .map(|(offset, (row, position))| (offset, row, position))
        .collect();
    all_pinned.sort_by_key(|(offset, _, position)| (position.unwrap_or(u64::MAX), *offset));
    let mut rows: Vec<MappedRow> = all_pinned.into_iter().map(|(_, row, _)| row).collect();
    let others: Vec<(MappedRow, f64)> =
        other_rest.iter().map(|row| (unmapped(row), row.timestamp)).collect();
    rows.extend(merged(owned_rest, others));
    Mapping {
        rows,
        pinned: pinned.into_iter().collect(),
        unread_marks: unread_marks.into_iter().collect(),
    }
}

/// `HomeInboxMapping.merged`: two newest-first lists as one, the owner's order kept; another row
/// goes before an owned row only when it is newer.
fn merged<T>(owned: Vec<(T, f64)>, others: Vec<(T, f64)>) -> Vec<T> {
    let mut result = Vec::with_capacity(owned.len() + others.len());
    let mut owned = owned.into_iter().peekable();
    let mut others = others.into_iter().peekable();
    loop {
        let take_other = match (owned.peek(), others.peek()) {
            (None, None) => break,
            (_, None) => false,
            (None, Some(_)) => true,
            (Some((_, o)), Some((_, c))) => c > o,
        };
        let next = if take_other { others.next() } else { owned.next() };
        if let Some((row, _)) = next {
            result.push(row);
        }
    }
    result
}

/// `HomeInboxMapping.ordered`: several owners' rows as one list. With one non-empty list, its own
/// order; else pinned rows by pin position (none last, then id), then the rest newest first (id).
pub fn ordered(lists: &[Vec<Row>]) -> Vec<Row> {
    let all: Vec<Row> = lists.iter().flatten().cloned().collect();
    if lists.iter().filter(|list| !list.is_empty()).count() <= 1 {
        return all;
    }
    let mut pinned: Vec<Row> = all.iter().filter(|row| row.pinned).cloned().collect();
    pinned.sort_by(|a, b| {
        (a.pin_position.unwrap_or(u64::MAX), &a.id)
            .cmp(&(b.pin_position.unwrap_or(u64::MAX), &b.id))
    });
    let mut rest: Vec<(String, Row)> = all
        .into_iter()
        .filter(|row| !row.pinned)
        .map(|row| (time_key(&row.activity_at), row))
        .collect();
    rest.sort_by(|(ka, a), (kb, b)| kb.cmp(ka).then_with(|| a.id.cmp(&b.id)));
    pinned.extend(rest.into_iter().map(|(_, row)| row));
    pinned
}

/// `HomeInboxMapping.timeKey`: an RFC 3339 UTC time with exactly three fraction digits, so two
/// owners' times sort as text (`...:07Z` is `...:07.000`).
pub fn time_key(time: &str) -> String {
    let plain = time.strip_suffix('Z').unwrap_or(time);
    // Swift's `split(separator: ".", maxSplits: 1)`: empty pieces dropped, at most one split made.
    let mut parts: Vec<&str> = Vec::new();
    let mut start = 0;
    for (index, ch) in plain.char_indices() {
        if ch == '.' {
            if let Some(piece) = plain.get(start..index).filter(|piece| !piece.is_empty()) {
                parts.push(piece);
            }
            start = index + 1;
            if parts.len() == 1 {
                break;
            }
        }
    }
    if let Some(piece) = plain.get(start..).filter(|piece| !piece.is_empty()) {
        parts.push(piece);
    }
    let fraction: String = parts.get(1).map(|f| f.chars().take(3).collect()).unwrap_or_default();
    let padded: String = fraction.chars().chain(std::iter::repeat('0')).take(3).collect();
    format!("{}.{padded}", parts.first().copied().unwrap_or_default())
}

// MARK: HomeInboxSource

/// The `DaemonEvent` cases `HomeInboxSource.note` looks at.
#[derive(Debug, Clone, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum SourceEvent {
    ConversationChanged,
    /// `.unknown(name, _)`.
    Unknown {
        name: String,
    },
    /// `.cloudConversations(event)`: the event's case name (`inboxChanged`, `inboxReset`, ...).
    CloudConversations {
        event: String,
    },
    #[serde(other)]
    Other,
}

/// `HomeInboxSource.rowEvents`.
pub const ROW_EVENTS: &[&str] = &["conversation-inbox-changed", "chief-changed"];

/// `HomeInboxSource.note`: whether the event asks for the rows again.
pub fn note(event: &SourceEvent, is_cloud: bool) -> bool {
    match event {
        SourceEvent::ConversationChanged => !is_cloud,
        SourceEvent::Unknown { name } => ROW_EVENTS.contains(&name.as_str()) && !is_cloud,
        SourceEvent::CloudConversations { event } => {
            is_cloud
                && matches!(
                    event.as_str(),
                    "inboxChanged" | "inboxReset" | "resynced" | "subscriptionState"
                )
        }
        SourceEvent::Other => false,
    }
}

/// `HomeInboxSource.accept`'s outcome.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Accepted {
    /// False: an edit is unanswered; nothing changes.
    pub kept: bool,
    /// The reply to hold (`kept` only).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reply: Option<Response>,
    /// The held reply changes (assign only then: it is observed).
    pub changed: bool,
}

/// `HomeInboxSource.accept`: an owner reply is kept unless an edit is unanswered; a Cloud that did
/// not answer keeps the last rows.
pub fn accept(current: Option<&Response>, next: Response, pending_writes: u64) -> Accepted {
    let mut next = next;
    if next.cloud.as_deref() == Some("unavailable")
        && let Some(last) = current
    {
        next.rows = last.rows.clone();
    }
    if pending_writes > 0 {
        return Accepted { kept: false, reply: None, changed: false };
    }
    let changed = current != Some(&next);
    Accepted { kept: true, reply: Some(next), changed }
}

/// `HomeInboxSource.seed`: the last launch's rows, only before the owner answered and with none held.
pub fn seed(
    answered: bool,
    current: Option<&Response>,
    last: Option<Response>,
) -> Option<Response> {
    if answered || current.is_some() {
        return None;
    }
    last
}

/// A list edit (`HomeInboxSource.setPinned`, `place`, `adopt`, `setMarkedUnread`, `setMuted`,
/// `canMute`).
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Edit {
    SetPinned { on: bool, id: String },
    Place { positions: Vec<Placed> },
    Adopt { ids: Vec<String> },
    SetMarkedUnread { on: bool, id: String },
    SetMuted { on: bool, id: String },
    CanMute { id: String },
}

#[derive(Debug, Clone, Deserialize)]
pub struct Placed {
    pub id: String,
    pub position: u64,
}

/// One op to send, in order.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Write {
    pub conversation: String,
    pub op: InboxOp,
}

/// An edit's outcome: the rows to show now, the ops to send (to `command`), and `canMute`'s answer.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Edited {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reply: Option<Response>,
    pub writes: Vec<Write>,
    /// `cloud-inbox-op` or `conversation-inbox-op`.
    pub command: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub can_mute: Option<bool>,
}

fn first_unpinned(rows: &[Row]) -> usize {
    rows.iter().position(|row| !row.pinned).unwrap_or(rows.len())
}

fn edit_row(reply: &mut Option<Response>, id: &str, change: impl FnOnce(&mut Row)) {
    if let Some(row) =
        reply.as_mut().and_then(|reply| reply.rows.iter_mut().find(|row| row.id == id))
    {
        change(row);
    }
}

fn place(reply: &mut Option<Response>, positions: &[Placed]) -> Vec<Write> {
    let Some(reply) = reply.as_mut() else {
        return Vec::new();
    };
    let placed: HashSet<&str> = positions.iter().map(|p| p.id.as_str()).collect();
    let pinned: Vec<Row> = positions
        .iter()
        .filter_map(|place| {
            let mut row = reply.rows.iter().find(|row| row.id == place.id)?.clone();
            row.pinned = true;
            row.pin_position = Some(place.position);
            Some(row)
        })
        .collect();
    reply.rows.retain(|row| !placed.contains(row.id.as_str()));
    let at = first_unpinned(&reply.rows);
    let writes = pinned
        .iter()
        .map(|row| Write { conversation: row.id.clone(), op: InboxOp::pin(true, row.pin_position) })
        .collect();
    reply.rows.splice(at..at, pinned);
    writes
}

/// Applies one edit to the held reply. `now` is milliseconds since 1970 (`HomeInboxSource.now`).
pub fn edit(reply: Option<Response>, is_cloud: bool, now: u64, edit: &Edit) -> Edited {
    let mut reply = reply;
    let command = if is_cloud { "cloud-inbox-op" } else { "conversation-inbox-op" };
    let row = |reply: &Option<Response>, id: &str| -> Option<Row> {
        reply.as_ref().and_then(|reply| reply.rows.iter().find(|row| row.id == id).cloned())
    };
    let mut can_mute = None;
    let writes = match edit {
        Edit::SetPinned { on, id } => {
            if *on && row(&reply, id).is_some_and(|row| row.pinned) {
                Vec::new()
            } else {
                edit_row(&mut reply, id, |row| {
                    row.pinned = *on;
                    row.pin_position = on.then_some(now);
                });
                if *on
                    && let Some(reply) = reply.as_mut()
                    && let Some(index) = reply.rows.iter().position(|row| row.id == *id)
                {
                    let moved = reply.rows.remove(index);
                    let at = first_unpinned(&reply.rows);
                    reply.rows.insert(at, moved);
                }
                vec![Write { conversation: id.clone(), op: InboxOp::pin(*on, on.then_some(now)) }]
            }
        }
        Edit::Place { positions } => place(&mut reply, positions),
        Edit::Adopt { ids } => {
            let positions: Vec<Placed> = ids
                .iter()
                .enumerate()
                .map(|(offset, id)| Placed { id: id.clone(), position: now + offset as u64 })
                .collect();
            place(&mut reply, &positions)
        }
        Edit::SetMarkedUnread { on, id } => match row(&reply, id) {
            Some(row) if row.marked_unread != *on => {
                edit_row(&mut reply, id, |row| row.marked_unread = *on);
                vec![Write { conversation: id.clone(), op: InboxOp::mark_unread(*on) }]
            }
            _ => Vec::new(),
        },
        Edit::SetMuted { on, id } => match row(&reply, id) {
            Some(row) if is_cloud && row.muted.unwrap_or(false) != *on => {
                edit_row(&mut reply, id, |row| row.muted = Some(*on));
                vec![Write { conversation: id.clone(), op: InboxOp::mute(*on, None) }]
            }
            _ => Vec::new(),
        },
        Edit::CanMute { id } => {
            can_mute = Some(is_cloud && row(&reply, id).is_some());
            Vec::new()
        }
    };
    Edited { reply, writes, command, can_mute }
}

// MARK: ops

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RowsRequest {
    #[serde(default)]
    owned: Vec<Row>,
    listed: Vec<ListedRow>,
    #[serde(default)]
    pins: Pins,
    #[serde(default)]
    unread_marks: BTreeSet<String>,
}

/// `mapping.inboxRows {owned, listed, pins, unreadMarks}` → `{rows, pinned, unreadMarks}`.
pub fn rows_op(request: &Value) -> Result<Value, OpError> {
    let request: RowsRequest = ops::parse(request)?;
    ops::reply(&map_rows(&request.owned, &request.listed, &request.pins, &request.unread_marks))
}

#[derive(Deserialize)]
struct OrderedRequest {
    lists: Vec<Vec<Row>>,
}

#[derive(Serialize)]
struct RowsReply {
    rows: Vec<Row>,
}

/// `mapping.inboxOrdered {lists}` → `{rows}`.
pub fn ordered_op(request: &Value) -> Result<Value, OpError> {
    let request: OrderedRequest = ops::parse(request)?;
    ops::reply(&RowsReply { rows: ordered(&request.lists) })
}

#[derive(Deserialize)]
struct TimeKeyRequest {
    time: String,
}

#[derive(Serialize)]
struct KeyReply {
    key: String,
}

/// `mapping.timeKey {time}` → `{key}`.
pub fn time_key_op(request: &Value) -> Result<Value, OpError> {
    let request: TimeKeyRequest = ops::parse(request)?;
    ops::reply(&KeyReply { key: time_key(&request.time) })
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct NoteRequest {
    event: SourceEvent,
    is_cloud: bool,
}

#[derive(Serialize)]
struct NoteReply {
    refresh: bool,
}

/// `mapping.inboxNote {event: {kind, name?, event?}, isCloud}` → `{refresh}`.
pub fn note_op(request: &Value) -> Result<Value, OpError> {
    let request: NoteRequest = ops::parse(request)?;
    ops::reply(&NoteReply { refresh: note(&request.event, request.is_cloud) })
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct AcceptRequest {
    #[serde(default)]
    current: Option<Response>,
    next: Response,
    #[serde(default)]
    pending_writes: u64,
}

/// `mapping.inboxAccept {current?, next, pendingWrites}` → `{kept, reply?, changed}`.
pub fn accept_op(request: &Value) -> Result<Value, OpError> {
    let request: AcceptRequest = ops::parse(request)?;
    ops::reply(&accept(request.current.as_ref(), request.next, request.pending_writes))
}

#[derive(Deserialize)]
struct SeedRequest {
    answered: bool,
    #[serde(default)]
    current: Option<Response>,
    #[serde(default)]
    last: Option<Response>,
}

#[derive(Serialize)]
struct SeedReply {
    reply: Option<Response>,
}

/// `mapping.inboxSeed {answered, current?, last?}` → `{reply}` (null: keep what is held).
pub fn seed_op(request: &Value) -> Result<Value, OpError> {
    let request: SeedRequest = ops::parse(request)?;
    ops::reply(&SeedReply { reply: seed(request.answered, request.current.as_ref(), request.last) })
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct EditRequest {
    #[serde(default)]
    reply: Option<Response>,
    is_cloud: bool,
    now: u64,
    edit: Edit,
}

/// `mapping.inboxEdit {reply?, isCloud, now, edit}` → `{reply?, writes, command, canMute?}`.
pub fn edit_op(request: &Value) -> Result<Value, OpError> {
    let request: EditRequest = ops::parse(request)?;
    ops::reply(&edit(request.reply, request.is_cloud, request.now, &request.edit))
}
