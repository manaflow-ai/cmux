//! The chats `chat.list` answers and `chat.changed` follows
//! (plans/cmux-next/extensibility-DESIGN.md, step 3): every ACP chat acpmux on
//! this machine knows, its peers' included, as one row each, for App Store
//! apps (Priority View), the CLI and the SDKs.
//!
//! The daemon already follows acpmux's chats for their notifications
//! (`agent_chat_notices.rs`: `_acpmux/watch`, its pages and its
//! `_acpmux/session_changed` pushes). That watch feeds this index too, so a
//! `chat.list` read costs no acpmux call and the index changes only when acpmux
//! says a chat changed: nothing polls.
//!
//! A row changes when a listed field other than `updated_ms` changes; each such
//! change raises the index's revision once and emits one
//! [`MuxEvent::ChatsChanged`] (an app's `chat.changed`). A page of rows raises it
//! once for the whole page. `updated_ms` moves with every output a working chat
//! writes, so it is kept fresh but is no change signal of its own.
//!
//! A chat that is closed, archived (acpmux's `archived` tag) or has no lane
//! leaves the list. A connection's list that comes whole drops the rows it did
//! not name (purged while the watch was away); a chat a push reached during that
//! list stays, and a page older than that push does not undo it. A follow
//! (acpmux answers only what changed since the watch's cursor) applies its rows
//! and drops the ones it says are `gone`, but drops nothing it did not name.

use std::collections::{BTreeMap, HashMap, HashSet};
use std::sync::{Mutex, MutexGuard, PoisonError};

use serde_json::{Map, Value, json};

use super::Mux;
use crate::MuxEvent;
use crate::resource::ContentPublicId;
use crate::state::conversation_tabs_store::ConversationTabRecord;

/// The acpmux session tag that pins a chat (`chat.pin`). acpmux keeps tags, so a
/// pin reaches every window and device, as the notifications mute does.
pub(crate) const PIN_TAG: &str = "pinned";
/// The value `chat.pin` sets; any non-empty value reads as pinned.
pub(crate) const PINNED: &str = "true";
/// acpmux's archive tag (`_acpmux/archive`): an archived chat is off the list.
const ARCHIVED_TAG: &str = "archived";

/// The index, behind one lock; see the module docs.
#[derive(Default)]
pub(crate) struct ChatIndex(Mutex<Chats>);

impl ChatIndex {
    fn lock(&self) -> MutexGuard<'_, Chats> {
        self.0.lock().unwrap_or_else(PoisonError::into_inner)
    }
}

#[derive(Default)]
pub(crate) struct Chats {
    /// Rows by key ([`key`]): the peer and the chat's id.
    rows: BTreeMap<String, Value>,
    revision: u64,
    /// The whole list a connection is reading now, if any.
    listing: Option<Listing>,
    /// The keys a push on this connection reached: an older page or follow does not undo them.
    pushed: HashSet<String>,
}

#[derive(Default)]
struct Listing {
    /// Every key the list or a push named.
    named: HashSet<String>,
}

/// A row's key: `peer\0id`, empty peer for this machine's chats (a peer's chat may
/// share an id with one here).
fn key(peer: Option<&str>, id: &str) -> String {
    format!("{}\0{id}", peer.unwrap_or_default())
}

fn summary_key(summary: &Value, peer: &Value) -> Option<String> {
    let id = summary.get("sessionId").and_then(Value::as_str).filter(|id| !id.is_empty())?;
    Some(key(peer.as_str(), id))
}

