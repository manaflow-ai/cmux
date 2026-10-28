//! The merged read model and the mutations of the history module.
//!
//! Per session: the agent fold over the session journal and
//! the history revision ([`HistoryHost`], one mutex). Per machine: the page
//! visit stores (pages.rs) and the location trail (trail.rs). Read from
//! other owners: closed items from the closed-history store (sources.rs)
//! and finished commands from the terminal command rows
//! (`terminal-command-history-v1`, the rows the Swift History page lists).
//!
//! What each kind allows (history.md section 3): page visits are deleted
//! into a backup (restore id); agent entries live in the append-only
//! journal and are hidden (`history.hidden`); command rows and closed items
//! are deleted for good (the command store; closed.rs, as `closed.delete`);
//! a location removes every trail entry of its place (cx-hnmbt.12).

use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, PoisonError};

use cmux_history::{
    AgentSessionFold, EntryContext, HiddenHistory, HistoryEntry, HistoryKind, hidden_id,
};
use serde_json::{Map, Value, json};

use super::pages::{self, run, wire};
use super::{closed, commands, hidden_doc, journal_feed, sources, store_failed, trail};
use crate::Mux;
use crate::resource::ResourceError;
use crate::workspace_registry::Actor;

/// The machine name the folds qualify ids with. It matches the Swift app's
/// `MachineRegistry.localID`, so hides it stored (`local/<provider>/<id>`)
/// keep applying.
pub(super) const LOCAL_MACHINE: &str = "local";

/// How long `history.entries.list` folds new journal records before it
/// answers (see `pending_kinds`). Well under the CLI's 10 s request timeout.
const LIST_FOLD_BUDGET: std::time::Duration = std::time::Duration::from_secs(2);

/// The registry key (`journal_reducer.<id>` in `meta`) of the saved agent
/// fold: its sessions and the journal cursor they reached. A restart folds
/// only the records after that cursor, never the whole journal again.
const AGENT_FOLD_STATE_ID: &str = "history.agent_sessions";
/// Bump when the saved fold's shape or meaning changes: a saved fold of
/// another version is dropped and the journal folded again.
const AGENT_FOLD_STATE_VERSION: u32 = 1;
/// A long fold (the first one over a large journal) saves its progress at
/// least every this many journal sequences, so a restart midway keeps it.
const SAVE_STRIDE: u64 = 50_000;

/// The session's history state: the journal folds, the journal cursor they
/// reached and the history revision.
pub(crate) struct HistoryHost {
    state: Mutex<HostState>,
    /// One journal page read and fold at a time: the feed thread and a list
    /// take turns page by page, so neither reads a page the other folds.
    turn: Mutex<()>,
    feed_claimed: AtomicBool,
}

struct HostState {
    agents: AgentSessionFold,
    cursor: u64,
    revision: u64,
    /// The saved fold has been loaded (or found missing) once.
    restored: bool,
    /// The cursor of the last saved fold.
    saved_cursor: u64,
    /// Agent records folded since the last save.
    unsaved_agents: bool,
}

impl Default for HistoryHost {
    fn default() -> Self {
        Self {
            state: Mutex::new(HostState {
                agents: AgentSessionFold::new(LOCAL_MACHINE),
                cursor: 0,
                revision: 1,
                restored: false,
                saved_cursor: 0,
                unsaved_agents: false,
            }),
            turn: Mutex::new(()),
            feed_claimed: AtomicBool::new(false),
        }
    }
}

impl HistoryHost {
    fn lock(&self) -> std::sync::MutexGuard<'_, HostState> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }

    pub(super) fn cursor(&self) -> u64 {
        self.lock().cursor
    }

