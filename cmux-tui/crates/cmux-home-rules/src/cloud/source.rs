//! The cloud Home source's decisions (`CloudHomeSource*.swift`): which
//! events belong to the account, the inbox list's paging and merge, the
//! head-hydration queue, when an intent's key is released, the keys an
//! intent's several ops derive, the masked address, and the message
//! request rows and answers. The daemon calls stay in each app.

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};
use std::collections::{BTreeMap, BTreeSet};

use super::lease::cloud_id;

/// `CloudHomeSource.inboxPages`: one inbox read lists at most this many pages.
pub const INBOX_PAGES: u32 = 50;
/// `CloudHomeSource.hydrationWidth`: head reads at once for the whole source.
pub const HYDRATION_WIDTH: u32 = 4;

// MARK: Events

/// The account fields of a `CloudConversationsEvent`.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EventAccount {
    /// changed, resynced, inboxChanged, inboxReset, subscriptionState,
    /// sessionNeeded, hostReplicaNeeded, live, runChanged, typing.
    pub kind: String,
    #[serde(default)]
    pub account: Option<String>,
}

/// `CloudHomeSource.isForAccount`: a data event without an account is
/// refused; a socket state or inbox reset without one is kept.
pub fn is_for_account(event: &EventAccount, cloud: Option<&str>) -> bool {
    let matches = |account: &str| cloud == Some(cloud_id(account).as_str());
    match event.kind.as_str() {
        "inboxReset" | "subscriptionState" => event.account.as_deref().is_none_or(matches),
        "sessionNeeded" | "hostReplicaNeeded" => true,
        _ => event.account.as_deref().is_some_and(matches),
    }
}

/// `CloudHomeSource.revision`: an inbox list's revision as the stream seq.
pub fn revision(value: Option<&Value>) -> Option<u64> {
    match value? {
        Value::String(text) => text.parse().ok(),
        Value::Number(n) => {
            if let Some(u) = n.as_u64() {
                return Some(u);
            }
            let f = n.as_f64()?;
            ((0.0..1.8e19).contains(&f) && f.round() == f).then_some(f as u64)
        }
        _ => None,
    }
}

// MARK: Inbox paging

fn conversation_of(entry: &Value) -> Option<&str> {
    entry.get("conversation")?.as_str()
}

/// `cloud.source_inbox_page` request: the list read so far, the page just
/// read after `cursor`, and how many pages the list holds (the first is 1).
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PageRequest {
    #[serde(default)]
    pub entries: Vec<Value>,
    #[serde(default)]
    pub cursor: Option<String>,
    #[serde(default)]
    pub page: Option<Page>,
    #[serde(default = "one")]
    pub pages: u32,
}

fn one() -> u32 {
    1
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Page {
    #[serde(default)]
    pub entries: Vec<Value>,
    #[serde(default)]
    pub next_cursor: Option<String>,
}

/// The list with the page joined, and the cursor of the next read (nil:
/// the list is whole).
#[derive(Debug, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct PageReply {
    pub entries: Vec<Value>,
    pub next_cursor: Option<String>,
    pub pages: u32,
}

/// One step of `allPages`: an entry a later page lists again keeps the
/// first copy; a cursor that does not move ends the read; at most
/// `INBOX_PAGES` pages are read.
pub fn inbox_page(req: PageRequest) -> PageReply {
    let mut entries = req.entries;
    let Some(page) = req.page else {
        return PageReply { entries, next_cursor: None, pages: req.pages };
    };
    let mut seen: BTreeSet<String> =
        entries.iter().filter_map(conversation_of).map(str::to_owned).collect();
    for entry in page.entries {
        if let Some(id) = conversation_of(&entry)
            && seen.insert(id.to_owned())
        {
            entries.push(entry);
        }
    }
    let pages = req.pages + 1;
    let next_cursor = match page.next_cursor {
        Some(next) if Some(&next) != req.cursor.as_ref() && pages < INBOX_PAGES => Some(next),
        _ => None,
    };
    PageReply { entries, next_cursor, pages }
}

// MARK: Inbox merge

fn is_listed(entry: &Value) -> bool {
    let flag = |key: &str| entry.get(key).and_then(Value::as_bool).unwrap_or(false);
    !flag("removed") && !flag("archived")
}

fn last_seq(entry: &Value) -> u64 {
    entry.get("last_seq").and_then(Value::as_u64).unwrap_or(0)
}