/// One acpmux session summary as a `ChatSummary` row (spec/resource-operations-v2.json),
/// without `workspace` (added at read time); `None` for a chat off the list.
pub(crate) fn row(summary: &Value) -> Option<Value> {
    let id = summary.get("sessionId").and_then(Value::as_str).filter(|id| !id.is_empty())?;
    let lane = summary.get("lane").and_then(Value::as_object)?;
    let status = summary.get("status").and_then(Value::as_str).unwrap_or_default();
    let tags = summary.get("tags").and_then(Value::as_object);
    let tag = |name: &str| {
        tags.and_then(|tags| tags.get(name))
            .and_then(Value::as_str)
            .filter(|value| !value.is_empty())
    };
    if status == "closed" || tag(ARCHIVED_TAG).is_some() {
        return None;
    }
    let state = match lane.get("state").and_then(Value::as_str)? {
        state @ ("working" | "input" | "idle" | "failed" | "lost") => state,
        _ => return None,
    };
    let text = |value: Option<&Value>| {
        value.and_then(Value::as_str).filter(|text| !text.trim().is_empty()).map(str::to_owned)
    };
    let title = text(lane.get("title"))
        .or_else(|| text(summary.get("title")))
        .or_else(|| text(summary.get("name")))
        .unwrap_or_else(|| id.to_owned());
    let cwd = text(summary.get("cwd"));
    let project = cwd.as_deref().and_then(|cwd| {
        std::path::Path::new(cwd).file_name().map(|name| name.to_string_lossy().into_owned())
    });
    let ms = |value: Option<&Value>| value.and_then(Value::as_u64).map(|ms| ms.to_string());
    let pull_requests = summary
        .get("pullRequests")
        .and_then(Value::as_array)
        .map(|urls| urls.iter().filter_map(Value::as_str).map(str::to_owned).collect::<Vec<_>>())
        .unwrap_or_default();
    let unread_turns = summary
        .get("unreadTurns")
        .and_then(Value::as_u64)
        .map_or(0, |turns| u32::try_from(turns).unwrap_or(u32::MAX));
    Some(json!({
        "id": id,
        "title": title,
        "harness": text(summary.get("harness")),
        "state": state,
        "unread": summary.get("unread").and_then(Value::as_bool) == Some(true),
        "unread_turns": unread_turns,
        "pinned": tag(PIN_TAG).is_some(),
        // No owner tells cmux a chat's checks yet; the field is in the shape so an app
        // ranks a red chat the day one does (the native view reads the session tree's badge).
        "ci_failing": Value::Null,
        "machine": text(summary.get("peer")),
        "cwd": cwd,
        "project": project,
        "parent": text(summary.get("parent")),
        "step": text(lane.get("step")),
        "error": text(lane.get("error")),
        "since_ms": ms(lane.get("since")),
        "updated_ms": ms(summary.get("updatedAt")),
        "created_ms": ms(summary.get("createdAt")),
        "pull_requests": pull_requests,
    }))
}

/// Whether two rows differ in anything but `updated_ms`.
fn differs(before: &Value, after: &Value) -> bool {
    let (Some(before), Some(after)) = (before.as_object(), after.as_object()) else {
        return before != after;
    };
    before.len() != after.len()
        || before.iter().any(|(name, value)| name != "updated_ms" && after.get(name) != Some(value))
}

impl Chats {
    /// Puts or removes `key`'s row; whether that is a change.
    fn put(&mut self, key: String, row: Option<Value>) -> bool {
        match row {
            Some(row) => {
                let changed = self.rows.get(&key).is_none_or(|before| differs(before, &row));
                // A row the same but for `updated_ms` is still stored, so reads see it fresh.
                self.rows.insert(key, row);
                changed
            }
            None => self.rows.remove(&key).is_some(),
        }
    }

    /// A page of the watch's list (`sessions`, each with its `peer`).
    pub(crate) fn page(&mut self, sessions: &[Value]) -> bool {
        let mut changed = false;
        for summary in sessions {
            let Some(key) = summary_key(summary, summary.get("peer").unwrap_or(&Value::Null))
            else {
                continue;
            };
            if let Some(listing) = &mut self.listing {
                listing.named.insert(key.clone());
            }
            if self.pushed.contains(&key) {
                continue;
            }
            changed |= self.put(key, row(summary));
        }
        changed
    }

    /// One `_acpmux/session_changed` push: `{sessionId, peer, kind, session}`.
    pub(crate) fn push(&mut self, params: &Value) -> bool {
        let peer = params.get("peer").unwrap_or(&Value::Null);
        let Some(key) = summary_key(params, peer) else { return false };
        if let Some(listing) = &mut self.listing {
            listing.named.insert(key.clone());
        }
        self.pushed.insert(key.clone());
        let row = if params.get("kind").and_then(Value::as_str) == Some("purged") {
            None
        } else {
            params.get("session").and_then(row)
        };
        self.put(key, row)
    }

    /// A new connection to acpmux: no push reached a row on it yet, and no list is out.
    pub(crate) fn connect(&mut self) {
        self.listing = None;
        self.pushed.clear();
    }

    /// The connection starts a whole list (a first list, or a follow acpmux reset).
    pub(crate) fn begin(&mut self) {
        self.listing = Some(Listing::default());
    }

    /// The connection's list came whole: a row it did not name, and no push reached, is gone.
    pub(crate) fn end(&mut self) -> bool {
        let Some(listing) = self.listing.take() else { return false };
        let before = self.rows.len();
        let pushed = &self.pushed;
        self.rows.retain(|key, _| listing.named.contains(key) || pushed.contains(key));
        self.rows.len() != before
    }