    /// The turn of one page read and fold (see `turn`).
    pub(super) fn turn(&self) -> std::sync::MutexGuard<'_, ()> {
        self.turn.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Loads the saved agent fold once, before the first fold: its sessions
    /// and cursor, when the version matches and the cursor is not past the
    /// journal head (a newer journal than the one it folded). Call with the
    /// turn held.
    pub(super) fn restore(&self, mux: &Mux) {
        if self.lock().restored {
            return;
        }
        let saved = {
            let registry = mux.workspace_registry.lock().unwrap_or_else(PoisonError::into_inner);
            registry
                .journal_reducer_state(AGENT_FOLD_STATE_ID)
                .and_then(|state| Ok((state, registry.session_journal_head()?)))
        };
        let restored = match saved {
            Ok((Some((AGENT_FOLD_STATE_VERSION, cursor, snapshot)), head)) if cursor <= head => {
                serde_json::from_str::<AgentSessionFold>(&snapshot)
                    .ok()
                    .filter(|fold| fold.machine() == LOCAL_MACHINE && fold.cursor() <= cursor)
                    .map(|fold| (fold, cursor))
            }
            Ok(_) => None,
            Err(error) => {
                eprintln!("cmux-tui: reading the saved agent history failed: {error:#}");
                None
            }
        };
        let mut state = self.lock();
        state.restored = true;
        if let Some((agents, cursor)) = restored
            && state.cursor == 0
        {
            state.agents = agents;
            state.cursor = cursor;
            state.saved_cursor = cursor;
        }
    }

    /// Saves the agent fold and its cursor when agent records were folded
    /// since the last save, or the cursor moved `SAVE_STRIDE` past it (a
    /// cursor moved only by terminal output is not worth a write each
    /// commit). Call with the turn held.
    pub(super) fn save(&self, mux: &Mux) {
        let (cursor, snapshot) = {
            let state = self.lock();
            let due = state.unsaved_agents
                || state.cursor.saturating_sub(state.saved_cursor) >= SAVE_STRIDE;
            if state.cursor <= state.saved_cursor || !due {
                return;
            }
            match serde_json::to_string(&state.agents) {
                Ok(snapshot) => (state.cursor, snapshot),
                Err(error) => {
                    eprintln!("cmux-tui: encoding the agent history failed: {error}");
                    return;
                }
            }
        };
        // The connection alone, never the workspace registry lock: the
        // snapshot is the whole agent history, and every state commit
        // (Cmd-N's pin, create and first tab) waited behind it (issue 23038).
        let saved = mux.registry_connection.put_journal_reducer_state(
            AGENT_FOLD_STATE_ID,
            AGENT_FOLD_STATE_VERSION,
            cursor,
            &snapshot,
        );
        match saved {
            Ok(()) => {
                let mut state = self.lock();
                state.saved_cursor = cursor;
                state.unsaved_agents = false;
            }
            Err(error) => eprintln!("cmux-tui: saving the agent history failed: {error:#}"),
        }
    }

    /// Marks the agent fold unsaved; returns its cursor.
    #[cfg(test)]
    pub(super) fn mark_unsaved_for_test(&self) -> u64 {
        let mut state = self.lock();
        state.saved_cursor = 0;
        state.unsaved_agents = true;
        state.cursor
    }

    /// Folds the journal records scanned after `from` through `scanned`. A
    /// concurrent fold that already moved the cursor wins. Returns the kinds
    /// that changed.
    pub(super) fn fold(
        &self,
        from: u64,
        scanned: u64,
        records: &[(HistoryKind, Value)],
    ) -> Vec<HistoryKind> {
        let mut state = self.lock();
        if state.cursor != from {
            return Vec::new();
        }
        let pick = |kind| -> Vec<Value> {
            records.iter().filter(|(of, _)| *of == kind).map(|(_, value)| value.clone()).collect()
        };
        let agents = pick(HistoryKind::Agent);
        let mut changed = Vec::new();
        if !agents.is_empty() {
            state.agents.apply(&agents);
            state.unsaved_agents = true;
            changed.push(HistoryKind::Agent);
        }
        // Closed items live in the closed-history store; a record that
        // changed one only marks the kind (an open History page re-reads).
        if records.iter().any(|(kind, _)| *kind == HistoryKind::Closed) {
            changed.push(HistoryKind::Closed);
        }
        state.cursor = scanned;
        changed
    }