/// `cloud.source_inbox_merge` request: a whole inbox list and the state
/// it lands on (`CloudHomeState`'s inbox fields).
#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MergeRequest {
    /// The list's entries (wire form, `conversation`, `removed`, `archived`, `last_seq`).
    #[serde(default)]
    pub list: Vec<Value>,
    #[serde(default)]
    pub revision: Option<Value>,
    /// The entries known before the list, by conversation.
    #[serde(default)]
    pub entries: BTreeMap<String, Value>,
    /// Inbox events since the read, conversation -> stream seq.
    #[serde(default)]
    pub touched: BTreeMap<String, u64>,
    #[serde(default)]
    pub created: BTreeSet<String>,
    #[serde(default)]
    pub removed: BTreeSet<String>,
    #[serde(default)]
    pub closed: BTreeSet<String>,
    /// Conversations with a subscription.
    #[serde(default)]
    pub targets: BTreeSet<String>,
    /// The known heads' last seq.
    #[serde(default)]
    pub heads: BTreeMap<String, u64>,
}

#[derive(Debug, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct MergeReply {
    pub entries: BTreeMap<String, Value>,
    pub touched: BTreeMap<String, u64>,
    pub created: BTreeSet<String>,
    pub removed: BTreeSet<String>,
    pub closed: BTreeSet<String>,
    /// Known before, not listed now: their heads and subscriptions are forgotten.
    pub gone: Vec<String>,
    /// The gone ones with a subscription to end.
    pub unlisted: Vec<String>,
    /// The listed conversations to hydrate (`missingHeads`).
    pub missing: Vec<String>,
}

/// `CloudHomeState.needsHead`: listed, unsubscribed, and no head as new as the entry.
pub fn needs_head(
    id: &str,
    entries: &BTreeMap<String, Value>,
    targets: &BTreeSet<String>,
    heads: &BTreeMap<String, u64>,
) -> bool {
    let Some(entry) = entries.get(id) else { return false };
    if targets.contains(id) {
        return false;
    }
    heads.get(id).is_none_or(|&head| last_seq(entry) > head)
}

/// The `inbox()` merge: an inbox event newer than the list wins; listed
/// again clears created, removed and closed; known and no longer listed is gone.
pub fn inbox_merge(req: MergeRequest) -> MergeReply {
    let mut entries: BTreeMap<String, Value> = BTreeMap::new();
    for entry in req.list.into_iter().filter(is_listed) {
        if let Some(id) = conversation_of(&entry).map(str::to_owned) {
            entries.insert(id, entry);
        }
    }
    let mut touched = req.touched;
    if let Some(rev) = revision(req.revision.as_ref()) {
        for (id, &seq) in &touched {
            if seq > rev {
                match req.entries.get(id) {
                    Some(known) => entries.insert(id.clone(), known.clone()),
                    None => entries.remove(id),
                };
            }
        }
        touched.retain(|_, seq| *seq > rev);
    }
    let mut created = req.created;
    let mut removed = req.removed;
    let mut closed = req.closed;
    created.retain(|id| !entries.contains_key(id));
    removed.retain(|id| !entries.contains_key(id));
    closed.retain(|id| !entries.contains_key(id) || req.entries.contains_key(id));
    let gone: Vec<String> = req
        .entries
        .keys()
        .filter(|id| !entries.contains_key(*id) && !created.contains(*id))
        .cloned()
        .collect();
    removed.extend(gone.iter().cloned());
    let mut targets = req.targets;
    let mut heads = req.heads;
    let unlisted: Vec<String> = gone
        .iter()
        .filter(|id| {
            heads.remove(*id);
            targets.remove(*id)
        })
        .cloned()
        .collect();
    let missing =
        entries.keys().filter(|id| needs_head(id, &entries, &targets, &heads)).cloned().collect();
    MergeReply { entries, touched, created, removed, closed, gone, unlisted, missing }
}

// MARK: Hydration

/// `cloud.source_hydrate`: the queue state and the conversations to queue.
#[derive(Debug, Default, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Hydration {
    #[serde(default)]
    pub hydrating: BTreeSet<String>,
    #[serde(default)]
    pub queue: Vec<String>,
    #[serde(default)]
    pub workers: u32,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HydrateRequest {
    #[serde(default)]
    pub state: Hydration,
    #[serde(default)]
    pub ids: Vec<String>,
}

#[derive(Debug, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct HydrateReply {
    pub state: Hydration,
    /// Workers to start now.
    pub start: u32,
}

