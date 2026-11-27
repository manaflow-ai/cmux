//! The JSON ops the app calls through the app FFI's JSON channel (cmux-layout-reducer-ffi
//! `cmux_layout_reducer_json`, ops `closed_tabs_*`). Every op is pure: state the app keeps
//! between calls (the seen ids, the recent items, the rate limit, the undo reducer's state)
//! comes in with the request and goes back with the reply. A closed item is the daemon's wire
//! shape ([`crate::item::ClosedItem`]); a machine is a [`Machine`].
//!
//! | op | request | reply |
//! | --- | --- | --- |
//! | `closed_tabs_entries` | `{machines, kinds?}` | `[{machine, item}]`, newest first |
//! | `closed_tabs_entry` | `{machines, id}` | `{machine, item}` or null |
//! | `closed_tabs_group_entry` | `{machines, id}` | `{machine, item}` or null |
//! | `closed_tabs_is_served` | `{machines}` | `{served}` |
//! | `closed_tabs_newest` | `{machines, installs, registry, window?}` | `{machine, item}` or null |
//! | `closed_tabs_newest_once` | `{closed: [{item, machine}]}` | `[index]` |
//! | `closed_tabs_closes` | `{target: {item, machine}, closed}` | `[index or null]` |
//! | `closed_tabs_reading` | `{item}` | `{kind, agentSession, worthReopening, shownTab}` |
//! | `closed_tabs_text` | `{item, words?}` | `{title, detail}` |
//! | `closed_tabs_history_rows` | `{machines, limit?, words?}` | [`Row`](crate::history::Row)s |
//! | `closed_tabs_history_id` | `{id}` | `{historyID}` |
//! | `closed_tabs_daemon_id` | `{historyID}` | `{id}` (null for the app's trackers) |
//! | `closed_tabs_new_tab_items` | `{sources, home}` | [`PageItem`](crate::new_tab::PageItem)s |
//! | `closed_tabs_record_id` | `{install?, window}` | `{record}` |
//! | `closed_tabs_window_id` | `{recorded, installs}` | `{window}` |
//! | `closed_tabs_reopened_window_id` | `{record}` | `{window}` |
//! | `closed_tabs_reopen_start` | `{item, local}` | `{pane, expectPageHistory}` |
//! | `closed_tabs_reopen_after_reply` | `{item, reopened, paneShown}` | an [`AfterReply`] |
//! | `closed_tabs_reopen_show` | `{kind, reopened}` | a [`ShowSelect`](crate::reopen::ShowSelect) or null |
//! | `closed_tabs_reopen_failure` | `{item, code?}` | a [`ReopenFailure`](crate::reopen::ReopenFailure) |
//! | `closed_tabs_tabs_arrived` | `{tabs, storeTabs}` | `{arrived}` |
//! | `closed_tabs_delete` | `{item, local, installs}` | `{releaseWindow, emptyTrash}` |
//! | `closed_tabs_delete_failure` | `{code?}` | `{done}` |
//! | `closed_tabs_clear` | `{machines, since?, installs}` | a [`Clear`](crate::reopen::Clear) |
//! | `closed_tabs_feed_signature` | `{machines: [FeedMachine]}` | `[part]` |
//! | `closed_tabs_undo_added` | `{seen, ids}` | `{added, seen}` |
//! | `closed_tabs_undo_recorded_items` | `{machines, ids}` | `[{id, kind, pane, tabs}]` |
//! | `closed_tabs_undo_recent` | `{recent, items, matched}` | `{recent}` |
//! | `closed_tabs_undo_toast` | `{limit, tabs, shown?, window, now}` | `{show, limit}` |
//! | `closed_tabs_undo_message` | `{tabs, title}` | a [`Message`](crate::undo::Message) |
//! | `closed_tabs_undo_reopen_order` | `{closes: [[id]]}` | `[id]` |
//! | `closed_tabs_undo_announce` | `{parts}` | `{tabs, panes, titled}` |
//! | `closed_tabs_undo_waiting` | `{state}` | `[{pane, tabs, daemonTabs}]` |

use crate::feed::{self, FeedMachine};
use crate::history::{self, Words};
use crate::item::{ClosedItem, Kind};
use crate::listing::{self, Entry, Machine, Registry};
use crate::new_tab::{self, Source};
use crate::reading;
use crate::records;
use crate::reopen::{self, AfterReply, Reopened};
use crate::undo::{self, ClosingPart, RateLimit, RecentItem, ShownToast};
use cmux_window_rules::closed::{ItemKind, UndoState};
use serde::Deserialize;
use serde::de::DeserializeOwned;
use serde_json::{Value, json};
use std::collections::BTreeSet;