    /// Agent entries the hides leave visible.
    fn agent_entries(&self, hidden: &HiddenHistory) -> Vec<HistoryEntry> {
        let context = EntryContext { local_machine: LOCAL_MACHINE, available: true };
        self.lock().agents.entries(&context, hidden)
    }

    fn revision(&self) -> u64 {
        self.lock().revision
    }

    /// Bumps the history revision and emits `history-changed`.
    pub(crate) fn changed(&self, mux: &Mux, kinds: &[HistoryKind]) {
        let revision = {
            let mut state = self.lock();
            state.revision += 1;
            state.revision
        };
        mux.emit(crate::MuxEvent::HistoryChanged {
            revision,
            kinds: kinds.iter().map(|kind| kind.as_str().to_owned()).collect(),
        });
    }

    pub(super) fn claim_feed(&self) -> bool {
        !self.feed_claimed.swap(true, Ordering::AcqRel)
    }

    pub(super) fn release_feed(&self) {
        self.feed_claimed.store(false, Ordering::Release);
    }
}

fn failed(operation: &str, error: &anyhow::Error) -> ResourceError {
    store_failed(operation, format!("{error:#}"))
}

/// `history.entries.list`: every selected kind, newest first.
pub(super) fn list(
    mux: &Arc<Mux>,
    fields: &Map<String, Value>,
    now_ms: i64,
    day_start_ms: i64,
) -> Result<Value, ResourceError> {
    const OPERATION: &str = "history.entries.list";
    let query = pages::query(fields)?;
    let profile = pages::text(fields, "profile")?;
    let wants = |kind| query.wants(kind) && (profile.is_none() || kind == HistoryKind::Page);
    let mut entries = Vec::new();
    if wants(HistoryKind::Page)
        && let Some(shared) = pages::shared(mux, OPERATION)?
    {
        let mut shared = shared.lock().unwrap_or_else(PoisonError::into_inner);
        entries.extend(
            pages::entries(&mut shared.stores, &query, profile, now_ms, day_start_ms)
                .map_err(|error| store_failed(OPERATION, error))?,
        );
    }
    let mut pending = Vec::new();
    if wants(HistoryKind::Agent) {
        journal_feed::start(mux);
        // A first fold over a large journal can take minutes: answer what is
        // folded by then and name the kind pending. The feed thread goes on
        // and emits `history-changed` (agent) when it has caught up.
        let deadline = std::time::Instant::now() + LIST_FOLD_BUDGET;
        let caught = journal_feed::catch_up(mux, Some(deadline))
            .map_err(|error| failed(OPERATION, &error))?;
        if !caught.changed.is_empty() {
            mux.history.changed(mux, &caught.changed);
        }
        if !caught.complete {
            pending.push(HistoryKind::Agent.as_str());
        }
        let (hidden, _) = hidden_doc::load(mux).map_err(|error| failed(OPERATION, &error))?;
        entries.extend(mux.history.agent_entries(&hidden));
    }
    if wants(HistoryKind::Command) {
        // Every unexpired row up to the store's page (1000): the search and
        // range filter below run over all of them, not the newest `limit`.
        entries.extend(commands::entries(mux).map_err(|error| failed(OPERATION, &error))?);
    }
    if wants(HistoryKind::Closed) {
        let items = mux
            .read_registry_state(crate::state::closed_history_query::closed_items)
            .map_err(|error| failed(OPERATION, &error))?;
        entries.extend(sources::closed_entries(&items));
    }
    // A location row also carries its window and stored location (an app
    // rebuilds its Back/Forward steps from them).
    let mut locations = Map::new();
    if wants(HistoryKind::Location) {
        let (document, _) = trail::load(mux).map_err(|error| failed(OPERATION, &error))?;
        let newest = document.entries.last().map(|entry| entry.id);
        for entry in &document.entries {
            let id = format!("location:{}", entry.id);
            locations
                .insert(id.clone(), json!({"window": entry.window, "location": entry.location}));
            entries.push(sources::location_entry(&id, entry, Some(entry.id) == newest));
        }
    }
    let matched = query.apply(&entries, now_ms, day_start_ms, |path| Path::new(path).is_dir());
    let rows = matched
        .iter()
        .map(|entry| {
            let mut row = wire(entry);
            if let (Some(object), Some(Value::Object(extra))) =
                (row.as_object_mut(), locations.get(&entry.id))
            {
                object.extend(extra.clone());
            }
            row
        })
        .collect::<Vec<_>>();
    let mut reply = json!({"entries": rows, "revision": mux.history.revision().to_string()});
    if !pending.is_empty() {
        reply["pending_kinds"] = json!(pending);
    }
    Ok(reply)
}