/// `hydrate`: each conversation waits once; at most `HYDRATION_WIDTH` workers.
pub fn hydrate(req: HydrateRequest) -> HydrateReply {
    let mut state = req.state;
    for id in req.ids {
        if state.hydrating.insert(id.clone()) {
            state.queue.push(id);
        }
    }
    let room = HYDRATION_WIDTH.saturating_sub(state.workers);
    let start = room.min(u32::try_from(state.queue.len()).unwrap_or(u32::MAX));
    state.workers += start;
    HydrateReply { state, start }
}

// MARK: Submit

/// Whether `submit` releases an intent's bound key: committed, or refused
/// for good (`isFinal`) and not a send (the user may send it again).
pub fn releases_key(op: &str, rejection: Option<&super::reply::Rejection>) -> bool {
    match rejection {
        None => true,
        Some(rejection) => rejection.is_final() && op != "sendMessage",
    }
}

/// The idempotency keys an intent's ops take (`CloudHomeSource+Ops`).
#[derive(Debug, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct DerivedKeys {
    /// One per `participants.add`: a single add keeps the intent's key.
    pub participants: Vec<String>,
    /// One per `invite.create`.
    pub invites: Vec<String>,
    /// The first message of a new conversation.
    pub message: String,
}

pub fn derived_keys(key: &str, participants: usize, invites: usize) -> DerivedKeys {
    DerivedKeys {
        participants: if participants == 1 {
            vec![key.to_owned()]
        } else {
            (0..participants).map(|i| format!("{key}:add:{i}")).collect()
        },
        invites: (0..invites).map(|i| format!("{key}:invite:{i}")).collect(),
        message: format!("{key}:message"),
    }
}

// MARK: Addresses

/// A contact address (`ContactAddress`).
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Contact {
    Email(String),
    Phone(String),
}

/// `CloudHomeSource.masked` (home-core `maskAddress`).
pub fn masked(contact: &Contact) -> String {
    match contact {
        Contact::Email(value) => match value.split_once('@') {
            Some((local, domain)) => {
                let first: String = local.chars().take(1).collect();
                format!("{first}***@{domain}")
            }
            None => "***".to_owned(),
        },
        Contact::Phone(value) => {
            let Some(digits) = value.strip_prefix('+') else { return "***".to_owned() };
            let count = digits.chars().count();
            if !(11..=15).contains(&count) || !digits.chars().all(|c| c.is_ascii_digit()) {
                return "***".to_owned();
            }
            let country = &digits[..count - 10];
            let last = &value[value.len() - 4..];
            format!("+{country} *** *** {last}")
        }
    }
}

// MARK: Message requests

const HOME_ID_PREFIXES: &[&str] =
    &["addr", "user", "agent", "conv", "inv", "msg", "team", "inst", "grant", "task", "vm"];

/// `String.isHomeInternalID`.
pub fn is_home_internal_id(text: &str) -> bool {
    let Some((prefix, rest)) = text.split_once('_') else { return false };
    HOME_ID_PREFIXES.contains(&prefix)
        && !rest.is_empty()
        && rest.chars().all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-')
}

/// `CloudHomeSource.request`: a row without a conversation or a readable
/// inviter is dropped; a title that is an internal id is left out.
pub fn message_request(row: &Value) -> Option<Value> {
    let text = |key: &str| row.get(key).and_then(Value::as_str).unwrap_or_default();
    let conversation = text("conversation");
    let inviter = text("inviter");
    if conversation.is_empty() || inviter.is_empty() || is_home_internal_id(inviter) {
        return None;
    }
    let mut out = Map::new();
    out.insert("conversation".into(), json!(conversation));
    out.insert("inviter".into(), json!(inviter));
    let title = row.get("title").and_then(Value::as_str).filter(|t| !is_home_internal_id(t));
    out.insert("title".into(), json!(title));
    for key in ["isGroup", "preview", "createdAt", "trusted"] {
        out.insert(key.into(), row.get(key).cloned().unwrap_or(Value::Null));
    }
    Some(Value::Object(out))
}

/// `answer`: the op an answer sends, and whether the inbox reloads after.
pub fn answer_op(answer: &str) -> Option<Value> {
    Some(match answer {
        "accept" => json!({ "op": { "kind": "acceptRequest" }, "reloadInbox": true }),
        "decline" => {
            json!({ "op": { "kind": "dismissRequest", "block": false }, "reloadInbox": false })
        }
        "block" => {
            json!({ "op": { "kind": "dismissRequest", "block": true }, "reloadInbox": false })
        }
        _ => return None,
    })
}