/// Why an op failed.
#[derive(Debug, PartialEq, Eq)]
pub enum OpError {
    /// The op is not one of the table's.
    UnknownOp(String),
    /// The request is not the JSON the op takes.
    Invalid(String),
}

#[derive(Deserialize)]
struct Machines {
    #[serde(default)]
    machines: Vec<Machine>,
}

#[derive(Deserialize)]
struct EntriesRequest {
    #[serde(default)]
    machines: Vec<Machine>,
    #[serde(default)]
    kinds: Option<Vec<Kind>>,
}

#[derive(Deserialize)]
struct LookupRequest {
    #[serde(default)]
    machines: Vec<Machine>,
    id: String,
}

#[derive(Deserialize)]
struct NewestRequest {
    #[serde(default)]
    machines: Vec<Machine>,
    #[serde(default)]
    installs: Vec<String>,
    #[serde(default)]
    registry: Registry,
    #[serde(default)]
    window: Option<String>,
}

#[derive(Deserialize)]
struct Placed {
    item: ClosedItem,
    machine: String,
}

#[derive(Deserialize)]
struct NewestOnceRequest {
    #[serde(default)]
    closed: Vec<Placed>,
}

#[derive(Deserialize)]
struct ClosesRequest {
    target: Placed,
    #[serde(default)]
    closed: Vec<Placed>,
}

#[derive(Deserialize)]
struct ItemRequest {
    item: ClosedItem,
    #[serde(default)]
    words: Words,
}

#[derive(Deserialize)]
struct RowsRequest {
    #[serde(default)]
    machines: Vec<Machine>,
    #[serde(default)]
    limit: Option<usize>,
    #[serde(default)]
    words: Words,
}

#[derive(Deserialize)]
struct IdRequest {
    id: String,
}

#[derive(Deserialize)]
struct HistoryIdRequest {
    #[serde(rename = "historyID", alias = "historyId")]
    history_id: String,
}

#[derive(Deserialize)]
struct NewTabRequest {
    #[serde(default)]
    sources: Vec<Source>,
    #[serde(default)]
    home: String,
}

#[derive(Deserialize)]
struct RecordIdRequest {
    #[serde(default)]
    install: Option<String>,
    window: String,
}

#[derive(Deserialize)]
struct WindowIdRequest {
    recorded: String,
    #[serde(default)]
    installs: Vec<String>,
}

#[derive(Deserialize)]
struct RecordRequest {
    record: String,
}