/// Runs one mutation once (the caller checked the key): its result value
/// and the kinds it changed.
pub(super) fn mutate(
    mux: &Arc<Mux>,
    key: &str,
    actor: &Actor,
    operation: &str,
    fields: &Map<String, Value>,
    now_ms: i64,
    day_start_ms: i64,
) -> Result<(Value, Vec<HistoryKind>), ResourceError> {
    let pages_only = |mux: &Arc<Mux>| -> Result<(Value, Vec<HistoryKind>), ResourceError> {
        let value = pages::with_stores(mux, operation, |stores| {
            run(stores, operation, fields, now_ms, day_start_ms)
        })?;
        let changed = changed_pages(&value);
        Ok((value, changed))
    };
    match operation {
        "history.entries.remove" => remove(mux, key, actor, fields, now_ms, day_start_ms),
        "history.clear" => clear(mux, key, actor, fields, now_ms, day_start_ms),
        "history.trail.record" => {
            let (value, changed) =
                trail::record(mux, key, actor, fields, now_ms).inspect_err(|error| {
                    trail::log(mux, format!("refused ({}: {})", error.code, error.message));
                })?;
            Ok((value, if changed { vec![HistoryKind::Location] } else { Vec::new() }))
        }
        _ => pages_only(mux),
    }
}

/// Whether a page result changed anything: a removal, restore or import of
/// at least one visit, a recorded visit, a changed title.
fn changed_pages(value: &Value) -> Vec<HistoryKind> {
    let counted = ["removed", "restored", "updated", "imported"]
        .iter()
        .any(|field| value.get(field).and_then(Value::as_u64).is_some_and(|n| n > 0));
    if counted || value.get("id").is_some() { vec![HistoryKind::Page] } else { Vec::new() }
}

/// `history.entries.remove`: page visits into a backup, agent entries
/// hidden, command rows and closed groups deleted, and every trail entry of
/// a location's place removed.
fn remove(
    mux: &Arc<Mux>,
    key: &str,
    actor: &Actor,
    fields: &Map<String, Value>,
    now_ms: i64,
    day_start_ms: i64,
) -> Result<(Value, Vec<HistoryKind>), ResourceError> {
    const OPERATION: &str = "history.entries.remove";
    let ids = pages::ids(fields)?;
    // Closed groups first: a failure there leaves no page backup without
    // its restore id.
    let deleted = closed::remove(mux, key, actor, &ids)?;
    let mut changed = Vec::new();
    let mut others = 0;
    let locations = trail::remove(mux, key, actor, &trail::ids(&ids))
        .map_err(|error| failed(OPERATION, &error))?;
    if locations > 0 {
        others += locations;
        changed.push(HistoryKind::Location);
    }
    let command_ids = commands::ids(&ids);
    if !command_ids.is_empty() {
        // The command worker announces the deleted rows (history-changed).
        others += commands::delete(mux, commands::Selection::Ids(command_ids))
            .map_err(|error| failed(OPERATION, &error))?;
    }
    let mut value = json!({"removed": 0, "restore_id": null});
    if ids.iter().any(|id| id.starts_with("page:")) {
        value = pages::with_stores(mux, OPERATION, |stores| {
            run(stores, OPERATION, fields, now_ms, day_start_ms)
        })?;
        changed.extend(changed_pages(&value));
    }
    if others > 0 {
        let before = value["removed"].as_u64().unwrap_or(0);
        value["removed"] = json!(before + others);
    }
    // Agent entries are hidden; so is an older journal command id
    // (`command:<machine>/<terminal>/<start ms>`).
    let hides: Vec<(&str, HistoryKind)> = ids
        .iter()
        .filter(|id| commands::row_id(id).is_none())
        .filter_map(|id| {
            let kind = match id.split(':').next() {
                Some("agent") => HistoryKind::Agent,
                Some("command") => HistoryKind::Command,
                _ => return None,
            };
            hidden_id(id).map(|hidden| (hidden, kind))
        })
        .collect();
    if !hides.is_empty() {
        hidden_doc::change(mux, key, actor, |document| {
            for (id, _) in &hides {
                document.hide_entry(id);
            }
        })
        .map_err(|error| failed(OPERATION, &error))?;
        let pages = value["removed"].as_u64().unwrap_or(0);
        value["removed"] = json!(pages + hides.len() as u64);
        for (_, kind) in &hides {
            if !changed.contains(kind) {
                changed.push(*kind);
            }
        }
    }
    if deleted > 0 {
        let before = value["removed"].as_u64().unwrap_or(0);
        value["removed"] = json!(before + deleted);
        changed.push(HistoryKind::Closed);
    }
    Ok((value, changed))
}