    /// A follow's `gone` entries (`{sessionId, peer}`): those chats left acpmux, unless a push
    /// on this connection reached them since.
    pub(crate) fn gone(&mut self, gone: &[Value]) -> bool {
        let mut changed = false;
        for entry in gone {
            let Some(key) = summary_key(entry, entry.get("peer").unwrap_or(&Value::Null)) else {
                continue;
            };
            if !self.pushed.contains(&key) {
                changed |= self.put(key, None);
            }
        }
        changed
    }

    /// Raises the revision after a change; the new revision.
    fn bump(&mut self) -> u64 {
        self.revision = self.revision.saturating_add(1);
        self.revision
    }

    /// The key of the row `chat` names: an exact id, this machine's first.
    fn find(&self, chat: &str) -> Option<String> {
        let local = key(None, chat);
        if self.rows.contains_key(&local) {
            return Some(local);
        }
        let suffix = format!("\0{chat}");
        self.rows.keys().find(|key| key.ends_with(&suffix)).cloned()
    }
}

impl Mux {
    fn chats(&self) -> MutexGuard<'_, Chats> {
        self.chat_index.lock()
    }

    /// Runs `change` on the index and emits one `ChatsChanged` when it changed something.
    pub(crate) fn change_chats(&self, change: impl FnOnce(&mut Chats) -> bool) {
        let revision = {
            let mut chats = self.chats();
            if !change(&mut chats) {
                return;
            }
            chats.bump()
        };
        self.emit(MuxEvent::ChatsChanged { revision });
    }

    /// `chat.list`: every row, with the workspace of a tab that shows the chat.
    pub(crate) fn chat_rows(&self) -> Vec<Value> {
        let mut rows = self.chats().rows.values().cloned().collect::<Vec<_>>();
        if rows.is_empty() {
            return rows;
        }
        let workspaces = self.chat_workspaces();
        for row in &mut rows {
            let workspace = row
                .get("id")
                .and_then(Value::as_str)
                .and_then(|id| workspaces.get(id))
                .map_or(Value::Null, |id| Value::String(id.clone()));
            if let Some(fields) = row.as_object_mut() {
                fields.insert("workspace".into(), workspace);
            }
        }
        rows
    }

    /// Whether `chat.list` lists `chat`.
    pub(crate) fn chat_listed(&self, chat: &str) -> bool {
        self.chats().find(chat).is_some()
    }

    /// Applies a change acpmux accepted (`chat.mark_read`, `chat.pin`) to `chat`'s row
    /// before acpmux's push confirms it, so the answer and an app's next read agree; the
    /// row after it, with its workspace, or `None` when the list no longer has it.
    pub(crate) fn update_chat(
        &self,
        chat: &str,
        change: impl FnOnce(&mut Map<String, Value>),
    ) -> Option<(Value, u64)> {
        let mut found = None;
        self.change_chats(|chats| {
            let Some(key) = chats.find(chat) else { return false };
            let Some(row) = chats.rows.get_mut(&key) else { return false };
            let before = row.clone();
            if let Some(fields) = row.as_object_mut() {
                change(fields);
            }
            let changed = differs(&before, row);
            found = Some(row.clone());
            changed
        });
        let mut row = found?;
        let revision = self.chats().revision;
        let workspace = row
            .get("id")
            .and_then(Value::as_str)
            .and_then(|id| self.chat_workspaces().remove(id))
            .map_or(Value::Null, Value::String);
        if let Some(fields) = row.as_object_mut() {
            fields.insert("workspace".into(), workspace);
        }
        Some((row, revision))
    }

    /// The public workspace id of a tab bound to each chat (the first one found).
    fn chat_workspaces(&self) -> HashMap<String, String> {
        let presentation = self.presentation_snapshot();
        let mut out = HashMap::new();
        if presentation.conversation_tabs.is_empty() {
            return out;
        }
        let state = self.state.lock().unwrap_or_else(PoisonError::into_inner);
        for (id, surface) in state.surfaces.iter() {
            let Some(identity) = surface.resource_identity() else { continue };
            let ContentPublicId::Browser(content) = &identity.content_id else { continue };
            let Some(ConversationTabRecord::AgentSession { session: Some(bound), .. }) =
                presentation.conversation_tabs.get(content.as_str())
            else {
                continue;
            };
            if out.contains_key(bound) {
                continue;
            }
            let Some(workspace) = Self::workspace_for_surface_in_state(&state, *id) else {
                continue;
            };
            let Some(index) = state.workspace_index(workspace) else { continue };
            if let Some(found) = state.workspaces.get(index) {
                out.insert(bound.clone(), found.public_id.to_string());
            }
        }
        out
    }
}

#[cfg(test)]
#[path = "chat_index_tests.rs"]
mod tests;