#[derive(Deserialize)]
struct StartRequest {
    item: ClosedItem,
    #[serde(default)]
    local: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct AfterReplyRequest {
    item: ClosedItem,
    #[serde(default)]
    reopened: Reopened,
    #[serde(default)]
    pane_shown: bool,
}

#[derive(Deserialize)]
struct ShowRequest {
    kind: Kind,
    #[serde(default)]
    reopened: Reopened,
}

#[derive(Deserialize)]
struct FailureRequest {
    item: ClosedItem,
    #[serde(default)]
    code: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ArrivedRequest {
    #[serde(default)]
    tabs: Vec<String>,
    #[serde(default)]
    store_tabs: Vec<String>,
}

#[derive(Deserialize)]
struct DeleteRequest {
    item: ClosedItem,
    #[serde(default)]
    local: bool,
    #[serde(default)]
    installs: Vec<String>,
}

#[derive(Deserialize)]
struct CodeRequest {
    #[serde(default)]
    code: Option<String>,
}

#[derive(Deserialize)]
struct ClearRequest {
    #[serde(default)]
    machines: Vec<Machine>,
    #[serde(default)]
    since: Option<f64>,
    #[serde(default)]
    installs: Vec<String>,
}

#[derive(Deserialize)]
struct FeedRequest {
    #[serde(default)]
    machines: Vec<FeedMachine>,
}

#[derive(Deserialize)]
struct AddedRequest {
    #[serde(default)]
    seen: BTreeSet<String>,
    #[serde(default)]
    ids: Vec<String>,
}

#[derive(Deserialize)]
struct RecordedItemsRequest {
    #[serde(default)]
    machines: Vec<Machine>,
    #[serde(default)]
    ids: Vec<String>,
}

#[derive(Deserialize, Default)]
#[serde(default)]
struct RecentItemIn {
    id: String,
    pane: Option<String>,
    tabs: usize,
}

#[derive(Deserialize)]
struct RecentRequest {
    #[serde(default)]
    recent: Vec<RecentItem>,
    #[serde(default)]
    items: Vec<RecentItemIn>,
    #[serde(default)]
    matched: Vec<bool>,
}

#[derive(Deserialize)]
struct ToastRequest {
    #[serde(default)]
    limit: RateLimit,
    tabs: usize,
    #[serde(default)]
    shown: Option<ShownToast>,
    #[serde(default)]
    window: String,
    now: i64,
}

#[derive(Deserialize)]
struct MessageRequest {
    tabs: usize,
    #[serde(default)]
    title: String,
}

#[derive(Deserialize)]
struct ReopenOrderRequest {
    #[serde(default)]
    closes: Vec<Vec<String>>,
}

#[derive(Deserialize)]
struct AnnounceRequest {
    #[serde(default)]
    parts: Vec<ClosingPart>,
}

#[derive(Deserialize)]
struct WaitingRequest {
    #[serde(default)]
    state: UndoState,
}

fn parse<T: DeserializeOwned>(request: Value) -> Result<T, OpError> {
    serde_json::from_value(request).map_err(|error| OpError::Invalid(error.to_string()))
}

fn encode<T: serde::Serialize>(value: &T) -> Value {
    serde_json::to_value(value).unwrap_or(Value::Null)
}

fn at(entry: Option<Entry<'_>>) -> Value {
    entry.map_or(Value::Null, |entry| encode(&entry.at))
}

fn kind_name(kind: ItemKind) -> &'static str {
    match kind {
        ItemKind::Tab => "tab",
        ItemKind::Screen => "screen",
        ItemKind::Workspace => "workspace",
        ItemKind::Window => "window",
        ItemKind::Other => "other",
    }
}

/// True for the ops [`call`] answers.
pub fn serves(op: &str) -> bool {
    op.starts_with("closed_tabs_")
}

/// Runs `op` on `request` (a JSON object; null means `{}`).
pub fn call(op: &str, request: Value) -> Result<Value, OpError> {
    let request = if request.is_null() { json!({}) } else { request };
    match op {
        "closed_tabs_entries" => {
            let EntriesRequest { machines, kinds } = parse(request)?;
            let kinds = kinds.unwrap_or_else(|| Kind::ALL.to_vec());
            let entries: Vec<_> =
                listing::entries(&machines, &kinds).into_iter().map(|entry| entry.at).collect();
            Ok(encode(&entries))
        }
        "closed_tabs_entry" => {
            let LookupRequest { machines, id } = parse(request)?;
            Ok(at(listing::entry(&machines, &id)))
        }
        "closed_tabs_group_entry" => {
            let LookupRequest { machines, id } = parse(request)?;
            Ok(at(listing::group_entry(&machines, &id)))
        }
        "closed_tabs_is_served" => {
            let Machines { machines } = parse(request)?;
            Ok(json!({"served": listing::is_served(&machines)}))
        }
        "closed_tabs_newest" => {
            let NewestRequest { machines, installs, registry, window } = parse(request)?;
            Ok(at(listing::newest(&machines, &installs, &registry, window.as_deref())))
        }
        "closed_tabs_newest_once" => {
            let NewestOnceRequest { closed } = parse(request)?;
            let pairs: Vec<_> =
                closed.iter().map(|placed| (&placed.item, placed.machine.as_str())).collect();
            Ok(encode(&listing::newest_once(&pairs)))
        }
        "closed_tabs_closes" => {
            let ClosesRequest { target, closed } = parse(request)?;
            let pairs: Vec<_> =
                closed.iter().map(|placed| (&placed.item, placed.machine.as_str())).collect();
            Ok(encode(&listing::closes((&target.item, target.machine.as_str()), &pairs)))
        }
        "closed_tabs_reading" => {
            let ItemRequest { item, .. } = parse(request)?;
            Ok(json!({
                "kind": reading::closed_kind(&item),
                "agentSession": reading::closed_agent_session(&item),
                "worthReopening": reading::is_worth_reopening(&item),
                "shownTab": reading::shown_tab(&item),
            }))
        }
        "closed_tabs_text" => {
            let ItemRequest { item, words } = parse(request)?;
            let (title, detail) = history::text(&item, &words);
            Ok(json!({"title": title, "detail": detail}))
        }
        "closed_tabs_history_rows" => {
            let RowsRequest { machines, limit, words } = parse(request)?;
            Ok(encode(&history::closed_rows(&machines, limit, &words)))
        }
        "closed_tabs_history_id" => {
            let IdRequest { id } = parse(request)?;
            Ok(json!({"historyID": history::history_id(&id)}))
        }
        "closed_tabs_daemon_id" => {
            let HistoryIdRequest { history_id } = parse(request)?;
            Ok(json!({"id": history::daemon_id(&history_id)}))
        }
        "closed_tabs_new_tab_items" => {
            let NewTabRequest { sources, home } = parse(request)?;
            Ok(encode(&new_tab::items(&sources, &home)))
        }
        "closed_tabs_record_id" => {
            let RecordIdRequest { install, window } = parse(request)?;
            Ok(json!({"record": records::record_id(install.as_deref(), &window)}))
        }
        "closed_tabs_window_id" => {
            let WindowIdRequest { recorded, installs } = parse(request)?;
            Ok(json!({"window": records::window_id(&recorded, &installs)}))
        }
        "closed_tabs_reopened_window_id" => {
            let RecordRequest { record } = parse(request)?;
            Ok(json!({"window": records::reopened_window_id(&record)}))
        }
        "closed_tabs_reopen_start" => {
            let StartRequest { item, local } = parse(request)?;
            Ok(encode(&reopen::start(&item, local)))
        }
        "closed_tabs_reopen_after_reply" => {
            let AfterReplyRequest { item, reopened, pane_shown } = parse(request)?;
            let step: AfterReply = reopen::after_reply(&item, &reopened, pane_shown);
            Ok(encode(&step))
        }
        "closed_tabs_reopen_show" => {
            let ShowRequest { kind, reopened } = parse(request)?;
            Ok(encode(&reopen::show(kind, &reopened)))
        }
        "closed_tabs_reopen_failure" => {
            let FailureRequest { item, code } = parse(request)?;
            Ok(encode(&reopen::reopen_failure(&item, code.as_deref())))
        }
        "closed_tabs_tabs_arrived" => {
            let ArrivedRequest { tabs, store_tabs } = parse(request)?;
            Ok(json!({"arrived": reopen::tabs_arrived(&tabs, &store_tabs)}))
        }
        "closed_tabs_delete" => {
            let DeleteRequest { item, local, installs } = parse(request)?;
            Ok(encode(&reopen::delete(&item, local, &installs)))
        }
        "closed_tabs_delete_failure" => {
            let CodeRequest { code } = parse(request)?;
            Ok(json!({"done": reopen::delete_failure_is_done(code.as_deref())}))
        }
        "closed_tabs_clear" => {
            let ClearRequest { machines, since, installs } = parse(request)?;
            Ok(encode(&reopen::clear(&machines, since, &installs)))
        }
        "closed_tabs_feed_signature" => {
            let FeedRequest { machines } = parse(request)?;
            Ok(encode(&feed::signature(&machines)))
        }
        "closed_tabs_undo_added" => {
            let AddedRequest { mut seen, ids } = parse(request)?;
            let added = undo::added(&mut seen, &ids);
            Ok(json!({"added": added, "seen": seen}))
        }
        "closed_tabs_undo_recorded_items" => {
            let RecordedItemsRequest { machines, ids } = parse(request)?;
            let items: Vec<Value> = undo::recorded_items(&machines, &ids)
                .into_iter()
                .map(|item| {
                    json!({"id": item.id, "kind": kind_name(item.kind), "pane": item.pane,
                           "tabs": item.tabs})
                })
                .collect();
            Ok(Value::Array(items))
        }
        "closed_tabs_undo_recent" => {
            let RecentRequest { mut recent, items, matched } = parse(request)?;
            let items: Vec<_> = items
                .into_iter()
                .map(|item| cmux_window_rules::closed::RecordedItem {
                    id: item.id,
                    pane: item.pane,
                    tabs: item.tabs,
                    ..Default::default()
                })
                .collect();
            undo::push_recent(&mut recent, &items, &matched);
            Ok(json!({"recent": recent}))
        }
        "closed_tabs_undo_toast" => {
            let ToastRequest { mut limit, tabs, shown, window, now } = parse(request)?;
            let show = undo::toast(&mut limit, tabs, shown.as_ref(), &window, now);
            let mut reply = encode(&show);
            if let Some(fields) = reply.as_object_mut() {
                fields.insert("limit".to_owned(), encode(&limit));
            }
            Ok(reply)
        }
        "closed_tabs_undo_message" => {
            let MessageRequest { tabs, title } = parse(request)?;
            Ok(encode(&undo::message(tabs, &title)))
        }
        "closed_tabs_undo_reopen_order" => {
            let ReopenOrderRequest { closes } = parse(request)?;
            Ok(encode(&undo::joined_reopen_order(&closes)))
        }
        "closed_tabs_undo_announce" => {
            let AnnounceRequest { parts } = parse(request)?;
            Ok(encode(&undo::announce(&parts)))
        }
        "closed_tabs_undo_waiting" => {
            let WaitingRequest { state } = parse(request)?;
            Ok(encode(&undo::waiting(&state)))
        }
        other => Err(OpError::UnknownOp(other.to_owned())),
    }
}