/// `history.clear`: page visits of the range into a backup (in `profile` or
/// every profile); unless a profile narrows the clear to pages, agent
/// entries hidden, and command rows, closed groups and trail entries
/// deleted by range: the kinds the Swift History page clears.
fn clear(
    mux: &Arc<Mux>,
    key: &str,
    actor: &Actor,
    fields: &Map<String, Value>,
    now_ms: i64,
    day_start_ms: i64,
) -> Result<(Value, Vec<HistoryKind>), ResourceError> {
    const OPERATION: &str = "history.clear";
    let kinds = pages::kinds(fields)?;
    let wants = |kind| kinds.is_empty() || kinds.contains(&kind);
    let since = pages::range(fields, true)?.start(now_ms, day_start_ms);
    let profile = pages::text(fields, "profile")?;
    // Closed groups first, as in remove.
    let deleted = match profile {
        None if wants(HistoryKind::Closed) => closed::clear(mux, key, actor, since)?,
        _ => 0,
    };
    let mut changed = Vec::new();
    let mut value = json!({"removed": 0, "restore_id": null});
    if wants(HistoryKind::Page) && pages::shared(mux, OPERATION)?.is_some() {
        value = pages::with_stores(mux, OPERATION, |stores| {
            run(stores, OPERATION, fields, now_ms, day_start_ms)
        })?;
        changed = changed_pages(&value);
    }
    let mut others = 0;
    if profile.is_none() && wants(HistoryKind::Location) {
        let removed =
            trail::clear(mux, key, actor, since).map_err(|error| failed(OPERATION, &error))?;
        if removed > 0 {
            others += removed;
            changed.push(HistoryKind::Location);
        }
    }
    if profile.is_none() && wants(HistoryKind::Command) {
        let selection = since.map_or(commands::Selection::All, |since| {
            commands::Selection::StartedSince(u64::try_from(since).unwrap_or(0))
        });
        // The command worker announces the deleted rows (history-changed).
        others += commands::delete(mux, selection).map_err(|error| failed(OPERATION, &error))?;
    }
    if others > 0 {
        let before = value["removed"].as_u64().unwrap_or(0);
        value["removed"] = json!(before + others);
    }
    let hidden: Vec<HistoryKind> =
        [HistoryKind::Agent].into_iter().filter(|kind| profile.is_none() && wants(*kind)).collect();
    if !hidden.is_empty() {
        hidden_doc::change(mux, key, actor, |document| {
            for kind in &hidden {
                document.hide_range(since, now_ms, Some(kind.as_str()));
            }
        })
        .map_err(|error| failed(OPERATION, &error))?;
        changed.extend(hidden);
    }
    if deleted > 0 {
        let before = value["removed"].as_u64().unwrap_or(0);
        value["removed"] = json!(before + deleted);
        changed.push(HistoryKind::Closed);
    }
    Ok((value, changed))
}
